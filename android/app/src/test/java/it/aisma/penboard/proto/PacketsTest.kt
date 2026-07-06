package it.aisma.penboard.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Golden + negative vectors from docs/PROTOCOL.md §9. Every assertion here must
 * match the mirrored Swift test (macos/Tests/PenBoardTests/PacketsTests.swift)
 * byte-for-byte — this is the cross-language wire contract.
 */
class PacketsTest {

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.replace(" ", "").replace("\n", "")
        return ByteArray(clean.length / 2) { i ->
            clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }

    // --- §9 golden vectors ---

    @Test
    fun `POINT_BATCH golden vector encodes byte-exact`() {
        val expected =
            hexToBytes("01 01 05 00 02 E8 03 D0 07 30 75 01 F2 03 E4 07 00 7D 02")
        val points =
            listOf(
                PenPoint(1000, 2000, 30000, PenPoint.flagsOf(PointEvent.PEN_DOWN)),
                PenPoint(1010, 2020, 32000, PenPoint.flagsOf(PointEvent.PEN_MOVE)),
            )
        val actual = Packets.encodePointBatch(seq = 5, points = points)
        assertTrue(expected.contentEquals(actual))
    }

    @Test
    fun `POINT_BATCH golden vector decodes byte-exact`() {
        val bytes = hexToBytes("01 01 05 00 02 E8 03 D0 07 30 75 01 F2 03 E4 07 00 7D 02")
        val result = Packets.decode(bytes)
        check(result is DecodeResult.PointBatch)
        assertEquals(5, result.packet.seq)
        assertEquals(2, result.packet.points.size)

        val p0 = result.packet.points[0]
        assertEquals(1000, p0.x)
        assertEquals(2000, p0.y)
        assertEquals(30000, p0.pressure)
        assertEquals(PointEvent.PEN_DOWN, p0.event)
        assertTrue(!p0.barrelButtonHeld)

        val p1 = result.packet.points[1]
        assertEquals(1010, p1.x)
        assertEquals(2020, p1.y)
        assertEquals(32000, p1.pressure)
        assertEquals(PointEvent.PEN_MOVE, p1.event)
    }

    @Test
    fun `CONTROL SET_COLOR golden vector round-trips`() {
        val expected = hexToBytes("01 02 02 01 02")
        val actual = Packets.encodeControl(ControlOpcode.SET_COLOR, byteArrayOf(2))
        assertTrue(expected.contentEquals(actual))

        val result = Packets.decode(expected)
        check(result is DecodeResult.Control)
        assertEquals(ControlOpcode.SET_COLOR, result.packet.opcode)
        assertTrue(byteArrayOf(2).contentEquals(result.packet.payload))
    }

    @Test
    fun `CONTROL PING golden vector round-trips`() {
        val expected = hexToBytes("01 02 06 04 40 E2 01 00")
        val payload = ByteArray(4).also { writeU32LE(it, 0, 123456L) }
        val actual = Packets.encodeControl(ControlOpcode.PING, payload)
        assertTrue(expected.contentEquals(actual))

        val result = Packets.decode(expected)
        check(result is DecodeResult.Control)
        assertEquals(ControlOpcode.PING, result.packet.opcode)
        assertEquals(123456L, readU32LE(result.packet.payload, 0))
    }

    @Test
    fun `CONTROL HELLO golden vector round-trips and yields the six-digit code`() {
        val expected = hexToBytes("01 02 08 05 01 EF BE AD DE")
        val payload = ByteArray(5)
        payload[0] = 1
        writeU32LE(payload, 1, 0xDEADBEEFL)
        val actual = Packets.encodeControl(ControlOpcode.HELLO, payload)
        assertTrue(expected.contentEquals(actual))

        val result = Packets.decode(expected)
        check(result is DecodeResult.Control)
        val hello = result.packet.asHello()
        checkNotNull(hello)
        assertEquals(1, hello.protoVersion)
        assertEquals(0xDEADBEEFL, hello.token)
        assertEquals("928559", hello.sixDigitCode)
    }

    // --- §9 negative vectors: all must be rejected ---

    @Test
    fun `truncated point batch is rejected`() {
        val bytes = hexToBytes("01 01 00 00 02 E8 03")
        assertTrue(Packets.decode(bytes) is DecodeResult.Malformed)
    }

