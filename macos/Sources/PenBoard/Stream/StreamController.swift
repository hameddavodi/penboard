import CoreGraphics
import Foundation
import os

/// A6 (Feature 2 MVP): thin @MainActor coordinator wiring the "Stream Screen
/// to Tablet" toggle to the capture/serve pipeline (`ScreenStreamer` ->
/// `MJPEGServer`). Mirrors the existing `AccessibilityGate`/StatusMenu hint
/// pattern for the Screen Recording TCC gate — same UX shape (menu hint +
/// "Open System Settings…"), different permission.
///
/// C6: this is the only place BLE and streaming ever meet, and even here
/// it's one-directional (`PenBoardApp.applyDisplay` calls `displayChanged`) —
/// nothing here touches `Central` or the BLE queues.
@MainActor
final class StreamController {

    private let log = Logger(subsystem: "it.aisma.penboard", category: "stream.controller")
    private let streamer = ScreenStreamer()
    private let server = MJPEGServer()

    /// D-3: never persisted — every enable is an explicit, per-session user
    /// action (screen capture is sensitive enough that v1 deliberately
    /// doesn't restart it silently on relaunch). Source of truth for whether
    /// capture is actually running; `PenBoardApp` doesn't duplicate this.
    private(set) var isEnabled = false

    /// Pushed on every enable/disable/permission-state change so
    /// `PenBoardApp` can drive `StatusMenu.updateStreaming(on:)` +
    /// `setScreenRecordingHintVisible(_:)`. Always fires on the main actor.
    var onStateChanged: ((_ isEnabled: Bool, _ needsPermission: Bool) -> Void)?

    init() {
        // `server` is captured directly (not via `self`) so these closures —
        // invoked from ScreenStreamer's own capture queue, not the main
        // actor — never need to cross back into this @MainActor instance
        // just to reach a plain `@unchecked Sendable` collaborator.
        let server = self.server
        streamer.onFrame = { data in
            server.push(frame: data)
        }
        streamer.onStopped = { [weak self] error in
            Task { @MainActor in
                self?.handleCaptureStopped(error)
            }
        }
        server.onFailure = { [weak self] error in
            Task { @MainActor in
                self?.log.error("MJPEG server failure: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// C6: on enable, preflights Screen Recording access without prompting
    /// (`CGPreflightScreenCaptureAccess`); if not yet granted, requests it
    /// (`CGRequestScreenCaptureAccess`) and surfaces the "needs permission"
    /// menu hint instead of arming — same shape as `PenBoardApp.applyMode`'s
    /// Accessibility gate for Laser. R-2: after granting, the app must be
    /// relaunched before a retry succeeds (TCC re-checks at process launch).
    func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) {
        guard enabled else {
            stop()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            log.info("Screen Recording not yet granted — requesting")
            CGRequestScreenCaptureAccess()
            isEnabled = false
            onStateChanged?(false, true)
            return
        }
        let token = MJPEGWire.makeToken() // C2: fresh token every toggle-ON
        server.start(token: token)
        streamer.start(displayID: displayID)
        isEnabled = true
        onStateChanged?(true, false)
    }

    /// A3 hook: called from `PenBoardApp.applyDisplay` after an effective
    /// display change. No-op if streaming isn't currently enabled.
    func displayChanged(id: CGDirectDisplayID) {
        guard isEnabled else { return }
        streamer.restart(displayID: id)
    }

    private func stop() {
        streamer.stop()
        server.stop()
        isEnabled = false
        onStateChanged?(false, false)
    }

    /// A capture-side failure (TCC revoked mid-session, SCStream error, the
    /// selected display vanishing without going through `applyDisplay`, …)
    /// degrades to "no video", never a partial/wedged state: tear down and
    /// let the menu reflect OFF again, same as an explicit toggle-off.
    private func handleCaptureStopped(_ error: Error?) {
        log.error("Capture stopped: \(String(describing: error), privacy: .public)")
        guard isEnabled else { return }
        stop()
    }
}
