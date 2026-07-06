package it.aisma.penboard.ui

import android.graphics.Canvas
import android.graphics.Paint
import kotlin.math.max
import kotlin.math.sqrt

/**
 * One locally-mirrored ink stroke (M2.1 local ink mirror). Stored as a list
 * of (x, y, widthPx) samples rather than a single [android.graphics.Path]
 * because Path/Paint only support one strokeWidth per drawPath call, and this
 * stroke's width must vary with pressure along its length -- each consecutive
 * pair of samples is drawn as its own line segment with an interpolated
 * width instead.
 *
 * [hitTest] backs the whole-stroke barrel/eraser (decision D3): true if an
 * erase point lands within [radiusPx] of any segment, accounting for that
 * segment's own rendered width.
 */
class InkStroke(private val color: Int) {
    private data class Sample(val x: Float, val y: Float, val widthPx: Float)

    private val samples = ArrayList<Sample>()

    val sampleCount: Int
        get() = samples.size

    fun addSample(x: Float, y: Float, widthPx: Float) {
        samples.add(Sample(x, y, widthPx))
    }

    fun draw(canvas: Canvas, paint: Paint) {
        if (samples.isEmpty()) return
        paint.color = color
        if (samples.size == 1) {
            val s = samples[0]
            paint.strokeWidth = s.widthPx
            canvas.drawPoint(s.x, s.y, paint)
            return
        }
        for (i in 1 until samples.size) {
            val a = samples[i - 1]
            val b = samples[i]
            paint.strokeWidth = (a.widthPx + b.widthPx) / 2f
            canvas.drawLine(a.x, a.y, b.x, b.y, paint)
        }
    }

    fun hitTest(x: Float, y: Float, radiusPx: Float): Boolean {
        if (samples.isEmpty()) return false
        if (samples.size == 1) {
            val s = samples[0]
            return distance(x, y, s.x, s.y) <= radiusPx + s.widthPx / 2f
        }
        for (i in 1 until samples.size) {
            val a = samples[i - 1]
            val b = samples[i]
            val threshold = radiusPx + max(a.widthPx, b.widthPx) / 2f
            if (pointToSegmentDistance(x, y, a.x, a.y, b.x, b.y) <= threshold) return true
        }
        return false
    }

    private fun distance(x1: Float, y1: Float, x2: Float, y2: Float): Float {
        val dx = x1 - x2
        val dy = y1 - y2
        return sqrt(dx * dx + dy * dy)
    }

    private fun pointToSegmentDistance(px: Float, py: Float, ax: Float, ay: Float, bx: Float, by: Float): Float {
        val dx = bx - ax
        val dy = by - ay
        val lengthSquared = dx * dx + dy * dy
        if (lengthSquared == 0f) return distance(px, py, ax, ay)
        val t = (((px - ax) * dx + (py - ay) * dy) / lengthSquared).coerceIn(0f, 1f)
        val projX = ax + t * dx
        val projY = ay + t * dy
        return distance(px, py, projX, projY)
    }
}
