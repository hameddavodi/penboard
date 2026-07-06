package it.aisma.penboard.ui

import it.aisma.penboard.proto.PointEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * M2.1 verify (docs/EXECUTION-PLAN.md): "MotionEvent fixture -> expected point
 * list including historical samples and flag bits." android.view.MotionEvent
 * cannot be constructed on the plain JVM without Robolectric (not permitted --
 * PadView/StylusPointExtractor.kt isolates the extraction logic behind the
 * [StylusEventSample] interface for exactly this reason), so [FakeSample]
 * below plays the role of a MotionEvent fixture.
 */
class StylusPointExtractorTest {

    /** A 1000x1000 pad rect makes the normalization arithmetic easy to hand-check. */
    private val rect = PadCoordinateMapper.ActiveRect(left = 0f, top = 0f, width = 1000f, height = 1000f)

    private class FakeSample(
        override val toolType: Int,
        override val actionMasked: Int,
        override val buttonState: Int = 0,
        override val x: Float = 0f,
        override val y: Float = 0f,
        override val pressure: Float = 0f,
        private val history: List<Triple<Float, Float, Float>> = emptyList(),
    ) : StylusEventSample {
        override val historySize: Int = history.size

        override fun historicalX(pos: Int): Float = history[pos].first

        override fun historicalY(pos: Int): Float = history[pos].second

        override fun historicalPressure(pos: Int): Float = history[pos].third
    }

    @Test
    fun `stylus PEN_DOWN with no history yields one normalized point`() {
        val sample =
            FakeSample(
                toolType = StylusConstants.TOOL_TYPE_STYLUS,
                actionMasked = StylusConstants.ACTION_DOWN,
                x = 500f,
                y = 250f,
                pressure = 0.5f,
            )
        val points = StylusPointExtractor.extract(sample, rect)

        assertEquals(1, points.size)
        val p = points[0]
        assertEquals(PointEvent.PEN_DOWN, p.event)
        assertEquals(32768, p.x) // 500/1000 * 65535 = 32767.5, ties round up
        assertEquals(16384, p.y) // 250/1000 * 65535 = 16383.75
        assertEquals(32768, p.pressure) // 0.5 * 65535 = 32767.5
        assertFalse(p.barrelButtonHeld)
    }

    @Test
    fun `historical samples are emitted before the current sample, in order`() {
        val sample =
            FakeSample(
                toolType = StylusConstants.TOOL_TYPE_STYLUS,
                actionMasked = StylusConstants.ACTION_MOVE,
                x = 1000f,
                y = 1000f,
                pressure = 1.0f,
                history =
                    listOf(
                        Triple(100f, 100f, 0.1f),
                        Triple(200f, 200f, 0.2f),
                        Triple(300f, 300f, 0.3f),
                    ),
            )
        val points = StylusPointExtractor.extract(sample, rect)

        assertEquals(4, points.size) // 3 historical + 1 current
        assertEquals(listOf(6554, 13107, 19661, 65535), points.map { it.x }) // 0.1,0.2,0.3,1.0 * 65535
        assertEquals(listOf(6554, 13107, 19661, 65535), points.map { it.y })
        assertEquals(listOf(6554, 13107, 19661, 65535), points.map { it.pressure })
        assertTrue(points.all { it.event == PointEvent.PEN_MOVE })
    }

    @Test
    fun `barrel button held sets the eraser-barrel flag bit on every extracted point`() {
        val sample =
            FakeSample(
                toolType = StylusConstants.TOOL_TYPE_STYLUS,
                actionMasked = StylusConstants.ACTION_MOVE,
                buttonState = StylusConstants.BUTTON_STYLUS_PRIMARY,
                history = listOf(Triple(10f, 10f, 0.5f)),
            )
        val points = StylusPointExtractor.extract(sample, rect)

        assertEquals(2, points.size)
        assertTrue(points.all { it.barrelButtonHeld })
    }

