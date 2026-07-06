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
}
