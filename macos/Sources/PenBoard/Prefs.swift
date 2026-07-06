import Foundation

/// UserDefaults-backed persistence: the trusted peripheral identifier, plus
/// (M4.2) draw/laser mode, color, and stroke width so they survive relaunch.
enum Prefs {
    // Computed (not stored) so it isn't flagged as shared mutable global state for the
    // non-Sendable UserDefaults class under Swift 6 strict concurrency.
    private static var defaults: UserDefaults { .standard }
    private static let trustedPeripheralIDKey = "it.aisma.penboard.trustedPeripheralID"
    private static let modeKey = "it.aisma.penboard.mode"
    private static let colorIndexKey = "it.aisma.penboard.colorIndex"
    private static let baseWidthKey = "it.aisma.penboard.baseWidth"

    /// `CBPeripheral.identifier` of the peripheral the user has confirmed via the
    /// trust dialog (PROTOCOL §6). Never a MAC address — CoreBluetooth identifiers
    /// only (risk R1: MAC-based reconnect is unreliable on Samsung peripherals).
    static var trustedPeripheralID: UUID? {
        get {
            guard let raw = defaults.string(forKey: trustedPeripheralIDKey) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: trustedPeripheralIDKey)
            } else {
                defaults.removeObject(forKey: trustedPeripheralIDKey)
            }
        }
    }

    /// 0 = draw, 1 = laser (mirrors `ControlPacket.setMode` / `PenBoardApp.Mode`).
    /// Defaults to draw (0) when unset.
    static var mode: UInt8 {
        get { UInt8(clamping: defaults.integer(forKey: modeKey)) }
        set { defaults.set(Int(newValue), forKey: modeKey) }
    }

    /// PROTOCOL §7 palette index 0-5; default 4 (black), matching the prior
    /// hardcoded STATE_SYNC default from M1.
    static var colorIndex: UInt8 {
        get {
            guard defaults.object(forKey: colorIndexKey) != nil else { return 4 }
            return UInt8(clamping: defaults.integer(forKey: colorIndexKey))
        }
        set { defaults.set(Int(newValue), forKey: colorIndexKey) }
    }

    /// PROTOCOL §5 SET_WIDTH range is 1-64 pt (clamp); default 6, matching one of
    /// the Android width presets (2/6/14/28) so a button highlights after the
    /// first STATE_SYNC.
    static var baseWidth: UInt8 {
        get {
            guard defaults.object(forKey: baseWidthKey) != nil else { return 6 }
            // Clamp defensively too: guards against a stale/corrupted value
            // written before this range was enforced at the call sites.
            return min(max(UInt8(clamping: defaults.integer(forKey: baseWidthKey)), 1), 64)
        }
        set { defaults.set(Int(newValue), forKey: baseWidthKey) }
    }
}
