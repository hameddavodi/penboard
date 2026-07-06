package it.aisma.penboard.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.os.ParcelUuid
import android.util.Log

/**
 * Wraps [android.bluetooth.le.BluetoothLeAdvertiser] for the PenBoard service
 * (PROTOCOL §1): connectable, low-latency, service UUID in the primary
 * advertisement, local name "PenBoard".
 *
 * Callers must verify [it.aisma.penboard.perm.BlePermissions.allGranted]
 * before calling [start] — the BLUETOOTH_ADVERTISE/BLUETOOTH_CONNECT runtime
 * checks happen one layer up (service), not here, so the @SuppressLint below
 * is a deliberate, narrow suppression rather than ignoring the check.
 */
class PenAdvertiser(private val adapter: BluetoothAdapter) {

    private var activeCallback: AdvertiseCallback? = null

    /** True once this call sequence has changed the adapter's local BT name. */
    private var localNameApplied = false

    /**
     * The adapter's Bluetooth name before this advertiser ever renamed it, so
     * [stop] can put it back. `AdvertiseData.setIncludeDeviceName(true)` has
     * no per-advertisement name of its own -- it broadcasts whatever
     * `BluetoothAdapter.getName()` currently returns (confirmed against the
     * official BluetoothLeAdvertiser/AdvertiseData docs, 2026-07-06: no API
     * scopes a name to just one advertisement), so showing "PenBoard" in the
     * advertisement means renaming the adapter globally -- and that rename
     * must not permanently stick to the user's tablet.
     */
    private var originalName: String? = null

    @SuppressLint("MissingPermission")
    fun start(onResult: (success: Boolean, failureReason: String?) -> Unit) {
        // Always stop any advertising this instance previously started
        // before starting again -- calling startAdvertising a second time
        // without stopping the first is what was producing
        // ADVERTISE_FAILED_ALREADY_STARTED on every reconnect retry.
        stopAdvertisingBroadcast()

        val advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            onResult(false, "BLE advertising not supported on this adapter")
            return
        }

        if (!localNameApplied) {
            originalName = adapter.name
            if (adapter.name != LOCAL_NAME) {
                adapter.name = LOCAL_NAME
            }
            localNameApplied = true
        }

        val settings =
            AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .build()

        // Legacy advertising PDUs are 31 bytes. Flags (3) + 128-bit service
        // UUID (2 + 16) = 21 bytes -- adding the device name (2 + 8) and TX
        // power (3) on top overflows the packet and the stack rejects it with
        // ADVERTISE_FAILED_DATA_TOO_LARGE. The name therefore rides in the
        // scan response, which has its own separate 31-byte budget.
        val data =
            AdvertiseData.Builder()
                .addServiceUuid(ParcelUuid(PenGattServer.SERVICE_UUID))
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .build()

        val scanResponse = AdvertiseData.Builder().setIncludeDeviceName(true).build()

        val callback =
            object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    Log.i(TAG, "advertising started")
                    onResult(true, null)
                }

                override fun onStartFailure(errorCode: Int) {
                    if (errorCode == AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED) {
                        // A previous session is still broadcasting under the
                        // settings/data we just requested (the stop() above
                        // hadn't fully unwound at the BLE stack yet) -- this
                        // is not a real failure, so don't trip the reconnect
                        // backoff loop or report a wrong "failed" status.
                        Log.i(TAG, "advertising already started, treating as success")
                        onResult(true, null)
                        return
                    }
                    val reason = describeFailure(errorCode)
                    Log.w(TAG, "advertising failed to start: $reason")
                    onResult(false, reason)
                }
            }
        activeCallback = callback
        advertiser.startAdvertising(settings, data, scanResponse, callback)
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        stopAdvertisingBroadcast()
        originalName?.let { name ->
            if (adapter.name != name) {
                adapter.name = name
            }
        }
        originalName = null
        localNameApplied = false
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertisingBroadcast() {
        val callback = activeCallback ?: return
        adapter.bluetoothLeAdvertiser?.stopAdvertising(callback)
        activeCallback = null
    }

    companion object {
        private const val TAG = "PenAdvertiser"
        const val LOCAL_NAME = "PenBoard"

        private fun describeFailure(code: Int): String =
            when (code) {
                AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "already started"
                AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "advertise data too large"
                AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "feature unsupported"
                AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "internal error"
                AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "too many advertisers"
                else -> "unknown error code $code"
            }
    }
}