    @Test
    fun `zero-count point batch is rejected`() {
        val bytes = hexToBytes("01 01 00 00 00")
        assertTrue(Packets.decode(bytes) is DecodeResult.Malformed)
    }

    @Test
    fun `point with event field zero is rejected`() {
        // version, type, seq=0, count=1, then one point with flags=0x00 (event bits = 0).
        val bytes = hexToBytes("01 01 00 00 01 00 00 00 00 00 00 00")
        assertTrue(Packets.decode(bytes) is DecodeResult.Malformed)
    }

    @Test
    fun `point with event field seven is rejected`() {
        // flags = 0x07 -> event bits = 7, the other reserved-invalid value.
        val bytes = hexToBytes("01 01 00 00 01 00 00 00 00 00 00 07")
        assertTrue(Packets.decode(bytes) is DecodeResult.Malformed)
    }

    @Test
    fun `unknown version is reported as version mismatch, not silently dropped`() {
        val bytes = hexToBytes("02 01 00 00 01 00 00 00 00 00 00 01")
        assertEquals(DecodeResult.VersionMismatch, Packets.decode(bytes))
    }

    @Test
    fun `point count 41 is rejected`() {
        val header = byteArrayOf(0x01, 0x01, 0x00, 0x00, 41.toByte())
        val points = ByteArray(41 * POINT_SIZE_BYTES)
        assertTrue(Packets.decode(header + points) is DecodeResult.Malformed)
    }

    @Test
    fun `CONTROL with length not matching actual payload is rejected`() {
        // opcode SET_COLOR declares length=2 but only one payload byte follows.
        val bytes = byteArrayOf(0x01, 0x02, ControlOpcode.SET_COLOR.toByte(), 0x02, 0x02)
        assertTrue(Packets.decode(bytes) is DecodeResult.Malformed)
    }

    @Test
    fun `CONTROL with length matching declared size but wrong for the opcode is rejected`() {
        // SET_COLOR expects a 1-byte payload; this packet is internally
        // consistent (len == 4 + length) but violates the opcode's own table.
        val bytes = byteArrayOf(0x01, 0x02, ControlOpcode.SET_COLOR.toByte(), 0x02, 0x02, 0x00)
        assertTrue(Packets.decode(bytes) is DecodeResult.Malformed)
    }

    @Test
    fun `unknown opcode is rejected`() {
        val bytes = byteArrayOf(0x01, 0x02, 0x7F, 0x00)
        assertTrue(Packets.decode(bytes) is DecodeResult.Malformed)
    }

    @Test
    fun `unknown type is rejected`() {
        val bytes = byteArrayOf(0x01, 0x03)
        assertTrue(Packets.decode(bytes) is DecodeResult.Malformed)
    }

    @Test
    fun `buffer over the hard cap is rejected without parsing`() {
        val bytes = ByteArray(MAX_INBOUND_BUFFER_BYTES + 1)
        bytes[0] = PROTOCOL_VERSION.toByte()
        bytes[1] = PacketType.POINT_BATCH.toByte()
        assertTrue(Packets.decode(bytes) is DecodeResult.Malformed)
    }

    @Test
    fun `clampWidth enforces the 1-64 SET_WIDTH STATE_SYNC bound`() {
        assertEquals(1, ControlOpcode.clampWidth(0))
        assertEquals(1, ControlOpcode.clampWidth(-5))
        assertEquals(1, ControlOpcode.clampWidth(1))
        assertEquals(30, ControlOpcode.clampWidth(30))
        assertEquals(64, ControlOpcode.clampWidth(64))
        assertEquals(64, ControlOpcode.clampWidth(65))
        assertEquals(64, ControlOpcode.clampWidth(255))
    }

    @Test
    fun `encodePointBatch rejects out-of-range point count`() {
        try {
            Packets.encodePointBatch(0, emptyList())
            fail("expected IllegalArgumentException")
        } catch (expected: IllegalArgumentException) {
            // expected
        }
        try {
            Packets.encodePointBatch(0, List(41) { PenPoint(0, 0, 0, PenPoint.flagsOf(PointEvent.PEN_MOVE)) })
            fail("expected IllegalArgumentException")
        } catch (expected: IllegalArgumentException) {
            // expected
        }
    }
}
