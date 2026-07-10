import Foundation
import Testing

@testable import PenBoard

/// PROTOCOL §5: SET_WIDTH/STATE_SYNC width is 1-64 pt, clamp. `Prefs.baseWidth`
/// clamps defensively on read too, in case a stale/corrupted value was ever
/// persisted before that range was enforced at the call sites (width 0 would
/// otherwise render invisible ink).
struct PrefsTests {

    @Test func baseWidthGetterClampsOutOfRangeStoredValues() {
        let original = Prefs.baseWidth
        defer { Prefs.baseWidth = original }

        Prefs.baseWidth = 0
        #expect(Prefs.baseWidth == 1)

        Prefs.baseWidth = 255
        #expect(Prefs.baseWidth == 64)

        Prefs.baseWidth = 30
        #expect(Prefs.baseWidth == 30)
    }

    /// C7: `selectedDisplayID` absent means "no explicit selection" (main
    /// display, v1.0 behavior) — nil, not 0 or some other sentinel. One test
    /// function (not split) because Swift Testing runs tests within a suite
    /// in parallel by default, and split tests hammering the same
    /// `UserDefaults` key would race each other.
    @Test func selectedDisplayIDDefaultsToNilAndRoundTrips() {
        let original = Prefs.selectedDisplayID
        defer { Prefs.selectedDisplayID = original }

        Prefs.selectedDisplayID = nil
        #expect(Prefs.selectedDisplayID == nil)

        Prefs.selectedDisplayID = 69732832 // a real CGDirectDisplayID-shaped value
        #expect(Prefs.selectedDisplayID == 69732832)

        Prefs.selectedDisplayID = nil
        #expect(Prefs.selectedDisplayID == nil)
    }
}
