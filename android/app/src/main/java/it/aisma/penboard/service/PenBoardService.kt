package it.aisma.penboard.service

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import it.aisma.penboard.MainActivity
import it.aisma.penboard.R
import it.aisma.penboard.ble.PenAdvertiser
import it.aisma.penboard.ble.PenGattServer
import it.aisma.penboard.perm.BlePermissions
import it.aisma.penboard.proto.PenPoint

/**
 * Foreground service that owns the BLE peripheral link (PLAN.md: "Foreground
 * service keeps the link alive with screen dimmed"). Started explicitly by
 * MainActivity once BLE runtime permissions are granted; also bindable so the
 * activity can register a [Listener] for status/handshake UI updates without
 * pulling in a third-party lifecycle/coroutines dependency.
 */
class PenBoardService : Service() {

    data class ConnectionStatus(
        val advertising: Boolean = false,
        val advertiseFailureReason: String? = null,
        val connectedDeviceName: String? = null,
        /** True once a device connected at least once and has since dropped (M4.1 reconnect banner). */
        val reconnecting: Boolean = false,
    )

    /** Last full-state push from the Mac (PROTOCOL §5/§6.7), cached so a listener attached later can replay it. */
    private data class StateSync(val mode: Int, val colorIndex: Int, val width: Int)

    interface Listener {
        fun onStatusChanged(status: ConnectionStatus)

        fun onPairingCodeReceived(sixDigitCode: String)

        fun onSetMode(mode: Int)

        fun onSetColor(colorIndex: Int)

        fun onSetWidth(width: Int)

        fun onClearReceived()

        fun onStateSync(mode: Int, colorIndex: Int, width: Int)
    }

    inner class LocalBinder : Binder() {
        fun getService(): PenBoardService = this@PenBoardService
    }

    private val binder = LocalBinder()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var listener: Listener? = null
    @Volatile private var status = ConnectionStatus()

    /**
     * listener?.onXxx(...) calls below only fire while an activity is bound
     * (M4.1 reconnect scenario: activity stopped/backgrounded). Without
     * caching, a HELLO or STATE_SYNC that arrives while nothing is listening
     * is lost forever -- the pairing code never shows, and the toolbar/prefs
     * never pick up the reconnect's authoritative state. These are replayed
     * in [setListener] once a non-null listener attaches.
     */
    @Volatile private var lastStateSync: StateSync? = null
    @Volatile private var pendingPairingCode: String? = null

    private var penGattServer: PenGattServer? = null
    private var penAdvertiser: PenAdvertiser? = null

    /** Guards onDestroy's unregister when onCreate bailed before registering (startForeground rejected). */
    private var receiverRegistered = false

    /** True once a device has connected at least once this service lifetime (M4.1 reconnect banner/backoff). */
    private var everConnected = false
    private var reconnectBackoffMs = INITIAL_RECONNECT_BACKOFF_MS

