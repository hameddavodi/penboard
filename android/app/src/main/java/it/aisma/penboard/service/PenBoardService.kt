package it.aisma.penboard.service

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
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

    /** True once a device has connected at least once this service lifetime (M4.1 reconnect banner/backoff). */
    private var everConnected = false
    private var reconnectBackoffMs = INITIAL_RECONNECT_BACKOFF_MS

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification(status), foregroundServiceType())
        startBleStack()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        penAdvertiser?.stop()
        penGattServer?.stop()
        super.onDestroy()
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
                        if (deviceName != null) {
                            everConnected = true
                            reconnectBackoffMs = INITIAL_RECONNECT_BACKOFF_MS
                            updateStatus(status.copy(connectedDeviceName = deviceName, reconnecting = false))
                        } else {
                            // The link is gone, so any pairing code cached
                            // from an in-progress handshake is dead -- a
                            // stale code must not resurface if the activity
                            // (re)attaches before a fresh HELLO arrives.
                            pendingPairingCode = null
                            updateStatus(status.copy(connectedDeviceName = null, reconnecting = everConnected))
                            // R1 (EXECUTION-PLAN.md): the peripheral typically
                            // stops advertising once a central connects, so it
                            // must be explicitly restarted after a disconnect
                            // to become discoverable again.
                            if (everConnected) scheduleReadvertise()
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
            return
        }

        val advertiser = PenAdvertiser(adapter)
        penAdvertiser = advertiser
        advertiser.start { success, reason ->
            updateStatus(status.copy(advertising = success, advertiseFailureReason = reason))
        }
    }

    /** Re-advertises after a disconnect with exponential backoff (M4.1: "sensible retry"), capped and reset on success. */
    private fun scheduleReadvertise() {
        mainHandler.postDelayed(
            {
                val advertiser = penAdvertiser ?: return@postDelayed
                advertiser.start { success, reason ->
                    updateStatus(status.copy(advertising = success, advertiseFailureReason = reason))
                    if (success) {
                        reconnectBackoffMs = INITIAL_RECONNECT_BACKOFF_MS
                    } else {
                        reconnectBackoffMs = (reconnectBackoffMs * 2).coerceAtMost(MAX_RECONNECT_BACKOFF_MS)
                        scheduleReadvertise()
                    }
                }
            },
            reconnectBackoffMs,
        )
    }

    private fun updateStatus(newStatus: ConnectionStatus) {
        status = newStatus
        mainHandler.post {
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

        fun bindingIntent(context: Context): Intent = Intent(context, PenBoardService::class.java)
    }
}
