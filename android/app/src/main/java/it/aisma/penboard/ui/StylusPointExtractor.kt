package it.aisma.penboard.ui

import it.aisma.penboard.proto.PenPoint
import it.aisma.penboard.proto.PointEvent
import kotlin.math.roundToInt

/**
 * Mirrors the subset of android.view.MotionEvent's TOOL_TYPE_, ACTION_ and
 * BUTTON_ public constants that stylus capture needs, kept as plain Int
 * constants so [StylusPointExtractor] has zero android.* imports and stays
 * plain-JVM testable (matches proto/Packets.kt's approach). Values verified
 * against the actual compileSdk 36 android.jar (`javap -constants
 * android.view.MotionEvent`) rather than assumed from memory -- these are
 * long-stable public API values (unchanged since API 1 for DOWN/UP/MOVE,
 * API 9 for hover, API 23 for stylus buttons), so mirroring them here carries
 * no real drift risk. [PadView]'s real adapter ([AndroidStylusEventSample])
 * reads the genuine android.view.MotionEvent constants directly.
 */
object StylusConstants {
    const val TOOL_TYPE_FINGER = 1
    const val TOOL_TYPE_STYLUS = 2
    const val TOOL_TYPE_MOUSE = 3
    const val TOOL_TYPE_ERASER = 4

    const val ACTION_DOWN = 0
    const val ACTION_UP = 1
    const val ACTION_MOVE = 2
    const val ACTION_CANCEL = 3
    const val ACTION_HOVER_MOVE = 7
    const val ACTION_HOVER_ENTER = 9
    const val ACTION_HOVER_EXIT = 10

    const val BUTTON_STYLUS_PRIMARY = 1 shl 5
}

/**
 * Minimal read-only view over one android.view.MotionEvent that
 * [StylusPointExtractor] needs. [PadView] adapts real MotionEvents to this
 * interface; unit tests build plain fakes directly -- MotionEvent itself
 * cannot be constructed off-device without Robolectric, so isolating the
 * extraction logic behind this interface is what makes it testable on the
 * plain JVM (docs/EXECUTION-PLAN.md 2.1 verify).
 */
interface StylusEventSample {
    val toolType: Int
    val actionMasked: Int
    val buttonState: Int
    val historySize: Int
    val x: Float
    val y: Float
    val pressure: Float

    fun historicalX(pos: Int): Float

    fun historicalY(pos: Int): Float

    fun historicalPressure(pos: Int): Float
}

/**
 * Converts one stylus/eraser [StylusEventSample] into ordered protocol
 * [PenPoint]s (PROTOCOL §4), consuming historical samples first so 120-240 Hz
 * input survives MotionEvent batching (EXECUTION-PLAN 2.1). Returns an empty
 * list for any other tool type (finger, mouse) -- this is the palm-rejection
 * mechanism, no separate check needed by callers.
 */
object StylusPointExtractor {
    fun extract(sample: StylusEventSample, rect: PadCoordinateMapper.ActiveRect): List<PenPoint> {
        if (sample.toolType != StylusConstants.TOOL_TYPE_STYLUS && sample.toolType != StylusConstants.TOOL_TYPE_ERASER) {
            return emptyList()
        }
        val event = eventFor(sample.actionMasked) ?: return emptyList()
        val barrelOrEraser =
            sample.toolType == StylusConstants.TOOL_TYPE_ERASER ||
                (sample.buttonState and StylusConstants.BUTTON_STYLUS_PRIMARY) != 0
        val flags = PenPoint.flagsOf(event, barrelOrEraser)
        // PROTOCOL §4: pressure is 0 while hovering, even if the digitizer
        // reports a nonzero hover-height reading for that sample.
        val isHovering = PointEvent.isHover(event)

        val points = ArrayList<PenPoint>(sample.historySize + 1)
        for (pos in 0 until sample.historySize) {
            val pressure = if (isHovering) 0f else sample.historicalPressure(pos)
            points.add(toPenPoint(sample.historicalX(pos), sample.historicalY(pos), pressure, flags, rect))
        }
        val pressure = if (isHovering) 0f else sample.pressure
        points.add(toPenPoint(sample.x, sample.y, pressure, flags, rect))
        return points
    }

    private fun eventFor(actionMasked: Int): Int? =
        when (actionMasked) {
            StylusConstants.ACTION_DOWN -> PointEvent.PEN_DOWN
            StylusConstants.ACTION_MOVE -> PointEvent.PEN_MOVE
            StylusConstants.ACTION_UP, StylusConstants.ACTION_CANCEL -> PointEvent.PEN_UP
            StylusConstants.ACTION_HOVER_MOVE -> PointEvent.HOVER_MOVE
            StylusConstants.ACTION_HOVER_ENTER -> PointEvent.HOVER_ENTER
            StylusConstants.ACTION_HOVER_EXIT -> PointEvent.HOVER_EXIT
            else -> null
        }

    private fun toPenPoint(
        x: Float,
        y: Float,
        pressure: Float,
        flags: Int,
        rect: PadCoordinateMapper.ActiveRect,
    ): PenPoint {
        val (nx, ny) = PadCoordinateMapper.normalize(x, y, rect)
        val np = (pressure.coerceIn(0f, 1f) * 65535f).roundToInt()
        return PenPoint(nx, ny, np, flags)
    }
}
