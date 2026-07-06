import CoreGraphics
import Foundation
import os

/// M3.2: pen position -> the real macOS cursor (Laser mode). PLAN.md: this is
/// what makes Chrome/Meet's built-in laser pointer follow the pen during a tab
/// share. HOVER_MOVE moves the cursor; PEN_DOWN/UP are left mouse down/up
/// (PEN_MOVE while down = drag). No Catmull-Rom here — cursor lag must stay
/// under a frame, so only a light low-pass on hover, never on contact.
final class CursorInjector {
    private let log = Logger(subsystem: "it.aisma.penboard", category: "cursor")

    /// D1: main display only. Also used to clamp injected positions (PROTOCOL
    /// §8) — safe to reuse the same AppKit-space frame for both AppKit and
    /// CGEvent coordinates because the main display's origin is (0, 0) in both
    /// conventions (see CoordinateMapper).
    private let displayFrame: CGRect

    private var isDown = false
    private var smoothed: CGPoint?
    private var recentClickTimes: [Date] = []

    /// PROTOCOL §8: click events rate-limited to 20/s.
    private let maxClicksPerSecond = 20
    /// Low-pass factor for hover smoothing only (higher = snappier/less smoothing).
    private let smoothingAlpha = 0.6

    init(displayFrame: CGRect) {
        self.displayFrame = displayFrame
    }

    /// Consumes one POINT_BATCH's points in order (Laser mode only —
    /// `PenBoardApp` routes packets here instead of `CanvasView` while in Laser).
    func handle(points: [Point]) {
        for point in points {
            guard let event = point.event else { continue }
            let target = CoordinateMapper.clamp(
                CoordinateMapper.cgEventPoint(x: point.x, y: point.y, in: displayFrame),
                to: displayFrame
            )

            switch event {
            case .hoverMove, .hoverEnter:
                post(.mouseMoved, at: lowPass(target))

            case .hoverExit:
                break // nothing to inject; the cursor simply stays put

            case .penDown:
                smoothed = target // reset the smoothing anchor at contact
                if canClick() {
                    post(.leftMouseDown, at: target)
                    isDown = true
                } else {
                    log.error("Click rate limit exceeded (>20/s) — dropping PEN_DOWN")
                }

            case .penMove:
                if isDown {
                    post(.leftMouseDragged, at: target)
                } else {
                    // Defensive fallback for a missed PEN_DOWN (PROTOCOL §4:
                    // strokes/gestures self-heal on the next down event).
                    post(.mouseMoved, at: lowPass(target))
                }

            case .penUp:
                if isDown {
                    post(.leftMouseUp, at: target)
                    isDown = false
                }
                smoothed = target
            }
        }
    }

    private func canClick() -> Bool {
        let now = Date()
        recentClickTimes.removeAll { now.timeIntervalSince($0) > 1 }
        guard recentClickTimes.count < maxClicksPerSecond else { return false }
        recentClickTimes.append(now)
        return true
    }

    private func lowPass(_ point: CGPoint) -> CGPoint {
        guard let previous = smoothed else {
            smoothed = point
            return point
        }
        let next = CGPoint(
            x: previous.x + (point.x - previous.x) * smoothingAlpha,
            y: previous.y + (point.y - previous.y) * smoothingAlpha
        )
        smoothed = next
        return next
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        else {
            log.error("Failed to construct CGEvent")
            return
        }
        if type == .leftMouseDown || type == .leftMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }
}
