import Foundation

/// M2.2/R4: the single place that converts the wire protocol's normalized
/// 0...65535 coordinates (top-left origin, y-down — PROTOCOL §4) into the two
/// screen-point spaces PenBoard needs:
///
/// - `overlayPoint` — AppKit space (bottom-left origin, y-up) for drawing into
///   the overlay window's content view. This is the one flip point: AppKit's
///   y-up convention is the opposite of the wire protocol's y-down convention.
/// - `cgEventPoint` — CGEvent global coordinates (top-left origin, y-down) for
///   cursor injection. Same vertical convention as the wire protocol, so no
///   flip is needed here.
///
/// D1 (v1 scope): main display only. Both functions take the target display's
/// AppKit frame (`NSScreen.frame`) so extending to non-main displays later only
/// needs the caller to pass the right frame — see the `cgEventPoint` doc comment
/// for the one extra step multi-display support would need.
enum CoordinateMapper {

    /// PROTOCOL §4: point fields are u16, so the normalized range is 0...65535.
    static let normalizedMax: Double = 65535

    /// Normalized (x, y) -> AppKit point space (bottom-left origin, y-up) inside
    /// `displayFrame`. `displayFrame` may be an `NSScreen.frame` (global) or an
    /// `NSView.bounds` (local, zero origin) — both are valid AppKit rects and the
    /// math is identical either way.
    static func overlayPoint(x: UInt16, y: UInt16, in displayFrame: CGRect) -> CGPoint {
        let fx = Double(x) / normalizedMax
        let fy = Double(y) / normalizedMax
        let topLeftY = fy * displayFrame.height
        return CGPoint(
            x: displayFrame.origin.x + fx * displayFrame.width,
            y: displayFrame.origin.y + displayFrame.height - topLeftY
        )
    }

    /// Normalized (x, y) -> CGEvent global coordinates (top-left origin, y-down).
    /// `displayFrame` is still an AppKit-space frame (for API symmetry with
    /// `overlayPoint`); no vertical flip is applied because macOS's main display
    /// always has AppKit frame origin (0, 0), which is also the origin CGEvent's
    /// global coordinate space anchors to — the two conventions coincide there.
    /// Extending past D1 to non-main displays would need the primary screen's
    /// height to correct for AppKit's unified multi-display coordinate space;
    /// out of scope while D1 holds.
    static func cgEventPoint(x: UInt16, y: UInt16, in displayFrame: CGRect) -> CGPoint {
        let fx = Double(x) / normalizedMax
        let fy = Double(y) / normalizedMax
        return CGPoint(
            x: displayFrame.origin.x + fx * displayFrame.width,
            y: fy * displayFrame.height
        )
    }

    /// PROTOCOL §8 laser-mode safety clamp: keep injected cursor positions inside
    /// the target display bounds. Works for both AppKit-space and CG-space
    /// rects, since D1's main-display frame is numerically identical in both
    /// (origin (0, 0) either way).
    static func clamp(_ point: CGPoint, to displayFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, displayFrame.minX), displayFrame.maxX - 1),
            y: min(max(point.y, displayFrame.minY), displayFrame.maxY - 1)
        )
    }
}
