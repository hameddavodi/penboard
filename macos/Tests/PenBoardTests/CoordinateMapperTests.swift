import Foundation
import Testing

@testable import PenBoard

/// R4: CoordinateMapper is the single place that converts normalized wire
/// coordinates into AppKit (overlay) and CGEvent (laser) point spaces. These
/// tests pin down corners, center, and the y-flip contrast between the two
/// output spaces — the exact bug class R4 exists to catch ("everything is
/// upside down").
struct CoordinateMapperTests {

    /// A representative main-display frame: origin (0, 0) per D1 (main display
    /// only), matching how `OverlayWindow`/`CursorInjector` use it.
    static let displayFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func expectApproximatelyEqual(_ a: CGPoint, _ b: CGPoint, tolerance: Double = 0.01) {
        #expect(abs(a.x - b.x) < tolerance, "x: \(a.x) != \(b.x)")
        #expect(abs(a.y - b.y) < tolerance, "y: \(a.y) != \(b.y)")
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
        let p = CoordinateMapper.cgEventPoint(x: 0, y: 0, in: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 0, y: 0))
    }

    @Test func cgEventPointBottomRightCorner() {
        let p = CoordinateMapper.cgEventPoint(x: 65535, y: 65535, in: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 1920, y: 1080))
    }

    @Test func cgEventPointCenter() {
        let p = CoordinateMapper.cgEventPoint(x: 32767, y: 32767, in: Self.displayFrame)
        expectApproximatelyEqual(p, CGPoint(x: 960, y: 540), tolerance: 1.0)
    }

    // MARK: y-flip contrast (the core R4 regression this file guards against)

    @Test func yAxisIsFlippedBetweenOverlayAndCGEventSpaces() {
        // As normalized y increases (moving down the physical screen), the
        // overlay (AppKit) y must DECREASE while the CGEvent y must INCREASE.
        let overlayTop = CoordinateMapper.overlayPoint(x: 0, y: 0, in: Self.displayFrame)
        let overlayBottom = CoordinateMapper.overlayPoint(x: 0, y: 65535, in: Self.displayFrame)
        #expect(overlayTop.y > overlayBottom.y)

        let cgTop = CoordinateMapper.cgEventPoint(x: 0, y: 0, in: Self.displayFrame)
        let cgBottom = CoordinateMapper.cgEventPoint(x: 0, y: 65535, in: Self.displayFrame)
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
}
