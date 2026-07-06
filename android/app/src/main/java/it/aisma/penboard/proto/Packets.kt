package it.aisma.penboard.proto

// Wire codec for the PenBoard BLE protocol (docs/PROTOCOL.md, locked v1).
// Pure Kotlin — zero android.* imports — so it is testable on the plain JVM
// and mirrors byte-for-byte against macos/Sources/PenBoard/Proto/Packets.swift.
// All multi-byte integers are little-endian (PROTOCOL §0 preamble).

/** The only wire version this build understands (PROTOCOL §3). */
const val PROTOCOL_VERSION: Int = 0x01

/** Absolute hard cap on any inbound buffer, independent of parsed fields (PROTOCOL §8). */
const val MAX_INBOUND_BUFFER_BYTES: Int = 512

const val MIN_POINT_COUNT: Int = 1
const val MAX_POINT_COUNT: Int = 40
const val POINT_SIZE_BYTES: Int = 7
const val POINT_BATCH_HEADER_BYTES: Int = 5
const val CONTROL_HEADER_BYTES: Int = 4

object PacketType {
    const val POINT_BATCH: Int = 0x01
    const val CONTROL: Int = 0x02
}

/** Bits 0-2 of a point's flags byte (PROTOCOL §4). */
object PointEvent {
    const val PEN_DOWN: Int = 1
    const val PEN_MOVE: Int = 2
    const val PEN_UP: Int = 3
    const val HOVER_MOVE: Int = 4
    const val HOVER_ENTER: Int = 5
    const val HOVER_EXIT: Int = 6

    /** True for events the drop policy must never discard (PROTOCOL §2). */
    fun isCritical(event: Int): Boolean =
        event == PEN_DOWN || event == PEN_UP || event == HOVER_ENTER || event == HOVER_EXIT

    /** True while hovering -- pressure must be forced to 0 for these (PROTOCOL §4). */
    fun isHover(event: Int): Boolean = event == HOVER_MOVE || event == HOVER_ENTER || event == HOVER_EXIT

    fun isValid(event: Int): Boolean = event in PEN_DOWN..HOVER_EXIT
}

object ControlOpcode {
    const val SET_MODE: Int = 0x01
    const val SET_COLOR: Int = 0x02
    const val SET_WIDTH: Int = 0x03
    const val UNDO: Int = 0x04
    const val CLEAR: Int = 0x05
    const val PING: Int = 0x06
    const val PONG: Int = 0x07
    const val HELLO: Int = 0x08
    const val HELLO_OK: Int = 0x09
    const val ERROR: Int = 0x0A
    const val STATE_SYNC: Int = 0x0B

    /** Required payload length per opcode (PROTOCOL §5 table). Unknown opcode = not in map. */
    val PAYLOAD_LENGTH: Map<Int, Int> =
        mapOf(
            SET_MODE to 1,
            SET_COLOR to 1,
            SET_WIDTH to 1,
            UNDO to 0,
            CLEAR to 0,
            PING to 4,
            PONG to 4,
            HELLO to 5,
            HELLO_OK to 1,
            ERROR to 1,
            STATE_SYNC to 3,
        )

    /** SET_WIDTH / STATE_SYNC base-width bounds, inclusive (PROTOCOL §5: "1-64 pt (clamp)"). */
    const val MIN_WIDTH: Int = 1
    const val MAX_WIDTH: Int = 64

    fun clampWidth(width: Int): Int = width.coerceIn(MIN_WIDTH, MAX_WIDTH)
}

object ErrorCode {
    const val VERSION_MISMATCH: Int = 1
    const val MALFORMED_FLOOD: Int = 2
    const val INTERNAL: Int = 3
}

/** One pen/stylus sample inside a POINT_BATCH (PROTOCOL §4). */
data class PenPoint(val x: Int, val y: Int, val pressure: Int, val flags: Int) {
    init {
        require(x in 0..0xFFFF) { "x out of range: $x" }
        require(y in 0..0xFFFF) { "y out of range: $y" }
        require(pressure in 0..0xFFFF) { "pressure out of range: $pressure" }
        require(flags in 0..0xFF) { "flags out of range: $flags" }
    }

