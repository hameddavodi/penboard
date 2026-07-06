package it.aisma.penboard.ui

import kotlin.math.roundToInt

/**
 * Maps PadView pixel coordinates to the protocol's normalized 0-65535 space
 * (PROTOCOL §4), keeping the pad locked to 16:10 regardless of the view's
 * actual aspect ratio by letterboxing (PLAN.md: "Coordinates normalized
 * 0-65535 (both screens 16:10 -> clean absolute mapping)"). Pure Kotlin, no
 * android.* imports, so this is testable on the plain JVM like proto/Packets.kt.
 */
object PadCoordinateMapper {
    private const val ASPECT_WIDTH = 16f
    private const val ASPECT_HEIGHT = 10f

    /** The largest 16:10 rect centered inside the view, in the view's own pixel space. */
    data class ActiveRect(val left: Float, val top: Float, val width: Float, val height: Float)

    fun activeRect(viewWidth: Int, viewHeight: Int): ActiveRect {
        require(viewWidth > 0 && viewHeight > 0) { "view must be measured before computing the active rect" }
        val targetAspect = ASPECT_WIDTH / ASPECT_HEIGHT
        val viewAspect = viewWidth.toFloat() / viewHeight.toFloat()
        return if (viewAspect > targetAspect) {
            // view wider than 16:10 -> letterbox left/right
            val activeWidth = viewHeight * targetAspect
            val left = (viewWidth - activeWidth) / 2f
            ActiveRect(left, 0f, activeWidth, viewHeight.toFloat())
        } else {
            // view taller than (or exactly) 16:10 -> letterbox top/bottom
            val activeHeight = viewWidth / targetAspect
            val top = (viewHeight - activeHeight) / 2f
            ActiveRect(0f, top, viewWidth.toFloat(), activeHeight)
        }
    }

    /** Normalizes (x, y) in the same pixel space as [rect] to protocol 0-65535, clamped to the rect's bounds. */
    fun normalize(x: Float, y: Float, rect: ActiveRect): Pair<Int, Int> {
        val nx = (((x - rect.left) / rect.width) * 65535f).roundToInt().coerceIn(0, 65535)
        val ny = (((y - rect.top) / rect.height) * 65535f).roundToInt().coerceIn(0, 65535)
        return nx to ny
    }
}
