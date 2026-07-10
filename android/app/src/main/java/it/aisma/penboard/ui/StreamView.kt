package it.aisma.penboard.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.util.TypedValue
import android.view.View

/**
 * Full-screen Mac-screen-stream renderer (EXECUTION-PLAN v1.1 Feature 2,
 * contract C5): fills [PadCoordinateMapper.activeRect] -- the same pure
 * function and inputs [PadView] uses for its own active rect, so the two
 * rects are always byte-identical -- with the latest decoded MJPEG frame,
 * scaled to fill both axes (anisotropic on non-16:10 sources; C5 rationale:
 * pen coordinates already stretch the full active rect onto the full display
 * frame both ways, so fill keeps ink-under-pen aligned with what the user
 * sees -- aspect-fit would misalign every annotation on a non-16:10 display).
 *
 * Sits *under* [PadView] in z-order (activity_main.xml: inserted before
 * padView in the `<merge>`) so ink and PadView's own black letterbox bars
 * stay on top; this view also paints black outside its own active rect
 * (belt and braces, C5) in case it's ever visible before PadView draws.
 *
 * Plain custom View + XML (decision D2, no Compose) -- matches PadView.
 * MainActivity owns this view's visibility/lifecycle alongside
 * [it.aisma.penboard.stream.StreamDiscovery]/[it.aisma.penboard.stream.MjpegClient]
 * (C6: Activity-scoped, not the foreground service).
 */
class StreamView
@JvmOverloads
constructor(context: Context, attrs: AttributeSet? = null, defStyleAttr: Int = 0) :
    View(context, attrs, defStyleAttr) {

    private var activeRect = PadCoordinateMapper.ActiveRect(0f, 0f, 1f, 1f)
    private val activeRectF = RectF()
    private var latestFrame: Bitmap? = null
    private var statusText: String? = null

    private val backgroundPaint = Paint().apply { color = Color.BLACK }
    private val framePaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val statusPaint =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textAlign = Paint.Align.CENTER
            // TypedValue.applyDimension (not DisplayMetrics.scaledDensity,
            // deprecated) so this respects Android 14+'s non-linear large-font
            // accessibility scaling curve, not just a flat multiplier.
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, STATUS_TEXT_SIZE_SP, resources.displayMetrics)
        }

    /** Posts the newest decoded frame for the next draw pass -- caller ([it.aisma.penboard.stream.MjpegClient]) already only ever delivers the newest. */
    fun setFrame(bitmap: Bitmap) {
        latestFrame = bitmap
        invalidate()
    }

    /** Hides the last frame (stream disconnected/toggled off) so a stale image never lingers. */
    fun clear() {
        latestFrame = null
        invalidate()
    }

    /** One-line status (CONNECTING/WAITING, e.g. "Looking for Mac stream…"); null once frames are flowing. No new UI surface (B5) -- drawn directly over the black background. */
    fun setStatus(text: String?) {
        statusText = text
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w > 0 && h > 0) {
            activeRect = PadCoordinateMapper.activeRect(w, h)
            activeRectF.set(
                activeRect.left,
                activeRect.top,
                activeRect.left + activeRect.width,
                activeRect.top + activeRect.height,
            )
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), backgroundPaint)
        val frame = latestFrame
        if (frame != null) {
            canvas.drawBitmap(frame, null, activeRectF, framePaint)
        } else {
            statusText?.let { canvas.drawText(it, width / 2f, height / 2f, statusPaint) }
        }
    }

    companion object {
        private const val STATUS_TEXT_SIZE_SP = 16f
    }
}