    /** Bits 0-2: event kind. See [PointEvent]. */
    val event: Int
        get() = flags and 0x07

    /** Bit 3: S Pen barrel button held. */
    val barrelButtonHeld: Boolean
        get() = (flags and 0x08) != 0

    companion object {
        fun flagsOf(event: Int, barrelButtonHeld: Boolean = false): Int =
            (event and 0x07) or (if (barrelButtonHeld) 0x08 else 0x00)
    }
}

data class PointBatchPacket(val seq: Int, val points: List<PenPoint>)

/** Generic CONTROL packet: opcode + raw validated payload (PROTOCOL §5). */
class ControlPacket(val opcode: Int, val payload: ByteArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ControlPacket) return false
        return opcode == other.opcode && payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int = 31 * opcode + payload.contentHashCode()

    override fun toString(): String = "ControlPacket(opcode=$opcode, length=${payload.size})"
}

/** HELLO payload, decoded (PROTOCOL §5, §6). */
data class HelloPayload(val protoVersion: Int, val token: Long) {
    /** The zero-padded 6-digit code shown on the tablet and confirmed on the Mac. */
    val sixDigitCode: String
        get() = (token % 1_000_000L).toString().padStart(6, '0')
}

sealed class DecodeResult {
    data class PointBatch(val packet: PointBatchPacket) : DecodeResult()

    data class Control(val packet: ControlPacket) : DecodeResult()

    /** Unknown protocol version (PROTOCOL §3): caller must send ERROR(1) then disconnect. */
    object VersionMismatch : DecodeResult()

    /** Any other schema violation (PROTOCOL §3-§5, §8): caller drops + counts it. */
    data class Malformed(val reason: String) : DecodeResult()
}

object Packets {

    fun encodePointBatch(seq: Int, points: List<PenPoint>): ByteArray {
        require(seq in 0..0xFFFF) { "seq out of range: $seq" }
        require(points.size in MIN_POINT_COUNT..MAX_POINT_COUNT) {
            "point count out of range: ${points.size}"
        }
        val out = ByteArray(POINT_BATCH_HEADER_BYTES + POINT_SIZE_BYTES * points.size)
        out[0] = PROTOCOL_VERSION.toByte()
        out[1] = PacketType.POINT_BATCH.toByte()
        writeU16LE(out, 2, seq)
        out[4] = points.size.toByte()
        var offset = POINT_BATCH_HEADER_BYTES
        for (point in points) {
            writeU16LE(out, offset, point.x)
            writeU16LE(out, offset + 2, point.y)
            writeU16LE(out, offset + 4, point.pressure)
            out[offset + 6] = point.flags.toByte()
            offset += POINT_SIZE_BYTES
        }
        return out
    }

    fun encodeControl(opcode: Int, payload: ByteArray = ByteArray(0)): ByteArray {
        require(opcode in 0..0xFF) { "opcode out of range: $opcode" }
        require(payload.size in 0..0xFF) { "payload too large: ${payload.size}" }
        val out = ByteArray(CONTROL_HEADER_BYTES + payload.size)
        out[0] = PROTOCOL_VERSION.toByte()
        out[1] = PacketType.CONTROL.toByte()
        out[2] = opcode.toByte()
        out[3] = payload.size.toByte()
        payload.copyInto(out, CONTROL_HEADER_BYTES)
        return out
    }

    fun decode(bytes: ByteArray): DecodeResult {
        if (bytes.size > MAX_INBOUND_BUFFER_BYTES) return DecodeResult.Malformed("buffer over hard cap")
        if (bytes.size < 2) return DecodeResult.Malformed("shorter than common header")

        val version = bytes[0].toInt() and 0xFF
        if (version != PROTOCOL_VERSION) return DecodeResult.VersionMismatch

        return when (bytes[1].toInt() and 0xFF) {
            PacketType.POINT_BATCH -> decodePointBatch(bytes)
            PacketType.CONTROL -> decodeControl(bytes)
            else -> DecodeResult.Malformed("unknown type")
        }
    }

