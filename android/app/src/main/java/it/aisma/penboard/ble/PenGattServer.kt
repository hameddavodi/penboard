package it.aisma.penboard.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import it.aisma.penboard.proto.ControlOpcode
import it.aisma.penboard.proto.ControlPacket
import it.aisma.penboard.proto.DecodeResult
import it.aisma.penboard.proto.ErrorCode
import it.aisma.penboard.proto.MAX_POINT_COUNT
import it.aisma.penboard.proto.PROTOCOL_VERSION
import it.aisma.penboard.proto.POINT_BATCH_HEADER_BYTES
import it.aisma.penboard.proto.POINT_SIZE_BYTES
import it.aisma.penboard.proto.Packets
import it.aisma.penboard.proto.PenPoint
import it.aisma.penboard.proto.asHello
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * GATT server for the PenBoard service (PROTOCOL §1): STREAM (notify-only,
 * point batches), CONTROL (write-with-response + notify, handshake/keepalive/
 * toolbar), INFO (read-only, device identity).
 *
 * Android's [BluetoothGattServerCallback.onNotificationSent] does not report
 * which characteristic finished sending — in practice the whole connection
 * only tolerates one outstanding `notifyCharacteristicChanged` call at a time,
 * not one per characteristic. So STREAM (paced by [NotifyQueue]) and CONTROL
 * (handshake/keepalive replies) share a single in-flight gate here, with
 * CONTROL given priority since it is rare and latency-sensitive while STREAM
 * is designed to tolerate coalescing.
 */
class PenGattServer(private val callback: Callback) {

    interface Callback {
        fun onConnectionStateChanged(deviceName: String?)

        fun onHelloReceived(sixDigitCode: String)

        /** Inbound SET_MODE from the Mac (PROTOCOL §5: bidirectional, receiver applies, last-writer-wins). */
        fun onSetMode(mode: Int)

        /** Inbound SET_COLOR from the Mac. */
        fun onSetColor(colorIndex: Int)

        /** Inbound SET_WIDTH from the Mac. */
        fun onSetWidth(width: Int)

        /** Inbound CLEAR from the Mac (bidirectional -- the tablet must mirror the Mac's clear locally too). */
        fun onClearReceived()

        /** Full state push after (re)connect (PROTOCOL §5, §6.7). */
        fun onStateSync(mode: Int, colorIndex: Int, width: Int)
    }

    private var gattServer: BluetoothGattServer? = null
    private var streamCharacteristic: BluetoothGattCharacteristic? = null
    private var controlCharacteristic: BluetoothGattCharacteristic? = null

    @Volatile private var connectedDevice: BluetoothDevice? = null
    @Volatile private var currentMtu = DEFAULT_MTU
    @Volatile private var streamSubscribed = false
    @Volatile private var controlSubscribed = false
    @Volatile private var streamGateOpen = false
    @Volatile private var notificationInFlight = false
    @Volatile private var lastPingReceivedAt = SystemClock.elapsedRealtime()

    /// False until the first PING of the current session. Before that the §6
    /// sequence is still in flight and is human-paced on the Mac side (SMP
    /// pairing dialog + trust confirmation), so the watchdog allows the longer
    /// handshake grace instead of the 10 s steady-state PING timeout.
    @Volatile private var pingSeenThisSession = false

    private val controlOutbox = ArrayDeque<ByteArray>()
    private val sendRetryScheduled = AtomicBoolean(false)
    private val malformedTimestamps = ArrayDeque<Long>()

    // @Volatile: reassigned on every (re)connect from a binder thread while the
    // UI/input thread reads it in enqueuePoint -- without it the pad can keep
    // feeding the previous session's queue (stale seq, silently lost points).
    @Volatile private var notifyQueue = buildNotifyQueue()

    // PROTOCOL §6.9: tablet drops the "connected" UI state if no PING for
    // 10s. Without an active check, a zombie link (BLE stack still thinks
    // it's connected, but the Mac is gone) would show "connected" forever.
    private val keepaliveHandler = Handler(Looper.getMainLooper())
    private val keepaliveCheck =
        object : Runnable {
            override fun run() {
                checkKeepalive()
                keepaliveHandler.postDelayed(this, KEEPALIVE_CHECK_INTERVAL_MS)
            }
        }

