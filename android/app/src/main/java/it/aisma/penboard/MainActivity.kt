package it.aisma.penboard

import android.Manifest
import android.app.Dialog
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import it.aisma.penboard.perm.BlePermissions
import it.aisma.penboard.proto.ControlOpcode
import it.aisma.penboard.service.PenBoardService
import it.aisma.penboard.ui.PadView
import it.aisma.penboard.ui.PenBoardPrefs
import it.aisma.penboard.ui.Toolbar

/**
 * Single full-screen activity (decision D2: plain Views/XML, no Compose).
 * Requests BLE runtime permissions, starts/binds [PenBoardService], reflects
 * its connection status, and shows the full-screen 6-digit pairing code
 * dialog when a HELLO handshake arrives (PROTOCOL §6).
 */
class MainActivity : AppCompatActivity(), PenBoardService.Listener {

    private lateinit var statusText: TextView
    private lateinit var grantPermissionsButton: Button
    private lateinit var permissionGate: View
    private lateinit var padView: PadView
    private lateinit var toolbar: Toolbar
    private lateinit var reconnectBanner: TextView

    private val prefs: PenBoardPrefs by lazy { PenBoardPrefs(this) }

    private var service: PenBoardService? = null
    private var pairingDialog: Dialog? = null

    /** True once [bindService] itself returned true; onStop must only unbind in that case (a bind can fail before onServiceConnected ever fires). */
    private var isBound = false

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
            if (BlePermissions.allGranted(this)) {
                grantPermissionsButton.visibility = View.GONE
                startAndBindService()
            } else {
                statusText.setText(R.string.status_permissions_required)
                grantPermissionsButton.visibility = View.VISIBLE
            }
        }

    /**
     * BLE permissions are the ones that actually gate the peripheral stack
     * (see [BlePermissions]); POST_NOTIFICATIONS only gates whether the
     * foreground service's status notification is visible, so it rides along
     * in the same request for a single permissions dialog rather than a
     * second prompt later.
     */
    private fun permissionsToRequest(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            BlePermissions.required() + Manifest.permission.POST_NOTIFICATIONS
        } else {
            BlePermissions.required()
        }

    private val serviceConnection =
        object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                val bound = (binder as PenBoardService.LocalBinder).getService()
                service = bound
                bound.setListener(this@MainActivity)
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                service = null
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        enterFullScreen()
        // R1 (EXECUTION-PLAN.md): Samsung stops BLE advertising when the
        // screen goes fully off, so the pad must never let the screen sleep.
        // The toolbar's dim toggle only ever touches screenBrightness, never
        // this flag.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        statusText = findViewById(R.id.statusText)
        grantPermissionsButton = findViewById(R.id.grantPermissionsButton)
        permissionGate = findViewById(R.id.permissionGate)
        padView = findViewById(R.id.padView)
        toolbar = findViewById(R.id.toolbar)
        reconnectBanner = findViewById(R.id.reconnectBanner)
        grantPermissionsButton.setOnClickListener { permissionLauncher.launch(permissionsToRequest()) }

        padView.onPoint = { point -> service?.enqueuePoint(point) }
        toolbar.listener = toolbarListener

        if (BlePermissions.allGranted(this)) {
            startAndBindService()
        } else {
            statusText.setText(R.string.status_permissions_required)
            grantPermissionsButton.visibility = View.VISIBLE
            permissionLauncher.launch(permissionsToRequest())
        }
    }

    override fun onStart() {
        super.onStart()
        if (BlePermissions.allGranted(this)) {
            isBound = bindService(PenBoardService.bindingIntent(this), serviceConnection, 0)
        }
    }

    override fun onStop() {
        service?.setListener(null)
        if (isBound) {
            unbindService(serviceConnection)
            isBound = false
        }
        service = null
        super.onStop()
    }

    override fun onDestroy() {
        pairingDialog?.dismiss()
        super.onDestroy()
    }

    override fun onStatusChanged(status: PenBoardService.ConnectionStatus) {
        val text =
            when {
                status.connectedDeviceName != null -> getString(R.string.status_connected, status.connectedDeviceName)
                status.reconnecting -> getString(R.string.status_reconnecting)
                status.advertising -> getString(R.string.status_advertising)
                status.advertiseFailureReason != null ->
                    getString(R.string.status_advertising_failed, status.advertiseFailureReason)
                else -> getString(R.string.status_starting)
            }
        statusText.text = text
        toolbar.setConnectionStatus(text)
        // M4.1: banner shows only while a previously-live link is down; it
        // auto-hides the moment reconnecting flips back to false.
        reconnectBanner.visibility = if (status.reconnecting) View.VISIBLE else View.GONE
        // The pairing dialog belongs to one specific handshake; once the link
        // drops (or never completed), its code is dead -- a fresh HELLO on
        // reconnect will show a new one. Without this it can linger full-
        // screen and cover the pad forever (finding: MainActivity dialog leak).
        if (status.connectedDeviceName == null) {
            pairingDialog?.dismiss()
            pairingDialog = null
        }
    }

    override fun onPairingCodeReceived(sixDigitCode: String) {
        showPairingCodeDialog(sixDigitCode)
    }

    override fun onSetMode(mode: Int) {
        prefs.mode = mode
        toolbar.setMode(mode)
        padView.setMode(mode)
    }

    override fun onSetColor(colorIndex: Int) {
        prefs.colorIndex = colorIndex
        toolbar.setColorIndex(colorIndex)
        padView.setColorIndex(colorIndex)
    }

    override fun onSetWidth(width: Int) {
        // PROTOCOL §5: SET_WIDTH / STATE_SYNC width is clamped 1-64.
        val clamped = ControlOpcode.clampWidth(width)
        prefs.widthBase = clamped
        toolbar.setWidth(clamped)
        padView.setBaseWidth(clamped)
    }

    override fun onClearReceived() {
        padView.clearAllStrokes()
    }

    override fun onStateSync(mode: Int, colorIndex: Int, width: Int) {
        // STATE_SYNC = handshake complete (PROTOCOL §6 step 7); the pairing
        // code dialog has served its purpose and must not linger over the pad.
        pairingDialog?.dismiss()
        pairingDialog = null
        onSetMode(mode)
        onSetColor(colorIndex)
        onSetWidth(width)
    }

    private val toolbarListener =
        object : Toolbar.Listener {
            override fun onModeChanged(mode: Int) {
                prefs.mode = mode
                padView.setMode(mode)
                service?.sendControl(ControlOpcode.SET_MODE, byteArrayOf(mode.toByte()))
            }

            override fun onColorSelected(colorIndex: Int) {
                prefs.colorIndex = colorIndex
                padView.setColorIndex(colorIndex)
                service?.sendControl(ControlOpcode.SET_COLOR, byteArrayOf(colorIndex.toByte()))
            }

            override fun onWidthSelected(width: Int) {
                prefs.widthBase = width
                padView.setBaseWidth(width)
                service?.sendControl(ControlOpcode.SET_WIDTH, byteArrayOf(width.toByte()))
            }

            override fun onUndoClicked() {
                padView.undoLastStroke()
                service?.sendControl(ControlOpcode.UNDO)
            }

            override fun onClearClicked() {
                padView.clearAllStrokes()
                service?.sendControl(ControlOpcode.CLEAR)
            }

            override fun onDimToggled(enabled: Boolean) {
                prefs.dimEnabled = enabled
                applyDim(enabled)
            }
        }

    private fun startAndBindService() {
        ContextCompat.startForegroundService(this, PenBoardService.bindingIntent(this))
        isBound = bindService(PenBoardService.bindingIntent(this), serviceConnection, 0)
        showPadUi()
    }

    /** Swaps the permission-gate UI for the live pad + toolbar and loads persisted settings (M4.1). */
    private fun showPadUi() {
        permissionGate.visibility = View.GONE
        padView.visibility = View.VISIBLE
        toolbar.visibility = View.VISIBLE
        padView.setColorIndex(prefs.colorIndex)
        padView.setBaseWidth(prefs.widthBase)
        padView.setMode(prefs.mode)
        toolbar.setMode(prefs.mode)
        toolbar.setColorIndex(prefs.colorIndex)
        toolbar.setWidth(prefs.widthBase)
        toolbar.setDimEnabled(prefs.dimEnabled)
        applyDim(prefs.dimEnabled)
    }

    /**
     * M4.1 "dim presenter mode": drops WindowManager.LayoutParams.screenBrightness
     * to its minimum. Independent of FLAG_KEEP_SCREEN_ON, which stays on
     * unconditionally regardless of this toggle.
     */
    private fun applyDim(enabled: Boolean) {
        val attrs = window.attributes
        attrs.screenBrightness =
            if (enabled) WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_OFF else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        window.attributes = attrs
    }

    private fun showPairingCodeDialog(code: String) {
        val dialog = Dialog(this, R.style.Theme_PenBoard_FullScreenDialog)
        dialog.setContentView(R.layout.dialog_pairing_code)
        dialog.window?.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
        dialog.setCancelable(false)
        dialog.findViewById<TextView>(R.id.pairingCodeText).text = code
        dialog.show()
        pairingDialog?.dismiss()
        pairingDialog = dialog
    }

    private fun enterFullScreen() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }
}
