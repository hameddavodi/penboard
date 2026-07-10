package it.aisma.penboard.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit

/**
 * Persists the toolbar/pad state that should survive process death and app
 * restarts (EXECUTION-PLAN M4.1): color, width, mode, dim-screen toggle. The
 * Mac is the authoritative source once connected (STATE_SYNC overwrites these
 * on every (re)connect, PROTOCOL §5/§6), but the tablet needs a sane default
 * before that first sync and while offline.
 */
class PenBoardPrefs(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var mode: Int
        get() = prefs.getInt(KEY_MODE, MODE_DRAW)
        set(value) = prefs.edit { putInt(KEY_MODE, value) }

    var colorIndex: Int
        get() = prefs.getInt(KEY_COLOR, Palette.DEFAULT_INDEX)
        set(value) = prefs.edit { putInt(KEY_COLOR, value) }

    var widthBase: Int
        get() = prefs.getInt(KEY_WIDTH, DEFAULT_WIDTH)
        set(value) = prefs.edit { putInt(KEY_WIDTH, value) }

    var dimEnabled: Boolean
        get() = prefs.getBoolean(KEY_DIM, false)
        set(value) = prefs.edit { putBoolean(KEY_DIM, value) }

    /** Mac screen-stream toggle (EXECUTION-PLAN v1.1, B5) -- tablet-side only; independent of the Mac's own toggle (C6). */
    var streamEnabled: Boolean
        get() = prefs.getBoolean(KEY_STREAM, false)
        set(value) = prefs.edit { putBoolean(KEY_STREAM, value) }

    companion object {
        private const val PREFS_NAME = "penboard_settings"
        private const val KEY_MODE = "mode"
        private const val KEY_COLOR = "color_index"
        private const val KEY_WIDTH = "width_base"
        private const val KEY_DIM = "dim_enabled"
        private const val KEY_STREAM = "stream_enabled"

        /** SET_MODE payload values (PROTOCOL §5). */
        const val MODE_DRAW = 0
        const val MODE_LASER = 1

        const val DEFAULT_WIDTH = 6
    }
}
