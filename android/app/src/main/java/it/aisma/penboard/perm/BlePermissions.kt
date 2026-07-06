package it.aisma.penboard.perm

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * Runtime permission matrix for the BLE peripheral role (PROTOCOL §1,
 * EXECUTION-PLAN R7): API 29-30 needs the legacy Bluetooth + location trio;
 * API 31+ needs the new BLE-specific permissions (declared `neverForLocation`
 * in the manifest, since this app never derives physical location from BLE).
 */
object BlePermissions {

    /** The permissions this build must hold before advertising/GATT-serving. */
    fun required(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN,
                Manifest.permission.ACCESS_FINE_LOCATION,
            )
        }

    fun missing(context: Context): Array<String> =
        required()
            .filter { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }
            .toTypedArray()

    fun allGranted(context: Context): Boolean = missing(context).isEmpty()
}