    /**
     * The GATT server/advertiser handle can go stale without any callback telling
     * us (adapter power-cycled, bluetoothd restarted, or the app simply sat
     * backgrounded for days) -- STATE_OFF tears the stack down, STATE_ON rebuilds
     * it, so a zombie link never survives past the next adapter toggle.
     */
    private val bluetoothStateReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                    BluetoothAdapter.STATE_ON -> {
                        Log.i(TAG, "Bluetooth adapter turned on -- rebuilding BLE stack")
                        restartBleStack()
                    }
                    BluetoothAdapter.STATE_OFF -> {
                        Log.w(TAG, "Bluetooth adapter turned off -- tearing down BLE stack")
                        mainHandler.removeCallbacksAndMessages(null)
                        penAdvertiser?.stop()
                        penGattServer?.stop()
                        penAdvertiser = null
                        penGattServer = null
                        updateStatus { ConnectionStatus() }
                    }
                }
            }
        }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        try {
            startForeground(NOTIFICATION_ID, buildNotification(status), foregroundServiceType())
        } catch (e: SecurityException) {
            // START_STICKY restart after the user revoked the Bluetooth
            // runtime permission: the connectedDevice foreground type then
            // rejects startForeground, and without this catch the service
            // crash-loops (crash -> sticky restart -> crash). Stop cleanly;
            // the next real app launch re-checks permissions and restarts us.
            Log.e(TAG, "startForeground rejected (permission revoked?) -- stopping service", e)
            stopSelf()
            return
        }
        ContextCompat.registerReceiver(
            this,
            bluetoothStateReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiverRegistered = true
        // No startBleStack() here: this service is only ever started via
        // startForegroundService (or a START_STICKY restart), so onStartCommand
        // always follows and its ensureBleStackRunning() builds the stack.
        // Building it here too made that first onStartCommand see an idle,
        // freshly-built stack and immediately tear it down and rebuild it --
        // a double advertise/rename/GATT-open on every cold start.
    }

    /**
     * MainActivity calls startForegroundService() on every app launch, including
     * against this already-running (START_STICKY) instance days later -- onCreate
     * only ever runs once, so this is what notices a dead/never-started stack
     * (e.g. after sitting backgrounded for days) and rebuilds it. Force-stopping
     * the app used to be the only way to get a fresh stack; this makes that
     * unnecessary.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureBleStackRunning()
        return START_STICKY
    }

    override fun onDestroy() {
        if (receiverRegistered) unregisterReceiver(bluetoothStateReceiver)
        mainHandler.removeCallbacksAndMessages(null)
        penAdvertiser?.stop()
        penGattServer?.stop()
        super.onDestroy()
    }

    /** Swiping the app away leaves this a zombie foreground service for days -- stop cleanly so the next launch always gets a fresh onCreate() rebuild. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    fun setListener(newListener: Listener?) {
        listener = newListener
        newListener?.onStatusChanged(status)
        lastStateSync?.let { newListener?.onStateSync(it.mode, it.colorIndex, it.width) }
        pendingPairingCode?.let { newListener?.onPairingCodeReceived(it) }
    }

    /** Feeds one PadView-captured pen/hover sample into the BLE STREAM path (M2.1 wiring). */
    fun enqueuePoint(point: PenPoint) {
        penGattServer?.enqueuePoint(point)
    }

    /** Sends a toolbar-driven CONTROL packet (SET_MODE/SET_COLOR/SET_WIDTH/UNDO/CLEAR) to the Mac, if connected. */
    fun sendControl(opcode: Int, payload: ByteArray = ByteArray(0)) {
        penGattServer?.sendControlPacket(opcode, payload)
    }

    private fun startBleStack() {
        if (!BlePermissions.allGranted(this)) {
            Log.w(TAG, "BLE permissions missing, not starting the peripheral stack")
            return
        }
        val bluetoothManager = getSystemService(BluetoothManager::class.java)
        val adapter: BluetoothAdapter? = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.w(TAG, "Bluetooth adapter unavailable or disabled")
            return
        }

        val gattServer =
            PenGattServer(
                object : PenGattServer.Callback {
                    override fun onConnectionStateChanged(deviceName: String?) {
                        // Hop to main: everConnected/reconnectBackoffMs/
                        // scheduleReadvertise are main-confined, and this
                        // callback arrives on a binder thread.
                        mainHandler.post {
                            if (deviceName != null) {
                                // A re-advertise still pending from an earlier
                                // drop would broadcast over the live link.
                                mainHandler.removeCallbacksAndMessages(READVERTISE_TOKEN)
                                everConnected = true
                                reconnectBackoffMs = INITIAL_RECONNECT_BACKOFF_MS
                                updateStatus { it.copy(connectedDeviceName = deviceName, reconnecting = false) }
                            } else {
                                // The link is gone, so any pairing code cached
                                // from an in-progress handshake is dead -- a
                                // stale code must not resurface if the activity
                                // (re)attaches before a fresh HELLO arrives.
                                pendingPairingCode = null
                                updateStatus { it.copy(connectedDeviceName = null, reconnecting = everConnected) }
                                // R1 (EXECUTION-PLAN.md): the peripheral typically
                                // stops advertising once a central connects, so it
                                // must be explicitly restarted after a disconnect
                                // to become discoverable again.
                                if (everConnected) scheduleReadvertise()
                            }
                        }
                    }

                    override fun onHelloReceived(sixDigitCode: String) {
                        pendingPairingCode = sixDigitCode
                        mainHandler.post { listener?.onPairingCodeReceived(sixDigitCode) }
                    }

                    override fun onSetMode(mode: Int) {
                        mainHandler.post { listener?.onSetMode(mode) }
                    }

                    override fun onSetColor(colorIndex: Int) {
                        mainHandler.post { listener?.onSetColor(colorIndex) }
                    }

                    override fun onSetWidth(width: Int) {
                        mainHandler.post { listener?.onSetWidth(width) }
                    }

                    override fun onClearReceived() {
                        mainHandler.post { listener?.onClearReceived() }
                    }

                    override fun onStateSync(mode: Int, colorIndex: Int, width: Int) {
                        lastStateSync = StateSync(mode, colorIndex, width)
                        // Handshake is complete (PROTOCOL §6 step 7); any
                        // cached pairing code is now stale.
                        pendingPairingCode = null
                        mainHandler.post { listener?.onStateSync(mode, colorIndex, width) }
                    }
                },
            )
        penGattServer = gattServer

        if (!gattServer.start(this, bluetoothManager)) {
            Log.e(TAG, "failed to start GATT server")
            // Release the half-started server (open handle + keepalive loop)
            // and null the reference so ensureBleStackRunning's == null branch
            // can rebuild on the next launch.
            gattServer.stop()
            penGattServer = null
            return
        }

        val advertiser = PenAdvertiser(adapter)
        penAdvertiser = advertiser
        advertiser.start { success, reason ->
            updateStatus { it.copy(advertising = success, advertiseFailureReason = reason) }
        }
    }

    /** Tears down and rebuilds the whole BLE stack -- used when the existing GATT server/advertiser handle may be stale rather than trusted. */
    private fun restartBleStack() {
        mainHandler.removeCallbacksAndMessages(READVERTISE_TOKEN)
        penAdvertiser?.stop()
        penGattServer?.stop()
        penAdvertiser = null
        penGattServer = null
        everConnected = false
        reconnectBackoffMs = INITIAL_RECONNECT_BACKOFF_MS
        updateStatus { ConnectionStatus() }
        startBleStack()
    }

    /** Called from [onStartCommand]: rebuilds the stack if it never started, or if it's sitting idle (not connected, handle possibly stale) rather than trusting a days-old handle. A live connection is left untouched. */
    private fun ensureBleStackRunning() {
        if (!BlePermissions.allGranted(this)) {
            Log.w(TAG, "BLE permissions missing, not starting the peripheral stack")
            return
        }
        val bluetoothManager = getSystemService(BluetoothManager::class.java)
        val adapter: BluetoothAdapter? = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.w(TAG, "Bluetooth adapter unavailable or disabled")
            return
        }
        if (penGattServer == null) {
            startBleStack()
            return
        }
        if (status.connectedDeviceName != null) {
            return
        }
        Log.i(TAG, "BLE stack idle on (re)launch -- rebuilding in case the GATT server/advertiser handle went stale")
        restartBleStack()
    }

    /** Re-advertises after a disconnect with exponential backoff (M4.1: "sensible retry"), capped and reset on success. */
    private fun scheduleReadvertise() {
        // At most one pending re-advertise: back-to-back drops (or a failure
        // retry racing a fresh drop) used to stack parallel retry chains.
        mainHandler.removeCallbacksAndMessages(READVERTISE_TOKEN)
        mainHandler.postDelayed(
            {
                val advertiser = penAdvertiser ?: return@postDelayed
                advertiser.start { success, reason ->
                    updateStatus { it.copy(advertising = success, advertiseFailureReason = reason) }
                    if (success) {
                        reconnectBackoffMs = INITIAL_RECONNECT_BACKOFF_MS
                    } else {
                        reconnectBackoffMs = (reconnectBackoffMs * 2).coerceAtMost(MAX_RECONNECT_BACKOFF_MS)
                        scheduleReadvertise()
                    }
                }
            },
            READVERTISE_TOKEN,
            reconnectBackoffMs,
        )
    }

    /**
     * All status updates are expressed as transforms and applied on the main
     * thread. `status.copy(...)` at the call site would be a non-atomic
     * read-modify-write racing binder-thread GATT callbacks against
     * main-thread advertise callbacks -- last writer wins with a stale read,
     * e.g. reverting `advertising` right after a re-advertise succeeded.
     */
    private fun updateStatus(transform: (ConnectionStatus) -> ConnectionStatus) {
        mainHandler.post {
            val newStatus = transform(status)
            status = newStatus
            listener?.onStatusChanged(newStatus)
            // POST_NOTIFICATIONS is a runtime permission on API 33+; the
            // foreground service keeps running either way (that grant only
            // gates whether the status notification is visible to the user).
            if (hasNotificationPermission()) {
                notificationManager().notify(NOTIFICATION_ID, buildNotification(newStatus))
            }
        }
    }

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

    // minSdk 29 already guarantees the connectedDevice foreground service type
    // is available (introduced in the original Android 10 / API 29 set), so no
    // SDK_INT branch is needed here.
    private fun foregroundServiceType(): Int = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE

    private fun notificationManager(): NotificationManager = getSystemService(NotificationManager::class.java)

    private fun createNotificationChannel() {
        val channel =
            NotificationChannel(NOTIFICATION_CHANNEL_ID, getString(R.string.app_name), NotificationManager.IMPORTANCE_LOW)
        notificationManager().createNotificationChannel(channel)
    }

    private fun buildNotification(current: ConnectionStatus): Notification {
        val contentText =
            when {
                current.connectedDeviceName != null -> getString(R.string.status_connected, current.connectedDeviceName)
                current.reconnecting -> getString(R.string.status_reconnecting)
                current.advertising -> getString(R.string.status_advertising)
                current.advertiseFailureReason != null ->
                    getString(R.string.status_advertising_failed, current.advertiseFailureReason)
                else -> getString(R.string.status_starting)
            }
        val contentIntent =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE,
            )
        return Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(contentText)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "PenBoardService"
        private const val NOTIFICATION_CHANNEL_ID = "penboard_status"
        private const val NOTIFICATION_ID = 1

        /** Re-advertise retry backoff after a disconnect (M4.1: "sensible retry"), doubling up to the cap. */
        private const val INITIAL_RECONNECT_BACKOFF_MS = 1_000L
        private const val MAX_RECONNECT_BACKOFF_MS = 16_000L
        private val READVERTISE_TOKEN = Any()

        fun bindingIntent(context: Context): Intent = Intent(context, PenBoardService::class.java)
    }
}
