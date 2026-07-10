import Foundation
import Testing

@testable import PenBoard

/// R4: CoordinateMapper is the single place that converts normalized wire
/// coordinates into AppKit (overlay) and CGEvent (laser) point spaces. These
/// tests pin down corners, center, and the y-flip contrast between the two
/// output spaces — the exact bug class R4 exists to catch ("everything is
/// upside down") — plus (A1) the AppKit<->CG frame conversion across the four
/// cardinal multi-display arrangements.
struct CoordinateMapperTests {

    /// A representative main-display frame: origin (0, 0) — the primary
    /// display's AppKit frame is always (0, 0, w, h) by AppKit convention,
    /// and is numerically identical in CG space too (the fixed point A1's
    /// `cgFrame` conversion must preserve).
    static let displayFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func expectApproximatelyEqual(_ a: CGPoint, _ b: CGPoint, tolerance: Double = 0.01) {
        #expect(abs(a.x - b.x) < tolerance, "x: \(a.x) != \(b.x)")
        #expect(abs(a.y - b.y) < tolerance, "y: \(a.y) != \(b.y)")
    }

    private func expectApproximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: Double = 0.01) {
        #expect(abs(a.origin.x - b.origin.x) < tolerance, "x: \(a.origin.x) != \(b.origin.x)")
        #expect(abs(a.origin.y - b.origin.y) < tolerance, "y: \(a.origin.y) != \(b.origin.y)")
        #expect(abs(a.width - b.width) < tolerance, "width: \(a.width) != \(b.width)")
        #expect(abs(a.height - b.height) < tolerance, "height: \(a.height) != \(b.height)")
    }

    // MARK: overlayPoint (AppKit space, bottom-left origin, y-up)

    @Test func overlayPointTopLeftCorner() {
        // Protocol top-left (0, 0) -> AppKit top-left = (0, height): highest y.
        let p = CoordinateMapper.overlayPoint(x: 0, y: 0, in: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 0, y: 1080))
    }

    @Test func overlayPointTopRightCorner() {
        let p = CoordinateMapper.overlayPoint(x: 65535, y: 0, in: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 1920, y: 1080))
    }

    @Test func overlayPointBottomLeftCorner() {
        // Protocol bottom-left (0, max) -> AppKit bottom-left = (0, 0): lowest y.
        let p = CoordinateMapper.overlayPoint(x: 0, y: 65535, in: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 0, y: 0))
    }

    @Test func overlayPointBottomRightCorner() {
        let p = CoordinateMapper.overlayPoint(x: 65535, y: 65535, in: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 1920, y: 0))
    }

    @Test func overlayPointCenter() {
        let p = CoordinateMapper.overlayPoint(x: 32767, y: 32767, in: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 960, y: 540), tolerance: 1.0)
    }

    // MARK: cgEventPoint (CG global space, top-left origin, y-down)

    @Test func cgEventPointTopLeftCorner() {
        // Protocol top-left (0, 0) -> CG top-left (0, 0): no flip vs. the wire protocol.
        let p = CoordinateMapper.cgEventPoint(x: 0, y: 0, inCGFrame: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 0, y: 0))
    }

    @Test func cgEventPointBottomRightCorner() {
        let p = CoordinateMapper.cgEventPoint(x: 65535, y: 65535, inCGFrame: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 1920, y: 1080))
    }

    @Test func cgEventPointCenter() {
        let p = CoordinateMapper.cgEventPoint(x: 32767, y: 32767, inCGFrame: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 960, y: 540), tolerance: 1.0)
    }

    // MARK: y-flip contrast (the core R4 regression this file guards against)

    @Test func yAxisIsFlippedBetweenOverlayAndCGEventSpaces() {
        // As normalized y increases (moving down the physical screen), the
        // overlay (AppKit) y must DECREASE while the CGEvent y must INCREASE.
        let overlayTop = CoordinateMapper.overlayPoint(x: 0, y: 0, in: Self.displayFrame)
        let overlayBottom = CoordinateMapper.overlayPoint(x: 0, y: 65535, in: Self.displayFrame)
        #expect(overlayTop.y > overlayBottom.y)

        let cgTop = CoordinateMapper.cgEventPoint(x: 0, y: 0, inCGFrame: Self.displayFrame)
        let cgBottom = CoordinateMapper.cgEventPoint(x: 0, y: 65535, inCGFrame: Self.displayFrame)
        #expect(cgTop.y < cgBottom.y)
    }

    /// Same contrast, extended (A1) to a non-main display: AppKit frame ->
    /// its own CG frame via `cgFrame`, feeding `overlayPoint`/`cgEventPoint`
    /// respectively. The flip direction must hold regardless of arrangement.
    @Test func yAxisIsFlippedBetweenOverlayAndCGEventSpacesOnNonMainDisplay() {
        let appKitFrame = CGRect(x: 1920, y: 0, width: 1600, height: 900) // external, right, bottom-aligned
        let cgFrame = CoordinateMapper.cgFrame(fromAppKitFrame: appKitFrame, primaryScreenHeight: 1080)

        let overlayTop = CoordinateMapper.overlayPoint(x: 0, y: 0, in: appKitFrame)
        let overlayBottom = CoordinateMapper.overlayPoint(x: 0, y: 65535, in: appKitFrame)
        #expect(overlayTop.y > overlayBottom.y)

        let cgTop = CoordinateMapper.cgEventPoint(x: 0, y: 0, inCGFrame: cgFrame)
        let cgBottom = CoordinateMapper.cgEventPoint(x: 0, y: 65535, inCGFrame: cgFrame)
        #expect(cgTop.y < cgBottom.y)
    }

    // MARK: clamp (PROTOCOL §8 laser safety clamp)

    @Test func clampKeepsPointsInsideBounds() {
        let inside = CGPoint(x: 500, y: 500)
        #expect(CoordinateMapper.clamp(inside, to: Self.displayFrame) == inside)

        let farOutsideHigh = CGPoint(x: 999_999, y: 999_999)
        let clampedHigh = CoordinateMapper.clamp(farOutsideHigh, to: Self.displayFrame)
        #expect(clampedHigh.x <= Self.displayFrame.maxX)
        #expect(clampedHigh.y <= Self.displayFrame.maxY)

        let farOutsideLow = CGPoint(x: -999_999, y: -999_999)
        let clampedLow = CoordinateMapper.clamp(farOutsideLow, to: Self.displayFrame)
        #expect(clampedLow.x >= Self.displayFrame.minX)
        #expect(clampedLow.y >= Self.displayFrame.minY)
    }

    /// Clamp with a negative-origin CG frame (e.g. a display to the left of
    /// main) — bounds must be evaluated against the frame's own min/max, not
    /// assumed non-negative.
    @Test func clampKeepsPointsInsideNegativeOriginCGFrame() {
        let leftAppKitFrame = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        let leftCGFrame = CoordinateMapper.cgFrame(fromAppKitFrame: leftAppKitFrame, primaryScreenHeight: 1080)
        // leftCGFrame == (-1600, 180, 1600, 900)

        let farOutsideLow = CGPoint(x: -999_999, y: -999_999)
        let clampedLow = CoordinateMapper.clamp(farOutsideLow, to: leftCGFrame)
        #expect(clampedLow.x >= leftCGFrame.minX)
        #expect(clampedLow.y >= leftCGFrame.minY)

        let farOutsideHigh = CGPoint(x: 999_999, y: 999_999)
        let clampedHigh = CoordinateMapper.clamp(farOutsideHigh, to: leftCGFrame)
        #expect(clampedHigh.x <= leftCGFrame.maxX)
        #expect(clampedHigh.y <= leftCGFrame.maxY)
    }

    // MARK: cgFrame(fromAppKitFrame:primaryScreenHeight:) — the arrangement matrix

    /// The primary display's own frame must convert to itself — the fixed
    /// point every single-display (pre-A1) test above still relies on.
    @Test func cgFrameOfPrimaryFrameIsIdentity() {
        let cg = CoordinateMapper.cgFrame(fromAppKitFrame: Self.displayFrame, primaryScreenHeight: 1080)
        expectApproximatelyEqual(cg, Self.displayFrame)
    }

    @Test func cgFrameRightBottomAligned() {
        let appKit = CGRect(x: 1920, y: 0, width: 1600, height: 900)
        let cg = CoordinateMapper.cgFrame(fromAppKitFrame: appKit, primaryScreenHeight: 1080)
        expectApproximatelyEqual(cg, CGRect(x: 1920, y: 180, width: 1600, height: 900))
    }

    @Test func cgFrameLeft() {
        let appKit = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        let cg = CoordinateMapper.cgFrame(fromAppKitFrame: appKit, primaryScreenHeight: 1080)
        expectApproximatelyEqual(cg, CGRect(x: -1600, y: 180, width: 1600, height: 900))
    }

    @Test func cgFrameAbove() {
        let appKit = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let cg = CoordinateMapper.cgFrame(fromAppKitFrame: appKit, primaryScreenHeight: 1080)
        expectApproximatelyEqual(cg, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    @Test func cgFrameBelow() {
        let appKit = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let cg = CoordinateMapper.cgFrame(fromAppKitFrame: appKit, primaryScreenHeight: 1080)
        expectApproximatelyEqual(cg, CGRect(x: 0, y: 1080, width: 1920, height: 1080))
    }

    // MARK: cgEventPoint corners/center on each arrangement (via cgFrame)

    @Test func cgEventPointCornersOnAboveDisplay() {
        let appKit = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let cg = CoordinateMapper.cgFrame(fromAppKitFrame: appKit, primaryScreenHeight: 1080)

        let topLeft = CoordinateMapper.cgEventPoint(x: 0, y: 0, inCGFrame: cg)
        expectApproximatelyEqual(topLeft, CGPoint(x: 0, y: -1080))

        let bottomRight = CoordinateMapper.cgEventPoint(x: 65535, y: 65535, inCGFrame: cg)
        expectApproximatelyEqual(bottomRight, CGPoint(x: 1920, y: 0))
    }

    @Test func cgEventPointCornersOnRightDisplay() {
        let appKit = CGRect(x: 1920, y: 0, width: 1600, height: 900)
        let cg = CoordinateMapper.cgFrame(fromAppKitFrame: appKit, primaryScreenHeight: 1080)

        let topLeft = CoordinateMapper.cgEventPoint(x: 0, y: 0, inCGFrame: cg)
        expectApproximatelyEqual(topLeft, CGPoint(x: 1920, y: 180))

        let bottomRight = CoordinateMapper.cgEventPoint(x: 65535, y: 65535, inCGFrame: cg)
        expectApproximatelyEqual(bottomRight, CGPoint(x: 1920 + 1600, y: 180 + 900))

        let center = CoordinateMapper.cgEventPoint(x: 32767, y: 32767, inCGFrame: cg)
        expectApproximatelyEqual(center, CGPoint(x: 1920 + 800, y: 180 + 450), tolerance: 1.0)
    }

    @Test func cgEventPointCornersOnLeftDisplay() {
        let appKit = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        let cg = CoordinateMapper.cgFrame(fromAppKitFrame: appKit, primaryScreenHeight: 1080)

        let topLeft = CoordinateMapper.cgEventPoint(x: 0, y: 0, inCGFrame: cg)
        expectApproximatelyEqual(topLeft, CGPoint(x: -1600, y: 180))

        let bottomRight = CoordinateMapper.cgEventPoint(x: 65535, y: 65535, inCGFrame: cg)
        expectApproximatelyEqual(bottomRight, CGPoint(x: 0, y: 1080))
    }

    @Test func cgEventPointCornersOnBelowDisplay() {
        let appKit = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let cg = CoordinateMapper.cgFrame(fromAppKitFrame: appKit, primaryScreenHeight: 1080)

        let topLeft = CoordinateMapper.cgEventPoint(x: 0, y: 0, inCGFrame: cg)
        expectApproximatelyEqual(topLeft, CGPoint(x: 0, y: 1080))

        let bottomRight = CoordinateMapper.cgEventPoint(x: 65535, y: 65535, inCGFrame: cg)
        expectApproximatelyEqual(bottomRight, CGPoint(x: 1920, y: 2160))
    }
}
