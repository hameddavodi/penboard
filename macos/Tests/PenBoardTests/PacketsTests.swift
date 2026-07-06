import Foundation
import Testing

@testable import PenBoard

/// Golden + negative vectors from docs/PROTOCOL.md §9. Byte-exact, both directions
/// (decode the golden bytes, and re-encode the decoded value back to the same bytes).
///
/// Uses Swift Testing (`import Testing`), not XCTest: this toolchain is Xcode
/// Command Line Tools only (no Xcode.app), which does not ship `XCTest.framework`.
/// The CLT does ship `Testing.framework` — see `Package.swift` for the framework
/// search path / rpath wiring that makes plain `swift test` find it.
struct PacketsTests {

    // MARK: Golden vectors

    @Test func decodePointBatchGoldenVector() throws {
        // seq 5, 2 points: (1000, 2000, p 30000, PEN_DOWN), (1010, 2020, p 32000, PEN_MOVE)
        let bytes: [UInt8] = [
            0x01, 0x01, 0x05, 0x00, 0x02,
            0xE8, 0x03, 0xD0, 0x07, 0x30, 0x75, 0x01,
            0xF2, 0x03, 0xE4, 0x07, 0x00, 0x7D, 0x02,
        ]
        let decoded = try Packets.decode(Data(bytes)).get()
        guard case .pointBatch(let batch) = decoded else {
            Issue.record("expected pointBatch, got \(decoded)")
            return
        }
        #expect(batch.seq == 5)
        #expect(batch.points.count == 2)

        #expect(batch.points[0].x == 1000)
        #expect(batch.points[0].y == 2000)
        #expect(batch.points[0].pressure == 30000)
        #expect(batch.points[0].event == .penDown)
        #expect(batch.points[0].barrelButtonHeld == false)

        #expect(batch.points[1].x == 1010)
        #expect(batch.points[1].y == 2020)
        #expect(batch.points[1].pressure == 32000)
        #expect(batch.points[1].event == .penMove)

        // Round-trip: re-encoding must produce the identical bytes.
        let encoded = try Packets.encodePointBatch(seq: batch.seq, points: batch.points).get()
        #expect(encoded == Data(bytes))
    }

    @Test func controlSetColorGoldenVector() throws {
        let bytes: [UInt8] = [0x01, 0x02, 0x02, 0x01, 0x02]
        let decoded = try Packets.decode(Data(bytes)).get()
        guard case .control(let packet) = decoded else {
            Issue.record("expected control, got \(decoded)")
            return
        }
        #expect(packet == .setColor(2))
        #expect(Packets.encodeControl(packet) == Data(bytes))
    }

    @Test func controlPingGoldenVector() throws {
        let bytes: [UInt8] = [0x01, 0x02, 0x06, 0x04, 0x40, 0xE2, 0x01, 0x00]
        let decoded = try Packets.decode(Data(bytes)).get()
        guard case .control(let packet) = decoded else {
            Issue.record("expected control, got \(decoded)")
            return
        }
        #expect(packet == .ping(123_456))
        #expect(Packets.encodeControl(packet) == Data(bytes))
    }

    @Test func controlHelloGoldenVector() throws {
        let bytes: [UInt8] = [0x01, 0x02, 0x08, 0x05, 0x01, 0xEF, 0xBE, 0xAD, 0xDE]
        let decoded = try Packets.decode(Data(bytes)).get()
        guard case .control(let packet) = decoded else {
            Issue.record("expected control, got \(decoded)")
            return
        }
        #expect(packet == .hello(protoVersion: 1, token: 0xDEAD_BEEF))
        #expect(Packets.encodeControl(packet) == Data(bytes))

        // 6-digit code shown on both screens per §6.
        #expect(ControlPacket.pairingCode(forToken: 0xDEAD_BEEF) == "928559")
    }

    // MARK: Negative vectors (§9: must be rejected)

