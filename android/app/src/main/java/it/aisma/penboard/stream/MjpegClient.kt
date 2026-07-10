package it.aisma.penboard.stream

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Dials the Mac's MJPEG server (docs/EXECUTION-PLAN.md v1.1, contract C3)
 * over a raw [Socket] -- deliberately not HttpURLConnection/OkHttp: targetSdk
 * 36's cleartext-HTTP policy applies to platform HTTP stacks, not raw
 * sockets, so this avoids any networkSecurityConfig cleartext exemption
 * (R-7). No new dependency either way.
 *
 * One background thread runs for as long as the client is enabled, retrying
 * with exponential backoff (1->2->4->8 s, capped) against whatever endpoint
 * [start] was most recently called with. Callers (MainActivity, wired to
 * [StreamDiscovery]) keep that endpoint fresh across a Mac-side toggle-off/on
 * token rotation (C2), so the next backoff-driven retry naturally reconnects
 * with the right token once one exists again -- this client never re-runs
 * discovery itself.
 *
 * All work happens on this class's own thread (C6): not PenBoardService's,
 * not the main thread.
 */
class MjpegClient(private val listener: Listener) {

    enum class State { CONNECTING, STREAMING, WAITING }

    interface Listener {
        fun onFrame(bitmap: Bitmap)

        fun onStateChanged(state: State)
    }

    private data class Endpoint(val host: String, val port: Int, val token: String)

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var enabled = false
    @Volatile private var currentEndpoint: Endpoint? = null
    private var worker: Thread? = null

    /** Coalescing hand-off to the main thread: only the newest decoded bitmap is ever delivered (C4), never a growing queue. */
    private val framePosted = AtomicBoolean(false)
    @Volatile private var latestBitmap: Bitmap? = null

    /** (Re)starts the client against this endpoint. Safe to call again while already running -- the next (re)connect attempt picks up the new endpoint (token rotation). */
    fun start(host: String, port: Int, token: String) {
        currentEndpoint = Endpoint(host, port, token)
        if (enabled) return
        enabled = true
        val thread = Thread({ runLoop() }, "MjpegClient")
        thread.isDaemon = true
        worker = thread
        thread.start()
    }

    /** Idempotent: safe to call when not running, or twice in a row. */
    fun stop() {
        if (!enabled) return
        enabled = false
        currentEndpoint = null
        worker?.interrupt()
        worker = null
    }

    private fun runLoop() {
        var backoffMs = INITIAL_BACKOFF_MS
        while (enabled) {
            val endpoint = currentEndpoint ?: break
            postState(State.CONNECTING)
            val everStreamed = runSingleConnection(endpoint)
            if (!enabled) break
            // A connection that streamed at least one frame before dropping
            // is more likely a transient blip than a dead endpoint -- retry
            // fast for that case and only back off on outright connect/reject
            // failures (mirrors PenBoardService's reconnectBackoffMs pattern).
            backoffMs = if (everStreamed) INITIAL_BACKOFF_MS else (backoffMs * 2).coerceAtMost(MAX_BACKOFF_MS)
            postState(State.WAITING)
            try {
                Thread.sleep(backoffMs)
            } catch (_: InterruptedException) {
                break
            }
        }
    }

    private fun runSingleConnection(endpoint: Endpoint): Boolean {
        var everStreamed = false
        var socket: Socket? = null
        try {
            socket = Socket()
            socket.soTimeout = READ_TIMEOUT_MS
            socket.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)

            val request = "GET /stream/${endpoint.token} HTTP/1.1\r\nHost: ${endpoint.host}\r\nConnection: close\r\n\r\n"
            val out = socket.getOutputStream()
            out.write(request.toByteArray(Charsets.US_ASCII))
            out.flush()

            val input = socket.getInputStream()
            if (!readAndValidateStatusLine(input)) {
                Log.w(TAG, "stream request rejected (bad status line)")
                return false
            }
            postState(State.STREAMING)

            val parser = MjpegParser { frame -> handleFrame(frame) }
            val chunk = ByteArray(READ_CHUNK_BYTES)
            while (enabled) {
                val n = input.read(chunk)
                if (n == -1) break // EOF -- Mac closed (toggle off, or another client replaced us, C3)
                everStreamed = true
                parser.feed(chunk, n)
            }
        } catch (e: IOException) {
            Log.w(TAG, "stream connection failed: ${e.message}")
        } finally {
            runCatching { socket?.close() }
        }
        return everStreamed
    }

    /** Reads exactly the status line (byte-at-a-time -- a few dozen bytes, once per connection); everything after it, including the rest of the HTTP header block, is left for [MjpegParser] to skip as tolerated garbage before the first boundary (C3). */
    private fun readAndValidateStatusLine(input: InputStream): Boolean {
        val acc = ByteArray(MAX_STATUS_LINE_BYTES)
        var len = 0
        val single = ByteArray(1)
        while (len < MAX_STATUS_LINE_BYTES) {
            if (input.read(single) == -1) return false
            if (single[0] == '\n'.code.toByte()) {
                val end = if (len > 0 && acc[len - 1] == '\r'.code.toByte()) len - 1 else len
                return MjpegStatusLine.isOk(String(acc, 0, end, Charsets.US_ASCII))
            }
            acc[len] = single[0]
            len++
        }
        return false // status line longer than any real response -- reject
    }

    private fun handleFrame(frame: ByteArray) {
        val bitmap = BitmapFactory.decodeByteArray(frame, 0, frame.size) ?: return
        latestBitmap = bitmap
        if (framePosted.compareAndSet(false, true)) {
            mainHandler.post {
                framePosted.set(false)
                latestBitmap?.let { listener.onFrame(it) }
            }
        }
    }

    private fun postState(state: State) {
        mainHandler.post { listener.onStateChanged(state) }
    }

    companion object {
        private const val TAG = "MjpegClient"
        private const val CONNECT_TIMEOUT_MS = 3_000
        private const val READ_TIMEOUT_MS = 10_000
        private const val READ_CHUNK_BYTES = 16 * 1024
        private const val MAX_STATUS_LINE_BYTES = 256
        private const val INITIAL_BACKOFF_MS = 1_000L
        private const val MAX_BACKOFF_MS = 8_000L
    }
}
