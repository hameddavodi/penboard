import Foundation

/// PenBoard wire codec — mirror of the Android `proto/Packets.kt` codec.
///
/// Pure value transforms only: no Bluetooth, no logging, no UI. See
/// `docs/PROTOCOL.md` for the frozen spec; `docs/PROTOCOL.md §9` golden
/// vectors are the byte-exact cross-language contract this file must satisfy.
enum Packets {

    /// Current wire protocol version. Any other value on the wire is a
    /// `versionMismatch` decode error (§3: caller must send ERROR(1) then disconnect).
    static let version: UInt8 = 0x01

    static let pointBatchType: UInt8 = 0x01
    static let controlType: UInt8 = 0x02

    /// §4: 1...40 points per batch (40 is the hard receiver cap regardless of MTU).
    static let minPointsPerBatch = 1
    static let maxPointsPerBatch = 40

    /// §8: hard cap on any inbound buffer, independent of any length field in the packet.
    static let maxInboundBufferSize = 512

    static let pointByteSize = 7
    static let pointBatchHeaderSize = 5 // version + type + seq(2) + count
    static let controlHeaderSize = 4 // version + type + opcode + length
}

// MARK: - Errors

enum PacketDecodeError: Error, Equatable {
    /// §3: unknown `version` byte — caller must send ERROR(1) then disconnect,
    /// distinct from the malformed counter (§8).
    case versionMismatch
    /// §3: unknown `type` byte — dropped, counts as malformed.
    case unknownType
    /// Buffer too short to even contain a header, or exceeds the 512-byte hard cap.
    case truncated
    /// Declared length field doesn't match the actual remaining bytes.
    case lengthMismatch
    /// POINT_BATCH `count` outside 1...40.
    case invalidCount
    /// A point's event field (`flags` bits 0-2) is 0 or 7.
    case invalidEvent
    /// CONTROL opcode not in the §5 table.
    case unknownOpcode
    /// CONTROL payload length doesn't match the fixed size for its opcode.
    case invalidPayloadLength
}

enum PacketEncodeError: Error, Equatable {
    case invalidCount
}

// MARK: - Decoded packet model

enum DecodedPacket: Equatable {
    case pointBatch(PointBatch)
    case control(ControlPacket)
}

struct PointBatch: Equatable {
    var seq: UInt16
    var points: [Point]
}

struct Point: Equatable {
    var x: UInt16
    var y: UInt16
    var pressure: UInt16
    var flags: UInt8

    enum Event: UInt8 {
        case penDown = 1
        case penMove = 2
        case penUp = 3
        case hoverMove = 4
        case hoverEnter = 5
        case hoverExit = 6
    }

    /// bits 0-2 of `flags`.
    var eventRaw: UInt8 { flags & 0x07 }
    var event: Event? { Event(rawValue: eventRaw) }
    /// bit 3 of `flags`.
    var barrelButtonHeld: Bool { (flags & 0x08) != 0 }
    /// bits 4-7 of `flags`; spec: sender writes 0, receiver ignores but logs non-zero.
    /// Exposed so the BLE layer can log it — this codec stays side-effect free.
    var reservedBits: UInt8 { (flags & 0xF0) >> 4 }

    init(x: UInt16, y: UInt16, pressure: UInt16, flags: UInt8) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.flags = flags
    }

    init(x: UInt16, y: UInt16, pressure: UInt16, event: Event, barrelButtonHeld: Bool = false) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.flags = event.rawValue | (barrelButtonHeld ? 0x08 : 0x00)
    }
}

enum ControlPacket: Equatable {
    case setMode(UInt8)
    case setColor(UInt8)
    case setWidth(UInt8)
    case undo
    case clear
    case ping(UInt32)
    case pong(UInt32)
    case hello(protoVersion: UInt8, token: UInt32)
    case helloOk(protoVersion: UInt8)
    case error(UInt8)
    case stateSync(mode: UInt8, color: UInt8, width: UInt8)

    var opcode: UInt8 {
        switch self {
        case .setMode: return ControlOpcode.setMode.rawValue
        case .setColor: return ControlOpcode.setColor.rawValue
        case .setWidth: return ControlOpcode.setWidth.rawValue
        case .undo: return ControlOpcode.undo.rawValue
        case .clear: return ControlOpcode.clear.rawValue
        case .ping: return ControlOpcode.ping.rawValue
        case .pong: return ControlOpcode.pong.rawValue
        case .hello: return ControlOpcode.hello.rawValue
        case .helloOk: return ControlOpcode.helloOk.rawValue
        case .error: return ControlOpcode.error.rawValue
        case .stateSync: return ControlOpcode.stateSync.rawValue
        }
    }

    /// 6-digit zero-padded pairing code shown on both screens (§6).
    /// Only meaningful for `.hello`.
    static func pairingCode(forToken token: UInt32) -> String {
        String(format: "%06u", token % 1_000_000)
    }
}

enum ControlOpcode: UInt8 {
    case setMode = 0x01
    case setColor = 0x02
    case setWidth = 0x03
    case undo = 0x04
    case clear = 0x05
    case ping = 0x06
    case pong = 0x07
    case hello = 0x08
    case helloOk = 0x09
    case error = 0x0A
    case stateSync = 0x0B

