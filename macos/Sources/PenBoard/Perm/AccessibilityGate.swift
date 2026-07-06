// ApplicationServices/HIServices (Carbon-era, unaudited for Swift 6 concurrency)
// exposes kAXTrustedCheckOptionPrompt as a plain C global; @preconcurrency tells
// the compiler to treat its un-audited globals leniently instead of flagging
// every reference as unsafe shared mutable state.
@preconcurrency import ApplicationServices
import Cocoa
import os

/// M3.1: Accessibility (TCC) trust gate for Laser mode. Cursor injection needs
/// `AXIsProcessTrustedWithOptions` to return true; `PenBoardApp` checks
/// `isTrusted` before ever arming Laser, and calls `requestAccess()` (which
/// triggers the system prompt once) when it isn't.
enum AccessibilityGate {
    private static let log = Logger(subsystem: "it.aisma.penboard", category: "accessibility")

    /// `kAXTrustedCheckOptionPrompt` is a link-time CFString constant; copying it
    /// into a `String` once here keeps the `@preconcurrency` C-global reference
    /// confined to a single spot.
    private static let promptOptionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

    /// Silent trust check — does not prompt.
    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Checks trust and asks the OS to show the system prompt if untrusted.
    /// Prompting is asynchronous: this call's return value reflects trust at the
    /// moment of the call, not after the user responds — callers must re-check
    /// (e.g. on the next laser-arm attempt) rather than assume this flips true.
    @discardableResult
    static func requestAccess() -> Bool {
        let trusted = AXIsProcessTrustedWithOptions([promptOptionKey: true] as CFDictionary)
        log.info("Accessibility trust check (prompt requested): \(trusted, privacy: .public)")
        return trusted
    }

    /// Deep link to the exact Privacy & Security > Accessibility settings pane.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