    @Test
    fun `eraser tool type sets the barrel-eraser flag bit even without the barrel button`() {
        val sample =
            FakeSample(
                toolType = StylusConstants.TOOL_TYPE_ERASER,
                actionMasked = StylusConstants.ACTION_DOWN,
                buttonState = 0,
            )
        val points = StylusPointExtractor.extract(sample, rect)

        assertEquals(1, points.size)
        assertTrue(points[0].barrelButtonHeld)
    }

    @Test
    fun `finger and mouse tool types are ignored -- palm rejection`() {
        val finger =
            FakeSample(toolType = StylusConstants.TOOL_TYPE_FINGER, actionMasked = StylusConstants.ACTION_DOWN)
        val mouse = FakeSample(toolType = StylusConstants.TOOL_TYPE_MOUSE, actionMasked = StylusConstants.ACTION_DOWN)

        assertTrue(StylusPointExtractor.extract(finger, rect).isEmpty())
        assertTrue(StylusPointExtractor.extract(mouse, rect).isEmpty())
    }

    @Test
    fun `hover actions map to HOVER_ENTER, HOVER_MOVE and HOVER_EXIT`() {
        val enter = FakeSample(toolType = StylusConstants.TOOL_TYPE_STYLUS, actionMasked = StylusConstants.ACTION_HOVER_ENTER)
        val move = FakeSample(toolType = StylusConstants.TOOL_TYPE_STYLUS, actionMasked = StylusConstants.ACTION_HOVER_MOVE)
        val exit = FakeSample(toolType = StylusConstants.TOOL_TYPE_STYLUS, actionMasked = StylusConstants.ACTION_HOVER_EXIT)

        assertEquals(PointEvent.HOVER_ENTER, StylusPointExtractor.extract(enter, rect).single().event)
        assertEquals(PointEvent.HOVER_MOVE, StylusPointExtractor.extract(move, rect).single().event)
        assertEquals(PointEvent.HOVER_EXIT, StylusPointExtractor.extract(exit, rect).single().event)
    }

    @Test
    fun `hover samples force pressure to zero even if the digitizer reports a nonzero reading`() {
        val sample =
            FakeSample(
                toolType = StylusConstants.TOOL_TYPE_STYLUS,
                actionMasked = StylusConstants.ACTION_HOVER_MOVE,
                pressure = 0.6f,
                history = listOf(Triple(10f, 10f, 0.4f)),
            )
        val points = StylusPointExtractor.extract(sample, rect)

        assertEquals(2, points.size)
        assertTrue(points.all { it.pressure == 0 })
    }

    @Test
    fun `ACTION_UP and ACTION_CANCEL both map to PEN_UP`() {
        val up = FakeSample(toolType = StylusConstants.TOOL_TYPE_STYLUS, actionMasked = StylusConstants.ACTION_UP)
        val cancel = FakeSample(toolType = StylusConstants.TOOL_TYPE_STYLUS, actionMasked = StylusConstants.ACTION_CANCEL)

        assertEquals(PointEvent.PEN_UP, StylusPointExtractor.extract(up, rect).single().event)
        assertEquals(PointEvent.PEN_UP, StylusPointExtractor.extract(cancel, rect).single().event)
    }

    @Test
    fun `an unmapped action on a stylus is ignored rather than crashing`() {
        val unmapped = FakeSample(toolType = StylusConstants.TOOL_TYPE_STYLUS, actionMasked = 5) // ACTION_POINTER_DOWN
        assertTrue(StylusPointExtractor.extract(unmapped, rect).isEmpty())
    }

    @Test
    fun `points outside the active rect are clamped, not dropped`() {
        val sample =
            FakeSample(toolType = StylusConstants.TOOL_TYPE_STYLUS, actionMasked = StylusConstants.ACTION_MOVE, x = -50f, y = 5000f)
        val points = StylusPointExtractor.extract(sample, rect)

        assertEquals(1, points.size)
        assertEquals(0, points[0].x)
        assertEquals(65535, points[0].y)
    }
}
