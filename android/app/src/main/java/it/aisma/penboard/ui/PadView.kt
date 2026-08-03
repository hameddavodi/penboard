package it.aisma.penboard.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import it.aisma.penboard.proto.PenPoint
import it.aisma.penboard.proto.PointEvent

/**
 * Full-screen drawing pad (M2.1): captures S Pen [MotionEvent]s (stylus and
 * eraser tool types only -- palm rejection, EXECUTION-PLAN 2.1), mirrors ink
 * locally, and forwards every extracted [PenPoint] to [onPoint] in order for
 * the BLE STREAM path (wired to NotifyQueue/PenGattServer by MainActivity).
 *
 * MotionEvent -> PenPoint extraction itself lives in [StylusPointExtractor]
 * (pure Kotlin, unit-tested on the plain JVM); this class only adapts real
 * MotionEvents to that pure interface via [AndroidStylusEventSample] and owns
 * the Android-side concerns: local ink rendering, the pad's letterboxed
 * 16:10 active rect (PLAN.md), and whole-stroke barrel/eraser removal
 * (decision D3 -- mirrors what the Mac does with the same flag bit).
 */
class PadView
@JvmOverloads
constructor(context: Context, attrs: AttributeSet? = null, defStyleAttr: Int = 0) :
    View(context, attrs, defStyleAttr) {

    /** Invoked for every point extracted from a stylus/eraser MotionEvent, in order. */
    var onPoint: ((PenPoint) -> Unit)? = null

    /**
     * Invoked when a size change (rotation -- the manifest opts out of activity
     * recreation via configChanges) forced the local ink to be dropped: stroke
     * samples are stored in absolute view pixels, so old geometry is meaningless
     * in the new layout. MainActivity uses this to send CLEAR to the Mac,
     * keeping the two mirrors in sync (the Mac clears on its own display
     * changes the same way).
     */
    var onInkInvalidated: (() -> Unit)? = null

    private var activeRect = PadCoordinateMapper.ActiveRect(0f, 0f, 1f, 1f)
    private val strokes = ArrayList<InkStroke>()
    private var currentStroke: InkStroke? = null
    private var currentGestureIsErase = false
    private var mode = PenBoardPrefs.MODE_DRAW

    private var currentColor = Palette.colorFor(Palette.DEFAULT_INDEX)
    private var currentBaseWidthPx = dpToPx(PenBoardPrefs.DEFAULT_WIDTH.toFloat())

    private val strokePaint =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
    private val letterboxPaint = Paint().apply { color = Color.BLACK }

    // Completed-stroke render cache. Without it, onDraw() re-draws every segment
    // of every stroke on every frame, and invalidate() fires once per incoming
    // point -- so a long session degrades to visible lag. Instead, completed
    // strokes are baked once into this offscreen bitmap; each frame blits the
    // bitmap plus only the in-progress stroke, keeping per-frame cost flat.
    private var cacheBitmap: Bitmap? = null
    private var cacheCanvas: Canvas? = null
    /** Count of leading [strokes] already baked into [cacheBitmap]. */
    private var bakedStrokeCount = 0

    private val eraserRadiusPx: Float
        get() = ERASER_RADIUS_DP * resources.displayMetrics.density

    fun setColorIndex(index: Int) {
        currentColor = Palette.colorFor(index)
    }

    fun setBaseWidth(width: Int) {
        currentBaseWidthPx = dpToPx(width.toFloat())
    }

    /**
     * Mode-aware ink mirroring (PROTOCOL §4): in Laser mode, points still
     * STREAM to the Mac as usual, but the tablet must not mirror ink locally
     * -- laser-pointer gestures would otherwise leave phantom local strokes
     * that diverge from the Mac's laser cursor/click behavior.
     */
    fun setMode(newMode: Int) {
        mode = newMode
    }

    /** UNDO (PROTOCOL §5): removes the last *completed* stroke; a stroke still in progress is untouched. */
    fun undoLastStroke() {
        if (strokes.isNotEmpty()) {
            strokes.removeAt(strokes.size - 1)
            invalidateCache() // a baked stroke was removed -- rebuild the cache
            invalidate()
        }
    }

    /** CLEAR (PROTOCOL §5): removes every stroke, completed or in progress. */
    fun clearAllStrokes() {
        strokes.clear()
        currentStroke = null
        invalidateCache()
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w > 0 && h > 0) {
            activeRect = PadCoordinateMapper.activeRect(w, h)
            cacheBitmap?.recycle()
            cacheBitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            cacheCanvas = Canvas(cacheBitmap!!)
            bakedStrokeCount = 0
            // Stroke samples live in absolute view pixels (see pixelX/pixelY),
            // so a real size change (rotation) invalidates every stroke's
            // geometry -- re-baking them unchanged would paint displaced ink,
            // including on top of the letterbox bars. Mirrors the Mac's
            // CanvasView.resize(), which clears for exactly this reason.
            if ((oldw > 0 || oldh > 0) && (strokes.isNotEmpty() || currentStroke != null)) {
                strokes.clear()
                currentStroke = null
                onInkInvalidated?.invoke()
            }
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val points = StylusPointExtractor.extract(AndroidStylusEventSample(event), activeRect)
        if (points.isEmpty()) return false
        points.forEach(::handlePoint)
        if (points.any { it.event == PointEvent.PEN_UP }) {
            performClick() // accessibility contract for onTouchEvent overrides; no-op without a click listener
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        val points = StylusPointExtractor.extract(AndroidStylusEventSample(event), activeRect)
        if (points.isEmpty()) return false
        points.forEach(::handlePoint)
        return true
    }

    private fun handlePoint(point: PenPoint) {
        // Laser mode still streams every point to the Mac; it just never
        // mirrors ink locally (D5 -- the Mac renders the laser cursor/clicks
        // instead of a stroke).
        if (mode == PenBoardPrefs.MODE_DRAW) {
            mirrorLocally(point)
        }
        onPoint?.invoke(point)
    }

    private fun mirrorLocally(point: PenPoint) {
        when (point.event) {
            PointEvent.PEN_DOWN -> {
                currentGestureIsErase = point.barrelButtonHeld
                if (currentGestureIsErase) {
                    eraseAt(point)
                } else {
                    val stroke = InkStroke(currentColor)
                    stroke.addSample(pixelX(point), pixelY(point), sampleWidthPx(point))
                    currentStroke = stroke
                }
            }
            PointEvent.PEN_MOVE -> {
                if (currentGestureIsErase) {
                    eraseAt(point)
                } else {
                    currentStroke?.addSample(pixelX(point), pixelY(point), sampleWidthPx(point))
                }
            }
            PointEvent.PEN_UP -> {
                if (currentGestureIsErase) {
                    eraseAt(point)
                } else {
                    currentStroke?.let { if (it.sampleCount > 0) strokes.add(it) }
                }
                currentStroke = null
                currentGestureIsErase = false
            }
            else -> return // hover events never mirror to ink
        }
        invalidate()
    }

    /** Erases exactly one stroke per event -- the topmost (last-drawn) one under the contact point, matching the Mac. */
    private fun eraseAt(point: PenPoint) {
        val x = pixelX(point)
        val y = pixelY(point)
        val topmostIndex = strokes.indexOfLast { it.hitTest(x, y, eraserRadiusPx) }
        if (topmostIndex != -1) {
            strokes.removeAt(topmostIndex)
            invalidateCache() // a baked stroke was removed -- rebuild the cache
            invalidate()
        }
    }

    /** Reverses [PadCoordinateMapper.normalize] to get back to view pixel space for local rendering. */
    private fun pixelX(point: PenPoint): Float = activeRect.left + (point.x / 65535f) * activeRect.width

    private fun pixelY(point: PenPoint): Float = activeRect.top + (point.y / 65535f) * activeRect.height

    private fun sampleWidthPx(point: PenPoint): Float {
        val pressureFraction = (point.pressure / 65535f).coerceIn(0f, 1f)
        return currentBaseWidthPx * (MIN_WIDTH_SCALE + (MAX_WIDTH_SCALE - MIN_WIDTH_SCALE) * pressureFraction)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        drawLetterboxBars(canvas)
        bakeCommittedStrokes()
        cacheBitmap?.let { canvas.drawBitmap(it, 0f, 0f, null) }
        currentStroke?.draw(canvas, strokePaint)
    }

    /**
     * Bakes every completed stroke not yet in [cacheBitmap]. Runs only when new
     * strokes have been added since the last frame; while a stroke is in
     * progress nothing bakes, so each frame just blits the bitmap plus the live
     * [currentStroke].
     */
    private fun bakeCommittedStrokes() {
        val target = cacheCanvas ?: return
        while (bakedStrokeCount < strokes.size) {
            strokes[bakedStrokeCount].draw(target, strokePaint)
            bakedStrokeCount++
        }
    }

    /** Clears the cache after a removal (undo/erase/clear) so it re-bakes the remaining strokes. */
    private fun invalidateCache() {
        cacheBitmap?.eraseColor(Color.TRANSPARENT)
        bakedStrokeCount = 0
    }

    private fun drawLetterboxBars(canvas: Canvas) {
        if (activeRect.left > 0f) {
            canvas.drawRect(0f, 0f, activeRect.left, height.toFloat(), letterboxPaint)
            canvas.drawRect(activeRect.left + activeRect.width, 0f, width.toFloat(), height.toFloat(), letterboxPaint)
        }
        if (activeRect.top > 0f) {
            canvas.drawRect(0f, 0f, width.toFloat(), activeRect.top, letterboxPaint)
            canvas.drawRect(0f, activeRect.top + activeRect.height, width.toFloat(), height.toFloat(), letterboxPaint)
        }
    }

    private fun dpToPx(dp: Float): Float = dp * resources.displayMetrics.density

    companion object {
        private const val MIN_WIDTH_SCALE = 0.25f
        private const val MAX_WIDTH_SCALE = 1.75f
        private const val ERASER_RADIUS_DP = 16f
    }
}

/**
 * Adapts a real [MotionEvent] to [StylusEventSample] so the pure
 * [StylusPointExtractor] logic runs identically here and in plain-JVM tests.
 *
 * The stylus is NOT always pointer index 0: when a palm/finger lands before
 * the pen, the pen arrives at a higher index, and when the stylus lifts while
 * another pointer is still down its lift is ACTION_POINTER_UP rather than
 * ACTION_UP. This adapter (a) locates the stylus/eraser pointer by tool type
 * and reads all coordinates from that index, and (b) translates
 * ACTION_POINTER_DOWN/UP *of the stylus pointer* into plain DOWN/UP so the
 * extractor emits the PEN_DOWN/PEN_UP the protocol requires. Multi-pointer
 * transitions of non-stylus pointers keep their raw action, which the
 * extractor ignores -- that remains the palm-rejection path.
 */
private class AndroidStylusEventSample(private val event: MotionEvent) : StylusEventSample {
    private val pointerIndex: Int =
        (0 until event.pointerCount).firstOrNull {
            event.getToolType(it) == MotionEvent.TOOL_TYPE_STYLUS ||
                event.getToolType(it) == MotionEvent.TOOL_TYPE_ERASER
        } ?: 0

    override val toolType: Int
        get() = event.getToolType(pointerIndex)

    override val actionMasked: Int
        get() =
            when (event.actionMasked) {
                MotionEvent.ACTION_POINTER_DOWN ->
                    if (event.actionIndex == pointerIndex) MotionEvent.ACTION_DOWN else event.actionMasked
                MotionEvent.ACTION_POINTER_UP ->
                    if (event.actionIndex == pointerIndex) MotionEvent.ACTION_UP else event.actionMasked
                else -> event.actionMasked
            }

    override val buttonState: Int
        get() = event.buttonState

    override val historySize: Int
        get() = event.historySize

    override val x: Float
        get() = event.getX(pointerIndex)

    override val y: Float
        get() = event.getY(pointerIndex)

    override val pressure: Float
        get() = event.getPressure(pointerIndex)

    override fun historicalX(pos: Int): Float = event.getHistoricalX(pointerIndex, pos)

    override fun historicalY(pos: Int): Float = event.getHistoricalY(pointerIndex, pos)

    override fun historicalPressure(pos: Int): Float = event.getHistoricalPressure(pointerIndex, pos)
}