    private fun decodePointBatch(bytes: ByteArray): DecodeResult {
        if (bytes.size < POINT_BATCH_HEADER_BYTES) {
            return DecodeResult.Malformed("truncated point-batch header")
        }
        val seq = readU16LE(bytes, 2)
        val count = bytes[4].toInt() and 0xFF
        if (count !in MIN_POINT_COUNT..MAX_POINT_COUNT) {
            return DecodeResult.Malformed("point count out of range: $count")
        }
        val expectedLen = POINT_BATCH_HEADER_BYTES + POINT_SIZE_BYTES * count
        if (bytes.size != expectedLen) {
            return DecodeResult.Malformed("length mismatch: expected $expectedLen, got ${bytes.size}")
        }
        val points = ArrayList<PenPoint>(count)
        var offset = POINT_BATCH_HEADER_BYTES
        repeat(count) {
            val x = readU16LE(bytes, offset)
            val y = readU16LE(bytes, offset + 2)
            val pressure = readU16LE(bytes, offset + 4)
            val flags = bytes[offset + 6].toInt() and 0xFF
            if (!PointEvent.isValid(flags and 0x07)) {
                return DecodeResult.Malformed("invalid point event: ${flags and 0x07}")
            }
            points.add(PenPoint(x, y, pressure, flags))
            offset += POINT_SIZE_BYTES
        }
        return DecodeResult.PointBatch(PointBatchPacket(seq, points))
    }

    private fun decodeControl(bytes: ByteArray): DecodeResult {
        if (bytes.size < CONTROL_HEADER_BYTES) return DecodeResult.Malformed("truncated control header")
        val opcode = bytes[2].toInt() and 0xFF
        val length = bytes[3].toInt() and 0xFF
        if (bytes.size != CONTROL_HEADER_BYTES + length) {
            return DecodeResult.Malformed(
                "length field ($length) does not match actual payload (${bytes.size - CONTROL_HEADER_BYTES})"
            )
        }
        val expectedLength =
            ControlOpcode.PAYLOAD_LENGTH[opcode] ?: return DecodeResult.Malformed("unknown opcode: $opcode")
        if (length != expectedLength) {
            return DecodeResult.Malformed(
                "payload length $length does not match opcode $opcode (expected $expectedLength)"
            )
        }
        val payload = bytes.copyOfRange(CONTROL_HEADER_BYTES, bytes.size)
        return DecodeResult.Control(ControlPacket(opcode, payload))
    }
}

/** Parses this packet's payload as a HELLO, or null if it isn't a well-formed HELLO. */
fun ControlPacket.asHello(): HelloPayload? {
    if (opcode != ControlOpcode.HELLO || payload.size != 5) return null
    val protoVersion = payload[0].toInt() and 0xFF
    val token = readU32LE(payload, 1)
    return HelloPayload(protoVersion, token)
}

// --- Little-endian helpers, shared by the codec and by callers that need to
// read/write individual CONTROL payload fields (e.g. echoing a PING timestamp). ---

internal fun writeU16LE(dest: ByteArray, offset: Int, value: Int) {
    dest[offset] = (value and 0xFF).toByte()
    dest[offset + 1] = ((value ushr 8) and 0xFF).toByte()
}

internal fun readU16LE(src: ByteArray, offset: Int): Int =
    (src[offset].toInt() and 0xFF) or ((src[offset + 1].toInt() and 0xFF) shl 8)

internal fun writeU32LE(dest: ByteArray, offset: Int, value: Long) {
    dest[offset] = (value and 0xFF).toByte()
    dest[offset + 1] = ((value ushr 8) and 0xFF).toByte()
    dest[offset + 2] = ((value ushr 16) and 0xFF).toByte()
    dest[offset + 3] = ((value ushr 24) and 0xFF).toByte()
}

internal fun readU32LE(src: ByteArray, offset: Int): Long {
    val b0 = src[offset].toLong() and 0xFF
    val b1 = src[offset + 1].toLong() and 0xFF
    val b2 = src[offset + 2].toLong() and 0xFF
    val b3 = src[offset + 3].toLong() and 0xFF
    return b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)
}
