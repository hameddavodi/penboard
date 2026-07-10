package it.aisma.penboard.stream

/**
 * Validates the HTTP response status line the Mac's MJPEG server sends
 * (docs/EXECUTION-PLAN.md v1.1, contract C3: exactly "HTTP/1.1 200 OK").
 * Pure Kotlin -- zero android.* imports -- so it's plain-JVM testable like
 * proto/Packets.kt; [MjpegClient] is the only caller and owns all the real
 * socket I/O. Matches on the status code rather than the exact reason
 * phrase -- the code is the part of the contract that matters.
 */
object MjpegStatusLine {
    private val STATUS_OK_PATTERN = Regex("""^HTTP/1\.1\s+200\b""")

    fun isOk(line: String): Boolean = STATUS_OK_PATTERN.containsMatchIn(line)
}
