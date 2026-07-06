package it.aisma.penboard.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class PadCoordinateMapperTest {

    private val delta = 0.01f

    @Test
    fun `exact 16-10 view has no letterboxing`() {
        val rect = PadCoordinateMapper.activeRect(1600, 1000)
        assertEquals(0f, rect.left, delta)
        assertEquals(0f, rect.top, delta)
        assertEquals(1600f, rect.width, delta)
        assertEquals(1000f, rect.height, delta)
    }

    @Test
    fun `wider-than-16-10 view letterboxes left and right`() {
        // A 2000x1000 view has aspect 2.0, wider than 16:10 (1.6) -> pillarbox on the sides.
        val rect = PadCoordinateMapper.activeRect(2000, 1000)
        assertEquals(0f, rect.top, delta)
        assertEquals(1000f, rect.height, delta)
        assertEquals(1600f, rect.width, delta) // 1000 * 16/10
        assertEquals(200f, rect.left, delta) // centered: (2000 - 1600) / 2
    }

    @Test
    fun `taller-than-16-10 view letterboxes top and bottom`() {
        // A 1000x2000 view is taller than 16:10 -> letterbox top/bottom.
        val rect = PadCoordinateMapper.activeRect(1000, 2000)
        assertEquals(0f, rect.left, delta)
        assertEquals(1000f, rect.width, delta)
        assertEquals(625f, rect.height, delta) // 1000 * 10/16
        assertEquals(687.5f, rect.top, delta) // centered: (2000 - 625) / 2
    }

    @Test
    fun `normalize maps rect corners to protocol extremes`() {
        val rect = PadCoordinateMapper.ActiveRect(left = 100f, top = 50f, width = 1600f, height = 1000f)

        val topLeft = PadCoordinateMapper.normalize(100f, 50f, rect)
        assertEquals(0 to 0, topLeft)

        val bottomRight = PadCoordinateMapper.normalize(1700f, 1050f, rect)
        assertEquals(65535 to 65535, bottomRight)

        val center = PadCoordinateMapper.normalize(900f, 550f, rect)
        assertEquals(32768 to 32768, center) // 0.5 * 65535 = 32767.5, ties round up
    }

    @Test
    fun `normalize clamps points outside the active rect`() {
        val rect = PadCoordinateMapper.ActiveRect(left = 0f, top = 0f, width = 1000f, height = 1000f)

        assertEquals(0 to 0, PadCoordinateMapper.normalize(-500f, -500f, rect))
        assertEquals(65535 to 65535, PadCoordinateMapper.normalize(5000f, 5000f, rect))
    }
}