    /// Fixed payload length for this opcode per §5. `nil` means length 0.
    var payloadLength: Int {
        switch self {
        case .setMode, .setColor, .setWidth, .helloOk, .error: return 1
        case .undo, .clear: return 0
        case .stateSync: return 3
        case .ping, .pong: return 4
        case .hello: return 5
        }
    }
}

// MARK: - Top-level decode

extension Packets {

    static func decode(_ data: Data) -> Result<DecodedPacket, PacketDecodeError> {
        let bytes = [UInt8](data)

        guard bytes.count <= maxInboundBufferSize else { return .failure(.truncated) }
        guard bytes.count >= 2 else { return .failure(.truncated) }
        guard bytes[0] == version else { return .failure(.versionMismatch) }

        switch bytes[1] {
        case pointBatchType:
            return decodePointBatch(bytes).map(DecodedPacket.pointBatch)
        case controlType:
            return decodeControl(bytes).map(DecodedPacket.control)
        default:
            return .failure(.unknownType)
        }
    }

    // MARK: POINT_BATCH

    static func decodePointBatch(_ bytes: [UInt8]) -> Result<PointBatch, PacketDecodeError> {
        guard bytes.count >= pointBatchHeaderSize else { return .failure(.truncated) }

        let seq = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let count = Int(bytes[4])

        guard count >= minPointsPerBatch, count <= maxPointsPerBatch else {
            return .failure(.invalidCount)
        }
        guard bytes.count == pointBatchHeaderSize + pointByteSize * count else {
            return .failure(.lengthMismatch)
        }

        var points: [Point] = []
        points.reserveCapacity(count)
        var offset = pointBatchHeaderSize
        for _ in 0..<count {
            let x = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let y = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
            let pressure = UInt16(bytes[offset + 4]) | (UInt16(bytes[offset + 5]) << 8)
            let flags = bytes[offset + 6]
            let point = Point(x: x, y: y, pressure: pressure, flags: flags)
            guard point.event != nil else { return .failure(.invalidEvent) }
            points.append(point)
            offset += pointByteSize
        }

        return .success(PointBatch(seq: seq, points: points))
    }

    static func encodePointBatch(seq: UInt16, points: [Point]) -> Result<Data, PacketEncodeError> {
        guard points.count >= minPointsPerBatch, points.count <= maxPointsPerBatch else {
            return .failure(.invalidCount)
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(pointBatchHeaderSize + pointByteSize * points.count)
        bytes.append(version)
        bytes.append(pointBatchType)
        bytes.append(UInt8(seq & 0xFF))
        bytes.append(UInt8((seq >> 8) & 0xFF))
        bytes.append(UInt8(points.count))
        for point in points {
            bytes.append(UInt8(point.x & 0xFF))
            bytes.append(UInt8((point.x >> 8) & 0xFF))
            bytes.append(UInt8(point.y & 0xFF))
            bytes.append(UInt8((point.y >> 8) & 0xFF))
            bytes.append(UInt8(point.pressure & 0xFF))
            bytes.append(UInt8((point.pressure >> 8) & 0xFF))
            bytes.append(point.flags)
        }
        return .success(Data(bytes))
    }

    // MARK: CONTROL

    static func decodeControl(_ bytes: [UInt8]) -> Result<ControlPacket, PacketDecodeError> {
        guard bytes.count >= controlHeaderSize else { return .failure(.truncated) }

        let opcodeRaw = bytes[2]
        let length = Int(bytes[3])
        guard bytes.count == controlHeaderSize + length else { return .failure(.lengthMismatch) }
        guard let opcode = ControlOpcode(rawValue: opcodeRaw) else { return .failure(.unknownOpcode) }
        guard length == opcode.payloadLength else { return .failure(.invalidPayloadLength) }

        let payload = Array(bytes[controlHeaderSize...])

        switch opcode {
        case .setMode: return .success(.setMode(payload[0]))
        case .setColor: return .success(.setColor(payload[0]))
        case .setWidth: return .success(.setWidth(payload[0]))
        case .undo: return .success(.undo)
        case .clear: return .success(.clear)
        case .ping: return .success(.ping(readU32LE(payload, at: 0)))
        case .pong: return .success(.pong(readU32LE(payload, at: 0)))
        case .hello:
            return .success(.hello(protoVersion: payload[0], token: readU32LE(payload, at: 1)))
        case .helloOk: return .success(.helloOk(protoVersion: payload[0]))
        case .error: return .success(.error(payload[0]))
        case .stateSync:
            return .success(.stateSync(mode: payload[0], color: payload[1], width: payload[2]))
        }
    }

    static func encodeControl(_ packet: ControlPacket) -> Data {
        var payload: [UInt8]
        switch packet {
        case .setMode(let mode): payload = [mode]
        case .setColor(let color): payload = [color]
        case .setWidth(let width): payload = [width]
        case .undo: payload = []
        case .clear: payload = []
        case .ping(let ts): payload = u32LEBytes(ts)
        case .pong(let ts): payload = u32LEBytes(ts)
        case .hello(let protoVersion, let token): payload = [protoVersion] + u32LEBytes(token)
        case .helloOk(let protoVersion): payload = [protoVersion]
        case .error(let code): payload = [code]
        case .stateSync(let mode, let color, let width): payload = [mode, color, width]
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(controlHeaderSize + payload.count)
        bytes.append(version)
        bytes.append(controlType)
        bytes.append(packet.opcode)
        bytes.append(UInt8(payload.count))
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    // MARK: little-endian helpers

    private static func readU32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func u32LEBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }
}