    @Test func truncatedBatchRejected() {
        let bytes: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x02, 0xE8, 0x03]
        #expect(Packets.decode(Data(bytes)) == .failure(.lengthMismatch))
    }

    @Test func zeroCountBatchRejected() {
        let bytes: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x00]
        #expect(Packets.decode(Data(bytes)) == .failure(.invalidCount))
    }

    @Test func eventZeroFlagsRejected() {
        // count=1, single point with event field 0 (invalid; valid range 1-6).
        var bytes: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x01]
        bytes += [0xE8, 0x03, 0xD0, 0x07, 0x30, 0x75, 0x00] // flags = 0
        #expect(Packets.decode(Data(bytes)) == .failure(.invalidEvent))
    }

    @Test func eventSevenFlagsRejected() {
        // event field 7 is also invalid (bits 0-2 == 0b111).
        var bytes: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x01]
        bytes += [0xE8, 0x03, 0xD0, 0x07, 0x30, 0x75, 0x07] // flags = 7
        #expect(Packets.decode(Data(bytes)) == .failure(.invalidEvent))
    }

    @Test func unknownVersionRejected() {
        let bytes: [UInt8] = [0x02, 0x01, 0x00, 0x00, 0x00]
        #expect(Packets.decode(Data(bytes)) == .failure(.versionMismatch))

        // "version 02 anything" — also check a CONTROL-shaped payload.
        let bytes2: [UInt8] = [0x02, 0x02, 0x02, 0x01, 0x02]
        #expect(Packets.decode(Data(bytes2)) == .failure(.versionMismatch))
    }

    @Test func countFortyOneRejected() {
        var bytes: [UInt8] = [0x01, 0x01, 0x00, 0x00, 41]
        bytes += [UInt8](repeating: 0, count: 7 * 41)
        #expect(Packets.decode(Data(bytes)) == .failure(.invalidCount))
    }

    @Test func countFortyAccepted() throws {
        var bytes: [UInt8] = [0x01, 0x01, 0x00, 0x00, 40]
        for _ in 0..<40 {
            bytes += [0xE8, 0x03, 0xD0, 0x07, 0x30, 0x75, 0x01]
        }
        let decoded = try Packets.decode(Data(bytes)).get()
        guard case .pointBatch(let batch) = decoded else {
            Issue.record("expected pointBatch, got \(decoded)")
            return
        }
        #expect(batch.points.count == 40)
    }

    @Test func controlLengthMismatchRejected() {
        // opcode SET_COLOR (payload length 1) declares length=1 but 2 bytes follow.
        let bytes: [UInt8] = [0x01, 0x02, 0x02, 0x01, 0x02, 0x00]
        #expect(Packets.decode(Data(bytes)) == .failure(.lengthMismatch))
    }

    @Test func controlDeclaredLengthWrongForOpcodeRejected() {
        // opcode SET_COLOR declares length=2 (spec requires 1), 2 bytes actually follow
        // so the header-vs-remaining-bytes check passes but the opcode table check must fail.
        let bytes: [UInt8] = [0x01, 0x02, 0x02, 0x02, 0x02, 0x00]
        #expect(Packets.decode(Data(bytes)) == .failure(.invalidPayloadLength))
    }

    @Test func unknownControlOpcodeRejected() {
        let bytes: [UInt8] = [0x01, 0x02, 0xFF, 0x00]
        #expect(Packets.decode(Data(bytes)) == .failure(.unknownOpcode))
    }

    @Test func unknownTypeRejected() {
        let bytes: [UInt8] = [0x01, 0x03, 0x00, 0x00]
        #expect(Packets.decode(Data(bytes)) == .failure(.unknownType))
    }

    @Test func oversizedBufferRejected() {
        let bytes = [UInt8](repeating: 0, count: Packets.maxInboundBufferSize + 1)
        #expect(Packets.decode(Data(bytes)) == .failure(.truncated))
    }

    @Test func emptyBufferRejected() {
        #expect(Packets.decode(Data()) == .failure(.truncated))
    }

    // MARK: Encode-side guard

    @Test func encodePointBatchRejectsOutOfRangeCount() {
        #expect(Packets.encodePointBatch(seq: 0, points: []) == .failure(.invalidCount))

        let tooMany = [Point](repeating: Point(x: 0, y: 0, pressure: 0, event: .penMove), count: 41)
        #expect(Packets.encodePointBatch(seq: 0, points: tooMany) == .failure(.invalidCount))
    }
}
