import Foundation

/// A1: pure multi-display resolution logic. No AppKit import — callers hand in
/// plain `DisplayDescriptor` values built from `NSScreen.screens`, so this
/// unit-tests headlessly on any machine (repo pattern: pure logic split from
/// platform glue, same as `CoordinateMapper`).
enum DisplaySelection {

    /// AppKit-free description of one attached display.
    struct DisplayDescriptor: Equatable {
        let id: UInt32
        let appKitFrame: CGRect
        let name: String
    }

    /// C7: resolves the display PenBoard should target.
    /// - `preferredID` is `Prefs.selectedDisplayID` (nil = no explicit
    ///   selection = main display, v1.0 behavior).
    /// - If `preferredID` is set but doesn't match any currently attached
    ///   display (disconnected/unplugged), falls back to the main display and
    ///   reports `isFallback: true` — the caller must NOT overwrite the
    ///   persisted preference in this case (C7: it's a temporary fallback, the
    ///   display may reappear).
    static func resolve(
        preferredID: UInt32?,
        displays: [DisplayDescriptor],
        mainID: UInt32
    ) -> (chosen: DisplayDescriptor, isFallback: Bool) {
        guard let preferredID else {
            return (mainDescriptor(displays: displays, mainID: mainID), false)
        }
        guard let match = displays.first(where: { $0.id == preferredID }) else {
            return (mainDescriptor(displays: displays, mainID: mainID), true)
        }
        return (match, false)
    }

    private static func mainDescriptor(displays: [DisplayDescriptor], mainID: UInt32) -> DisplayDescriptor {
        if let main = displays.first(where: { $0.id == mainID }) { return main }
        if let first = displays.first { return first }
        // NSScreen.screens is never empty for a running app; this branch only
        // exists so `resolve` stays total (no crash) for literally-empty input.
        return DisplayDescriptor(id: mainID, appKitFrame: .zero, name: "Unknown")
    }
}
