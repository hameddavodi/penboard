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

    /// A1/A2 (v1.1): any attached display, not just main. Always a CG
    /// (CoreGraphics global) space frame — see `CoordinateMapper.cgFrame`
    /// for how a caller derives one from an `NSScreen.frame`. Used both to
    /// place the injected cursor (`cgEventPoint`) and to clamp it (PROTOCOL
    /// §8) inside the target display. Mutable via `update(cgDisplayFrame:)`
    /// (A3: display switch) rather than being reset there, so an in-flight
    /// `isDown` drag survives a switch — the next point is simply
    /// remapped/clamped against the new frame instead of losing mouse-down
    /// state. Conversion math itself stays out of this class — it's all in
    /// `CoordinateMapper`; this injector only ever holds/forwards the frame.
    private var cgDisplayFrame: CGRect

    private var isDown = false
    private var smoothed: CGPoint?
    private var recentClickTimes: [Date] = []
    /// Last position injected while down — where `releaseIfDown()` posts its
    /// balancing `leftMouseUp` when the real PEN_UP never arrives.
    private var lastDownPoint: CGPoint?

    /// PROTOCOL §8: click events rate-limited to 20/s.
    private let maxClicksPerSecond = 20
    /// Low-pass factor for hover smoothing only (higher = snappier/less smoothing).
    private let smoothingAlpha = 0.6

    init(cgDisplayFrame: CGRect) {
        self.cgDisplayFrame = cgDisplayFrame
    }

    /// A3: re-point injection at a new display's CG frame (menu selection, or
    /// hotplug fallback/return). Deliberately does not touch `isDown`/
    /// `smoothed`/click-rate state — see the property doc comment above.
    func update(cgDisplayFrame: CGRect) {
        self.cgDisplayFrame = cgDisplayFrame
    }

    /// Consumes one POINT_BATCH's points in order (Laser mode only —
    /// `PenBoardApp` routes packets here instead of `CanvasView` while in Laser).
    func handle(points: [Point]) {
        // A batch's points all arrive at once, so consecutive hover moves would
        // be posted back-to-back with only the last one ever visible. Run the
        // low-pass over every sample (same filter state as before) but post one
        // mouseMoved per run, flushed before any other event to keep ordering.
        var pendingHover: CGPoint?
        for point in points {
            guard let event = point.event else { continue }
            let target = CoordinateMapper.clamp(
                CoordinateMapper.cgEventPoint(x: point.x, y: point.y, inCGFrame: cgDisplayFrame),
                to: cgDisplayFrame
            )

            if event == .hoverMove || event == .hoverEnter {
                pendingHover = lowPass(target)
                continue
            }
            if let hover = pendingHover {
                post(.mouseMoved, at: hover)
                pendingHover = nil
            }

            switch event {
            case .hoverMove, .hoverEnter:
                break // handled (coalesced) above

            case .hoverExit:
                break // nothing to inject; the cursor simply stays put

            case .penDown:
                // PROTOCOL §4 self-heal: a PEN_DOWN with the button still held
                // means the previous PEN_UP was lost — balance it before
                // posting a second leftMouseDown.
                releaseIfDown()
                smoothed = target // reset the smoothing anchor at contact
                if canClick() {
                    post(.leftMouseDown, at: target)
                    isDown = true
                    lastDownPoint = target
                } else {
                    log.error("Click rate limit exceeded (>20/s) — dropping PEN_DOWN")
                }

            case .penMove:
                if isDown {
                    post(.leftMouseDragged, at: target)
                    lastDownPoint = target
                } else {
                    // Defensive fallback for a missed PEN_DOWN (PROTOCOL §4:
                    // strokes/gestures self-heal on the next down event).
                    post(.mouseMoved, at: lowPass(target))
                }

            case .penUp:
                if isDown {
                    post(.leftMouseUp, at: target)
                    isDown = false
                    lastDownPoint = nil
                }
                smoothed = target
            }
        }
        if let pendingHover { post(.mouseMoved, at: pendingHover) }
    }

    /// Balances an unmatched `leftMouseDown` when the PEN_UP that should have
    /// ended it can no longer arrive: a STREAM seq gap dropped it, or the mode
    /// switched away from Laser mid-drag. Without this the system is left with
    /// the left button logically held — every real mouse movement becomes a
    /// drag/rubber-band selection until the user clicks again.
    func releaseIfDown() {
        guard isDown else { return }
        log.error("Releasing unmatched leftMouseDown (lost PEN_UP)")
        post(.leftMouseUp, at: lastDownPoint ?? smoothed ?? CGPoint(x: cgDisplayFrame.midX, y: cgDisplayFrame.midY))
        isDown = false
        lastDownPoint = nil
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
