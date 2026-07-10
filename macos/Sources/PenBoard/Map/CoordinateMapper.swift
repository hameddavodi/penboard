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
/// v1.1 (A1): multi-display support. Both functions still take a single
/// frame in the display's own point space — `overlayPoint` an AppKit frame,
/// `cgEventPoint` a CG (CoreGraphics global) frame — so callers on any
/// display just pass the right frame. `cgFrame(fromAppKitFrame:primaryScreenHeight:)`
/// is the bridge between the two: AppKit's per-display frames and CGEvent's
/// global space agree on x but disagree on y's reference edge once more than
/// one display (and therefore a non-zero AppKit origin) is in play.
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

    /// AppKit's unified multi-display coordinate space places every screen's
    /// frame relative to the *primary* screen's bottom-left origin (AppKit
    /// convention: `NSScreen.screens[0]`, `frame.origin == .zero`), while
    /// CGEvent's global space is anchored top-left to that same primary
    /// screen. The two spaces agree on x and disagree on y by a single flip
    /// around the primary screen's height: `cgOrigin.y = h - frame.maxY`.
    /// x/width/height are unchanged by the flip. Passing the primary screen's
    /// own frame back through this function is the identity (its origin is
    /// already (0, 0) in both spaces) — the fixed point the existing
    /// single-display tests pin down.
    static func cgFrame(fromAppKitFrame frame: CGRect, primaryScreenHeight h: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: h - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Normalized (x, y) -> CGEvent global coordinates (top-left origin,
    /// y-down) inside `cgFrame`. `cgFrame` is already in CG (CoreGraphics
    /// global) space — see `cgFrame(fromAppKitFrame:primaryScreenHeight:)` for
    /// how to get there from an `NSScreen.frame` — so no vertical flip is
    /// applied here: both the wire protocol and CG global space are y-down.
    static func cgEventPoint(x: UInt16, y: UInt16, inCGFrame cgFrame: CGRect) -> CGPoint {
        let fx = Double(x) / normalizedMax
        let fy = Double(y) / normalizedMax
        return CGPoint(
            x: cgFrame.origin.x + fx * cgFrame.width,
            y: cgFrame.origin.y + fy * cgFrame.height
        )
    }

    /// PROTOCOL §8 laser-mode safety clamp: keep injected cursor positions inside
    /// the target display bounds. Works for both AppKit-space and CG-space
    /// rects — it only ever compares a point against the frame it came from.
    static func clamp(_ point: CGPoint, to displayFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, displayFrame.minX), displayFrame.maxX - 1),
            y: min(max(point.y, displayFrame.minY), displayFrame.maxY - 1)
        )
    }
}