    private val infoPayload: ByteArray by lazy {
        val nameBytes = Build.MODEL.toByteArray(Charsets.UTF_8)
        ByteArray(2 + nameBytes.size).also {
            it[0] = PROTOCOL_VERSION.toByte()
            it[1] = 0 // capsBitmask, reserved 0 in v1
            nameBytes.copyInto(it, 2)
        }
    }

    private val serverCallback =
        object : BluetoothGattServerCallback() {
            @SuppressLint("MissingPermission") // permission verified upstream by BlePermissions before start()
            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                // A second bonded central connecting mid-session must not
                // replace the active one and reset its handshake/stream
                // state out from under it -- refuse anything but the device
                // we're already talking to.
                if (newState == BluetoothProfile.STATE_CONNECTED && connectedDevice != null && connectedDevice != device) {
                    Log.w(TAG, "refusing second central connection while one is already active")
                    gattServer?.cancelConnection(device)
                    return
                }
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        // Some stacks report STATE_CONNECTED with an error
                        // status (e.g. failed encryption re-establishment);
                        // adopting that as a live session flips the UI to
                        // "connected" for a link that never came up.
                        if (status != BluetoothGatt.GATT_SUCCESS) {
                            Log.w(TAG, "ignoring STATE_CONNECTED with error status $status")
                            return
                        }
                        connectedDevice = device
                        resetSessionState()
                        callback.onConnectionStateChanged(deviceDisplayName(device))
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        // Only the active central's disconnect ends the
                        // session. Without this check, the DISCONNECTED event
                        // for a *refused* second central (cancelConnection
                        // above) nulls connectedDevice out from under the
                        // still-connected Mac: ink stops, the keepalive
                        // watchdog disarms, and the service re-advertises
                        // over a live link.
                        if (device != connectedDevice) return
                        connectedDevice = null
                        callback.onConnectionStateChanged(null)
                    }
                }
            }

            override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
                // A refused second central can still negotiate its own MTU
                // before its cancelConnection lands; adopting it would size
                // the active link's batches for someone else's link.
                if (device != connectedDevice) return
                currentMtu = mtu
                Log.i(TAG, "ATT MTU negotiated: $mtu")
            }

            @SuppressLint("MissingPermission") // permission verified upstream by BlePermissions before start()
            override fun onCharacteristicReadRequest(
                device: BluetoothDevice,
                requestId: Int,
                offset: Int,
                characteristic: BluetoothGattCharacteristic,
            ) {
                val server = gattServer ?: return
                if (characteristic.uuid == INFO_CHARACTERISTIC_UUID) {
                    lastPingReceivedAt = SystemClock.elapsedRealtime() // setup progress counts as liveness
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, infoPayload)
                } else {
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                }
            }

            @SuppressLint("MissingPermission") // permission verified upstream by BlePermissions before start()
            override fun onCharacteristicWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray,
            ) {
                if (characteristic.uuid != CONTROL_CHARACTERISTIC_UUID || device != connectedDevice) {
                    // Non-CONTROL, or a write from a refused second central
                    // racing its cancelConnection: it must never drive the
                    // active session's handshake/toolbar state.
                    if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                    }
                    return
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
                handleControlWrite(device, value)
            }

            @SuppressLint("MissingPermission") // permission verified upstream by BlePermissions before start()
            override fun onDescriptorWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                descriptor: BluetoothGattDescriptor,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray,
            ) {
                if (device != connectedDevice) {
                    if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                    }
                    return
                }
                val enable =
                    value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                        value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                when (descriptor.characteristic.uuid) {
                    STREAM_CHARACTERISTIC_UUID -> streamSubscribed = enable
                    CONTROL_CHARACTERISTIC_UUID -> controlSubscribed = enable
                }
                lastPingReceivedAt = SystemClock.elapsedRealtime() // setup progress counts as liveness
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
            }

            @SuppressLint("MissingPermission") // permission verified upstream by BlePermissions before start()
            override fun onDescriptorReadRequest(
                device: BluetoothDevice,
                requestId: Int,
                offset: Int,
                descriptor: BluetoothGattDescriptor,
            ) {
                val enabled =
                    when (descriptor.characteristic.uuid) {
                        STREAM_CHARACTERISTIC_UUID -> streamSubscribed
                        CONTROL_CHARACTERISTIC_UUID -> controlSubscribed
                        else -> false
                    }
                val value =
                    if (enabled) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }

            override fun onNotificationSent(device: BluetoothDevice, status: Int) {
                handleNotificationSent(device)
            }
        }

    @SuppressLint("MissingPermission")
    fun start(context: Context, bluetoothManager: BluetoothManager): Boolean {
        val server = bluetoothManager.openGattServer(context, serverCallback) ?: return false
        gattServer = server
        val service = buildService()
        streamCharacteristic = service.getCharacteristic(STREAM_CHARACTERISTIC_UUID)
        controlCharacteristic = service.getCharacteristic(CONTROL_CHARACTERISTIC_UUID)
        val added = server.addService(service)
        keepaliveHandler.postDelayed(keepaliveCheck, KEEPALIVE_CHECK_INTERVAL_MS)
        return added
    }

    @SuppressLint("MissingPermission") // permission verified upstream by BlePermissions before start()
    fun stop() {
        keepaliveHandler.removeCallbacks(keepaliveCheck)
        keepaliveHandler.removeCallbacks(sendRetry)
        gattServer?.close()
        gattServer = null
        connectedDevice = null
    }

    /** PROTOCOL §6.9 watchdog: no PING for 10s from a supposedly-connected device means the link is dead at the app layer even if the BLE stack hasn't noticed yet. */
    @SuppressLint("MissingPermission") // permission verified upstream by BlePermissions before start()
    private fun checkKeepalive() {
        val device = connectedDevice ?: return
        val elapsed = SystemClock.elapsedRealtime() - lastPingReceivedAt
        // The Mac sends its first PING only after the entire §6 sequence
        // completes -- which on a first connect includes the user answering
        // the macOS pairing dialog AND the trust-confirmation dialog. Killing
        // the link 10 s in guarantees first-time pairing loops forever, so the
        // strict timeout only applies once PINGs have actually started.
        val timeout = if (pingSeenThisSession) PING_TIMEOUT_MS else HANDSHAKE_GRACE_MS
        if (elapsed > timeout) {
            Log.w(TAG, "no PING received for ${elapsed}ms, treating link as dead")
            gattServer?.cancelConnection(device) // triggers onConnectionStateChange(STATE_DISCONNECTED) -> existing reconnect/re-advertise path
        }
    }

    /**
     * Feeds one captured pen/hover sample into the STREAM pacing queue
     * (PadView -> NotifyQueue). Points are discarded outright while STREAM
     * can't deliver (no link, HELLO not yet answered, or the Mac hasn't
     * subscribed -- it only does so after the user passes the trust dialog,
     * PROTOCOL §6.7). Queuing them instead let PEN_DOWN/PEN_UP/HOVER_*,
     * which the drop policy never evicts, pile up without bound for as long
     * as the pairing dialog sat open, then flush as a phantom burst of dots
     * the moment STREAM was subscribed.
     */
    fun enqueuePoint(point: PenPoint) {
        if (connectedDevice == null || !streamGateOpen || !streamSubscribed) return
        notifyQueue.enqueue(point)
    }

    /**
     * Sends a toolbar-driven CONTROL packet (SET_MODE/SET_COLOR/SET_WIDTH/
     * UNDO/CLEAR, PROTOCOL §5) to the connected Mac, if any. No-op when
     * nothing is connected -- the toolbar always applies the change locally
     * regardless, so there is nothing to retry once a connection appears.
     */
    fun sendControlPacket(opcode: Int, payload: ByteArray = ByteArray(0)) {
        val device = connectedDevice ?: return
        sendControl(device, Packets.encodeControl(opcode, payload))
    }

    private fun buildService(): BluetoothGattService {
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        val stream =
            BluetoothGattCharacteristic(STREAM_CHARACTERISTIC_UUID, BluetoothGattCharacteristic.PROPERTY_NOTIFY, 0)
        stream.addDescriptor(newCccd())

        val control =
            BluetoothGattCharacteristic(
                CONTROL_CHARACTERISTIC_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED,
            )
        control.addDescriptor(newCccd())

        val info =
            BluetoothGattCharacteristic(
                INFO_CHARACTERISTIC_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED,
            )

        service.addCharacteristic(stream)
        service.addCharacteristic(control)
        service.addCharacteristic(info)
        return service
    }

    private fun newCccd(): BluetoothGattDescriptor =
        // PROTOCOL §1 lists READ_ENCRYPTED for STREAM's CCCD and "encrypted"
        // for CONTROL's; both need WRITE too so the central can actually write
        // the CCCD to subscribe — read-only would make notifications
        // unsubscribable. Applying read+write encrypted to both closes that
        // gap without weakening the encryption requirement the doc asks for.
        BluetoothGattDescriptor(
            CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_READ_ENCRYPTED or BluetoothGattDescriptor.PERMISSION_WRITE_ENCRYPTED,
        )

    // @Synchronized: called from the binder-thread onConnectionStateChange
    // while sendControl/pumpControlOutbox (other binder threads) mutate
    // controlOutbox under the same monitor. Lock order stays one-directional
    // (this method never calls into NotifyQueue's monitor -- buildNotifyQueue
    // only constructs).
    @Synchronized
    private fun resetSessionState() {
        currentMtu = DEFAULT_MTU
        streamSubscribed = false
        controlSubscribed = false
        streamGateOpen = false
        notificationInFlight = false
        lastPingReceivedAt = SystemClock.elapsedRealtime()
        pingSeenThisSession = false
        controlOutbox.clear()
        malformedTimestamps.clear()
        notifyQueue = buildNotifyQueue()
    }

    private fun buildNotifyQueue(): NotifyQueue =
        NotifyQueue(maxPointsPerBatch = { maxPointsForMtu(currentMtu) }, send = ::trySendStream)

    private fun maxPointsForMtu(mtu: Int): Int {
        val maxPayload = mtu - ATT_HEADER_BYTES
        val raw = (maxPayload - POINT_BATCH_HEADER_BYTES) / POINT_SIZE_BYTES
        return raw.coerceIn(1, MAX_POINT_COUNT)
    }

    @Synchronized
    private fun trySendStream(bytes: ByteArray): Boolean {
        if (notificationInFlight) return false
        val device = connectedDevice ?: return false
        val characteristic = streamCharacteristic ?: return false
        if (!streamGateOpen || !streamSubscribed) return false
        if (!notify(device, characteristic, bytes)) {
            scheduleSendRetry()
            return false
        }
        notificationInFlight = true
        return true
    }

    @Synchronized
    private fun sendControl(device: BluetoothDevice, bytes: ByteArray) {
        controlOutbox.addLast(bytes)
        pumpControlOutbox(device)
    }

    @Synchronized
    private fun pumpControlOutbox(device: BluetoothDevice) {
        if (notificationInFlight || controlOutbox.isEmpty()) return
        val characteristic = controlCharacteristic ?: return
        val next = controlOutbox.first()
        if (notify(device, characteristic, next)) {
            controlOutbox.removeFirst()
            notificationInFlight = true
        } else {
            scheduleSendRetry()
        }
    }

    /**
     * The stack can reject a notify with nothing of ours in flight (API 33+
     * returns ERROR_GATT_WRITE_REQUEST_BUSY while its own queue drains), and
     * then no onNotificationSent will ever arrive to pump the outbox again.
     * Without a retry, a rejected HELLO_OK stalled the handshake until the
     * 90 s watchdog, a rejected PONG cost the link, and a rejected PEN_UP sat
     * buffered until the next pen event. Coalesced: at most one pending retry.
     */
    private fun scheduleSendRetry() {
        if (!sendRetryScheduled.compareAndSet(false, true)) return
        keepaliveHandler.postDelayed(sendRetry, SEND_RETRY_DELAY_MS)
    }

    private fun handleNotificationSent(device: BluetoothDevice) {
        // Deliberately NOT one @Synchronized block: NotifyQueue.enqueue ->
        // flushIfIdle can call back into trySendStream (which locks `this`)
        // while holding NotifyQueue's own monitor. If this method held
        // `this`'s lock for the whole body, notifyQueue.onNotificationSent()
        // below would try to acquire NotifyQueue's monitor while still
        // holding `this` -- the exact reverse acquisition order, an AB-BA
        // deadlock under sustained input. Releasing `this`'s lock before
        // calling into NotifyQueue keeps the lock order one-directional
        // (NotifyQueue -> PenGattServer, never the other way).
        synchronized(this) {
            notificationInFlight = false
            pumpControlOutbox(device) // CONTROL (handshake/keepalive) takes priority...
        }
        notifyQueue.onNotificationSent() // ...then STREAM gets its turn if the gate is still free.
    }

    // Same split-lock shape as handleNotificationSent: never hold `this` while
    // calling into NotifyQueue (lock order stays NotifyQueue -> PenGattServer).
    private val sendRetry = Runnable {
        sendRetryScheduled.set(false)
        val device = connectedDevice ?: return@Runnable
        synchronized(this) { pumpControlOutbox(device) }
        notifyQueue.retry()
    }

    @SuppressLint("MissingPermission") // permission verified upstream by BlePermissions before start()
    private fun handleControlWrite(device: BluetoothDevice, value: ByteArray) {
        when (val result = Packets.decode(value)) {
            DecodeResult.VersionMismatch -> {
                Log.w(TAG, "CONTROL write: unsupported protocol version, disconnecting")
                sendControl(device, Packets.encodeControl(ControlOpcode.ERROR, byteArrayOf(ErrorCode.VERSION_MISMATCH.toByte())))
                gattServer?.cancelConnection(device)
            }
            is DecodeResult.Malformed -> {
                // Never log packet contents (AISMA §7 redaction) — reason only.
                Log.w(TAG, "CONTROL write malformed: ${result.reason}")
                if (recordMalformedAndCheckFlood()) {
                    Log.w(TAG, "malformed-flood threshold exceeded, disconnecting")
                    sendControl(device, Packets.encodeControl(ControlOpcode.ERROR, byteArrayOf(ErrorCode.MALFORMED_FLOOD.toByte())))
                    gattServer?.cancelConnection(device)
                }
            }
            is DecodeResult.PointBatch -> Log.w(TAG, "point batch received on CONTROL characteristic, dropping")
            is DecodeResult.Control -> handleControlPacket(device, result.packet)
        }
    }

    @SuppressLint("MissingPermission") // permission verified upstream by BlePermissions before start()
    private fun handleControlPacket(device: BluetoothDevice, packet: ControlPacket) {
        // Any schema-valid CONTROL from the Mac proves the app-level link is
        // alive -- it feeds the same watchdog as PING so setup traffic (HELLO,
        // STATE_SYNC) counts as progress during the pre-PING handshake window.
        lastPingReceivedAt = SystemClock.elapsedRealtime()
        when (packet.opcode) {
            ControlOpcode.HELLO -> {
                val hello = packet.asHello()
                if (hello == null) {
                    Log.w(TAG, "HELLO payload failed to parse despite passing schema validation")
                    return
                }
                if (hello.protoVersion != PROTOCOL_VERSION) {
                    Log.w(TAG, "HELLO protoVersion mismatch: ${hello.protoVersion}, disconnecting")
                    sendControl(device, Packets.encodeControl(ControlOpcode.ERROR, byteArrayOf(ErrorCode.VERSION_MISMATCH.toByte())))
                    gattServer?.cancelConnection(device)
                    return
                }
                callback.onHelloReceived(hello.sixDigitCode)
                sendControl(device, Packets.encodeControl(ControlOpcode.HELLO_OK, byteArrayOf(PROTOCOL_VERSION.toByte())))
                if (!streamGateOpen) {
                    // Points captured before the handshake completed (e.g.
                    // while the pairing dialog was up) are stale by the time
                    // the gate opens; flushing them would show up as a
                    // phantom burst of ink right after pairing.
                    notifyQueue.clear()
                }
                streamGateOpen = true
            }
            ControlOpcode.PING -> {
                pingSeenThisSession = true
                sendControl(device, Packets.encodeControl(ControlOpcode.PONG, packet.payload))
            }
            ControlOpcode.SET_MODE -> callback.onSetMode(packet.payload[0].toInt() and 0xFF)
            ControlOpcode.SET_COLOR -> callback.onSetColor(packet.payload[0].toInt() and 0xFF)
            ControlOpcode.SET_WIDTH -> callback.onSetWidth(packet.payload[0].toInt() and 0xFF)
            ControlOpcode.CLEAR -> callback.onClearReceived()
            ControlOpcode.STATE_SYNC ->
                callback.onStateSync(
                    mode = packet.payload[0].toInt() and 0xFF,
                    colorIndex = packet.payload[1].toInt() and 0xFF,
                    width = packet.payload[2].toInt() and 0xFF,
                )
            else -> {
                // UNDO is tablet -> Mac only (PROTOCOL §5) and ERROR from the
                // Mac has no tablet-side action defined at this milestone --
                // both are schema-valid but only logged.
                Log.i(TAG, "received CONTROL opcode ${packet.opcode}")
            }
        }
    }

    // @Synchronized: GATT callbacks are not guaranteed to arrive on a single
    // binder thread, and resetSessionState clears this deque concurrently.
    @Synchronized
    private fun recordMalformedAndCheckFlood(): Boolean {
        val now = SystemClock.elapsedRealtime()
        malformedTimestamps.addLast(now)
        while (malformedTimestamps.isNotEmpty() && now - malformedTimestamps.first() > MALFORMED_WINDOW_MS) {
            malformedTimestamps.removeFirst()
        }
        return malformedTimestamps.size > MALFORMED_FLOOD_THRESHOLD
    }

    @SuppressLint("MissingPermission")
    private fun notify(device: BluetoothDevice, characteristic: BluetoothGattCharacteristic, value: ByteArray): Boolean {
        val server = gattServer ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device, characteristic, false, value) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = value
            @Suppress("DEPRECATION")
            server.notifyCharacteristicChanged(device, characteristic, false)
        }
    }

    @SuppressLint("MissingPermission")
    private fun deviceDisplayName(device: BluetoothDevice): String = device.name ?: device.address

    companion object {
        private const val TAG = "PenGattServer"

        /** Conservative floor (PROTOCOL §2): assumed until onMtuChanged fires. */
        private const val DEFAULT_MTU = 185
        private const val ATT_HEADER_BYTES = 3
        private const val MALFORMED_WINDOW_MS = 60_000L
        private const val MALFORMED_FLOOD_THRESHOLD = 10

        /** PROTOCOL §6.9: tablet drops "connected" if no PING arrives for this long. */
        private const val PING_TIMEOUT_MS = 10_000L

        /**
         * Watchdog allowance before the first PING of a session: the §6
         * sequence is human-paced on a first connect (macOS pairing dialog +
         * trust confirmation), so the 10 s steady-state timeout only arms
         * once PINGs start. Setup traffic (INFO read, CCCD writes, CONTROL)
         * refreshes the clock within this window.
         */
        private const val HANDSHAKE_GRACE_MS = 90_000L
        private const val KEEPALIVE_CHECK_INTERVAL_MS = 2_000L
        private const val SEND_RETRY_DELAY_MS = 20L

        val SERVICE_UUID: UUID = UUID.fromString("C5F1A9E2-7B34-4E86-9D12-8A50C3B7F6D4")
        val STREAM_CHARACTERISTIC_UUID: UUID = UUID.fromString("C5F1A9E3-7B34-4E86-9D12-8A50C3B7F6D4")
        val CONTROL_CHARACTERISTIC_UUID: UUID = UUID.fromString("C5F1A9E4-7B34-4E86-9D12-8A50C3B7F6D4")
        val INFO_CHARACTERISTIC_UUID: UUID = UUID.fromString("C5F1A9E5-7B34-4E86-9D12-8A50C3B7F6D4")
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
    }
}
