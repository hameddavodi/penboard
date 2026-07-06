import Cocoa
import Security
import os

/// PROTOCOL §6 app-layer handshake support: CSPRNG token + 6-digit pairing code,
/// the UserDefaults-backed trust store, the first-connect confirmation dialog, and
/// the §8 malformed-packet flood gate. No CoreBluetooth here — `Central.swift` owns
/// the state machine and calls into this file at the right transitions.
enum Handshake {
    private static let log = Logger(subsystem: "it.aisma.penboard", category: "handshake")

    enum HandshakeError: Error {
        case randomGenerationFailed(OSStatus)
    }

    /// Fresh CSPRNG token per handshake attempt (§6 step 5: "fresh token per handshake,
    /// from a CSPRNG"). Never persisted — only the resulting trust decision is.
    static func generateToken() throws -> UInt32 {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            log.error("SecRandomCopyBytes failed: \(status, privacy: .public)")
            throw HandshakeError.randomGenerationFailed(status)
        }
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    /// §6 step 6: "Reconnect of a trusted+bonded peripheral: dialog skipped."
    static func isTrusted(_ peripheralID: UUID) -> Bool {
        Prefs.trustedPeripheralID == peripheralID
    }

    /// §6 step 6: "On confirm, Mac persists the peripheral identifier as trusted."
    static func markTrusted(_ peripheralID: UUID) {
        Prefs.trustedPeripheralID = peripheralID
    }

    /// Shows "Pair with 'PenBoard' — code NNNNNN?" (§6 step 6). Safe to call from any
    /// thread; runs the modal on the main thread and calls back with the user's choice.
    static func presentTrustDialog(
        deviceName: String,
        token: UInt32,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        let code = ControlPacket.pairingCode(forToken: token)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Pair with \u{201C}\(deviceName)\u{201D}"
            alert.informativeText = "Code \(code)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            completion(response == .alertFirstButtonReturn)
        }
    }
}

/// §8: "> 10 malformed packets within 60 s → send ERROR(2), disconnect." macOS
/// additionally requires a manual reconnect afterward so a hostile peer can't ride
/// the auto-reconnect loop — `Central` reads `tripped` to decide that.
final class MalformedFloodGate {
    private let threshold = 10
    private let window: TimeInterval = 60
    private var timestamps: [Date] = []
    private let lock = NSLock()

    /// Records one malformed-packet event and reports whether the flood threshold
    /// has now been exceeded.
    @discardableResult
    func recordMalformed(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        timestamps.append(now)
        timestamps.removeAll { now.timeIntervalSince($0) > window }
        return timestamps.count > threshold
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        timestamps.removeAll()
    }
}
