package it.aisma.penboard.stream

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Golden vectors + chunk-split matrix from docs/EXECUTION-PLAN.md v1.1, C3 +
 * B1. Every assertion here exercises the exact wire shape both sides agree
 * on: "--pbframe\r\n" + part headers + blank line + JPEG bytes + trailing
 * "\r\n" before the next boundary.
 */
class MjpegParserTest {

    private fun part(jpeg: ByteArray, includeContentLength: Boolean = true): ByteArray {
        val header = buildString {
            append("--pbframe\r\n")
            append("Content-Type: image/jpeg\r\n")
            if (includeContentLength) append("Content-Length: ${jpeg.size}\r\n")
            append("\r\n")
        }
        return header.toByteArray(Charsets.US_ASCII) + jpeg + "\r\n".toByteArray(Charsets.US_ASCII)
    }

    private fun collectingParser(): Pair<MjpegParser, MutableList<ByteArray>> {
        val frames = mutableListOf<ByteArray>()
        return MjpegParser { frame -> frames.add(frame) } to frames
    }

    @Test
    fun `single frame with Content-Length is emitted byte-exact`() {
        val (parser, frames) = collectingParser()
        val jpeg = byteArrayOf(1, 2, 3, 4, 5)
        val bytes = part(jpeg)

        parser.feed(bytes, bytes.size)

        assertEquals(1, frames.size)
        assertTrue(jpeg.contentEquals(frames[0]))
    }

    @Test
    fun `two frames in one feed call are emitted in order`() {
        val (parser, frames) = collectingParser()
        val jpeg1 = byteArrayOf(10, 20, 30)
        val jpeg2 = byteArrayOf(40, 50)
        val bytes = part(jpeg1) + part(jpeg2)

        parser.feed(bytes, bytes.size)

        assertEquals(2, frames.size)
        assertTrue(jpeg1.contentEquals(frames[0]))
        assertTrue(jpeg2.contentEquals(frames[1]))
    }

    @Test
    fun `frame split across arbitrary chunk boundaries still parses`() {
        val jpeg = byteArrayOf(7, 8, 9, 10, 11, 12, 13)
        val bytes = part(jpeg)

        // Every possible split point, including mid-boundary-token and
        // mid-CRLF (e.g. inside "--pbframe" itself, inside the blank-line
        // terminator, and inside the trailing CRLF after the body).
        for (splitPoint in 0..bytes.size) {
            val (parser, frames) = collectingParser()
            val first = bytes.copyOfRange(0, splitPoint)
            val second = bytes.copyOfRange(splitPoint, bytes.size)

            parser.feed(first, first.size)
            parser.feed(second, second.size)

            assertEquals("split at $splitPoint produced ${frames.size} frames", 1, frames.size)
            assertTrue("split at $splitPoint", jpeg.contentEquals(frames[0]))
        }
    }

    @Test
    fun `missing Content-Length falls back to boundary scanning`() {
        val (parser, frames) = collectingParser()
        val scanned = byteArrayOf(1, 1, 1)
        val byLength = byteArrayOf(2, 2)
        val bytes = part(scanned, includeContentLength = false) + part(byLength)

        parser.feed(bytes, bytes.size)

        assertEquals(2, frames.size)
        assertTrue(scanned.contentEquals(frames[0]))
        assertTrue(byLength.contentEquals(frames[1]))
    }

    @Test
    fun `oversized frame is rejected and the parser recovers on the next boundary`() {
        val (parser, frames) = collectingParser()

        // A part with no Content-Length whose body never contains the
        // boundary token within the hard cap -- must be dropped, not emitted.
        val header = "--pbframe\r\nContent-Type: image/jpeg\r\n\r\n".toByteArray(Charsets.US_ASCII)
        val filler = ByteArray(MJPEG_MAX_FRAME_BYTES + 1) { 'A'.code.toByte() }
        parser.feed(header, header.size)
        parser.feed(filler, filler.size)
        assertEquals(0, frames.size)

        // A legitimate part right after must still parse cleanly.
        val recovered = byteArrayOf(9, 8, 7)
        val bytes = part(recovered)
        parser.feed(bytes, bytes.size)

        assertEquals(1, frames.size)
        assertTrue(recovered.contentEquals(frames[0]))
    }

    @Test
    fun `garbage prefix before the first boundary is tolerated`() {
        val (parser, frames) = collectingParser()
        val jpeg = byteArrayOf(42)
        val garbage = "not a boundary at all".toByteArray(Charsets.US_ASCII)
        val bytes = garbage + part(jpeg)

        parser.feed(bytes, bytes.size)

        assertEquals(1, frames.size)
        assertTrue(jpeg.contentEquals(frames[0]))
    }
}
