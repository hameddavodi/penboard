package it.aisma.penboard.stream

// Pure Kotlin -- zero android.* imports -- testable on the plain JVM, mirroring
// proto/Packets.kt. Incrementally parses the Mac's MJPEG multipart stream
// (docs/EXECUTION-PLAN.md v1.1, contract C3) as bytes arrive off a raw socket
// in arbitrary chunks. The whole thing runs off one accumulating buffer that
// is re-scanned from its front on every feed() call, so a boundary/header/body
// terminator split across two socket reads "just works" without any special
// cross-call bookkeeping beyond the buffer itself.

/** Part header block hard cap (schema-validation of external input, AISMA) -- a legitimate part header is a few dozen bytes. */
const val MJPEG_MAX_HEADER_BLOCK_BYTES: Int = 2 * 1024

/** Single-frame hard cap (C4 targets a JPEG well under 1 MB; this is a generous ceiling, not a real budget). */
const val MJPEG_MAX_FRAME_BYTES: Int = 4 * 1024 * 1024

private val BOUNDARY = "--pbframe".toByteArray(Charsets.US_ASCII)
private val HEADER_TERMINATOR = "\r\n\r\n".toByteArray(Charsets.US_ASCII)
private val SCAN_TERMINATOR = "\r\n--pbframe".toByteArray(Charsets.US_ASCII)
private const val CONTENT_LENGTH_PREFIX = "content-length:"
private const val INITIAL_BUFFER_BYTES = 16 * 1024

/**
 * Incremental push-parser for one MJPEG connection: feed bytes as they arrive
 * off the socket via [feed], get complete JPEG frames back through [onFrame],
 * in order. One instance per connection; not thread-safe (matches
 * ble/NotifyQueue's contract -- callers must serialize their own feed() calls,
 * which is naturally true here since MjpegClient pumps bytes from a single
 * background thread, PLAN B3).
 *
 * States mirror C3's wire shape: hunt for the next "--pbframe" boundary (any
 * bytes before it, including a stray CRLF left over from the previous part,
 * are tolerated garbage) -> read the part's headers up to the blank line,
 * extracting Content-Length if present -> read the body either by that
 * declared length (fast path) or, if absent/invalid/oversized, by scanning
 * for the next "\r\n--pbframe" terminator (C3's robustness fallback).
 */
class MjpegParser(private val onFrame: (ByteArray) -> Unit) {

    private enum class State {
        SEEKING_BOUNDARY,
        READING_HEADERS,
        READING_BODY_BY_LENGTH,
        READING_BODY_BY_SCAN,
    }

    private var state = State.SEEKING_BOUNDARY
    private var buf = ByteArray(INITIAL_BUFFER_BYTES)
    private var count = 0
    private var bodyRemaining = 0

    fun feed(bytes: ByteArray, len: Int) {
        append(bytes, len)
        while (step()) {
            // Drain every complete frame/state transition the buffer currently
            // allows -- a single feed() call can yield several frames at once
            // (e.g. two frames landing in the same socket read).
        }
    }

    private fun step(): Boolean =
        when (state) {
            State.SEEKING_BOUNDARY -> seekBoundary()
            State.READING_HEADERS -> readHeaders()
            State.READING_BODY_BY_LENGTH -> readBodyByLength()
            State.READING_BODY_BY_SCAN -> readBodyByScan()
        }

    private fun seekBoundary(): Boolean {
        val idx = indexOf(BOUNDARY)
        if (idx == -1) {
            // Keep only enough of the tail to catch a boundary token split
            // across the next feed() call -- unbounded garbage before the
            // first boundary must not grow the buffer forever.
            trimFrontKeepingTail(BOUNDARY.size - 1)
            return false
        }
        consumeFront(idx + BOUNDARY.size)
        state = State.READING_HEADERS
        return true
    }

    private fun readHeaders(): Boolean {
        val idx = indexOf(HEADER_TERMINATOR)
        if (idx == -1) {
            if (count > MJPEG_MAX_HEADER_BLOCK_BYTES) {
                // Not a legitimate part header -- resync without discarding
                // the buffer, in case it already contains the *next* real
                // boundary further along.
                state = State.SEEKING_BOUNDARY
                return true
            }
            return false
        }
        val contentLength = parseContentLength(idx)
        consumeFront(idx + HEADER_TERMINATOR.size)
        if (contentLength != null && contentLength in 0..MJPEG_MAX_FRAME_BYTES) {
            bodyRemaining = contentLength
            state = State.READING_BODY_BY_LENGTH
        } else {
            // Missing, unparsable, or oversized Content-Length (C3 fallback
            // rule): scan for the next boundary instead of trusting a length.
            state = State.READING_BODY_BY_SCAN
        }
        return true
    }

    private fun readBodyByLength(): Boolean {
        if (count < bodyRemaining) return false
        emitFrame(bodyRemaining)
        state = State.SEEKING_BOUNDARY
        return true
    }

    private fun readBodyByScan(): Boolean {
        val idx = indexOf(SCAN_TERMINATOR)
        if (idx == -1) {
            if (count > MJPEG_MAX_FRAME_BYTES) {
                // Oversized part with no usable length -- give up on it and
                // resync on the next boundary (hard cap: "reset to seeking").
                state = State.SEEKING_BOUNDARY
                return true
            }
            return false
        }
        emitFrame(idx)
        consumeFront(2) // drop the trailing CRLF; "--pbframe" itself stays buffered for the next seekBoundary()
        state = State.SEEKING_BOUNDARY
        return true
    }

    private fun emitFrame(length: Int) {
        val frame = buf.copyOfRange(0, length)
        consumeFront(length)
        onFrame(frame)
    }

    private fun parseContentLength(headerBlockEnd: Int): Int? {
        val headerText = String(buf, 0, headerBlockEnd, Charsets.US_ASCII)
        for (line in headerText.split("\r\n")) {
            val trimmed = line.trim()
            if (trimmed.lowercase().startsWith(CONTENT_LENGTH_PREFIX)) {
                return trimmed.substring(CONTENT_LENGTH_PREFIX.length).trim().toIntOrNull()
            }
        }
        return null
    }

    // --- buffer plumbing: one growable array, always scanned from index 0 ---

    private fun append(bytes: ByteArray, len: Int) {
        if (count + len > buf.size) {
            var newSize = buf.size * 2
            while (newSize < count + len) newSize *= 2
            buf = buf.copyOf(newSize)
        }
        System.arraycopy(bytes, 0, buf, count, len)
        count += len
    }

    private fun consumeFront(n: Int) {
        if (n >= count) {
            count = 0
            return
        }
        System.arraycopy(buf, n, buf, 0, count - n)
        count -= n
    }

    private fun trimFrontKeepingTail(tailSize: Int) {
        if (count <= tailSize) return
        consumeFront(count - tailSize)
    }

    private fun indexOf(pattern: ByteArray): Int {
        val last = count - pattern.size
        outer@ for (i in 0..last) {
            for (j in pattern.indices) {
                if (buf[i + j] != pattern[j]) continue@outer
            }
            return i
        }
        return -1
    }
}
