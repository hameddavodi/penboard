import Foundation
import Testing

@testable import PenBoard

/// C7/A1: `DisplaySelection.resolve` decides which display PenBoard targets
/// from a persisted preference plus whatever's currently attached. Pure
/// struct in/out — no NSScreen involved, so these run on any machine.
struct DisplaySelectionTests {

    private static let main = DisplaySelection.DisplayDescriptor(
        id: 1,
        appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        name: "Built-in"
    )
    private static let external = DisplaySelection.DisplayDescriptor(
        id: 2,
        appKitFrame: CGRect(x: 1920, y: 0, width: 1600, height: 900),
        name: "External"
    )

    @Test func nilPreferenceResolvesToMain() {
        let result = DisplaySelection.resolve(preferredID: nil, displays: [Self.main, Self.external], mainID: 1)
        #expect(result.chosen == Self.main)
        #expect(result.isFallback == false)
    }

    @Test func preferredDisplayPresentIsChosenDirectly() {
        let result = DisplaySelection.resolve(preferredID: 2, displays: [Self.main, Self.external], mainID: 1)
        #expect(result.chosen == Self.external)
        #expect(result.isFallback == false)
    }

    @Test func preferredDisplayAbsentFallsBackToMainWithFallbackFlag() {
        // Preferred (id 2) unplugged: only main is attached.
        let result = DisplaySelection.resolve(preferredID: 2, displays: [Self.main], mainID: 1)
        #expect(result.chosen == Self.main)
        #expect(result.isFallback == true)
    }

    @Test func preferredDisplayEqualToMainIsNotAFallback() {
        let result = DisplaySelection.resolve(preferredID: 1, displays: [Self.main, Self.external], mainID: 1)
        #expect(result.chosen == Self.main)
        #expect(result.isFallback == false)
    }

    @Test func mainMissingFromDisplaysFallsBackToFirstAttached() {
        // Defensive: mainID doesn't match any attached display (shouldn't
        // happen in practice) — still returns something rather than crashing.
        let result = DisplaySelection.resolve(preferredID: nil, displays: [Self.external], mainID: 999)
        #expect(result.chosen == Self.external)
        #expect(result.isFallback == false)
    }

    @Test func emptyDisplaysDoesNotCrash() {
        let result = DisplaySelection.resolve(preferredID: 1, displays: [], mainID: 1)
        #expect(result.isFallback == true)
        #expect(result.chosen.id == 1)
    }
}
