package it.aisma.penboard.stream

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** B3 verify (docs/EXECUTION-PLAN.md v1.1): the pure status-line validator. */
class MjpegStatusLineTest {

    @Test
    fun `exact C3 status line is ok`() {
        assertTrue(MjpegStatusLine.isOk("HTTP/1.1 200 OK"))
    }

    @Test
    fun `200 with a different reason phrase is still ok`() {
        assertTrue(MjpegStatusLine.isOk("HTTP/1.1 200 Something Else"))
    }

    @Test
    fun `404 is rejected`() {
        assertFalse(MjpegStatusLine.isOk("HTTP/1.1 404 Not Found"))
    }

    @Test
    fun `a status code merely starting with 200 digits is rejected`() {
        assertFalse(MjpegStatusLine.isOk("HTTP/1.1 2001 OK"))
    }

    @Test
    fun `wrong HTTP version is rejected`() {
        assertFalse(MjpegStatusLine.isOk("HTTP/1.0 200 OK"))
    }

    @Test
    fun `garbage is rejected`() {
        assertFalse(MjpegStatusLine.isOk("not an http response"))
        assertFalse(MjpegStatusLine.isOk(""))
    }
}
