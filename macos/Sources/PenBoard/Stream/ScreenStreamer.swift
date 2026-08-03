import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import os

/// A4/C4 (Feature 2 MVP): captures the selected display via ScreenCaptureKit
/// and emits scaled, JPEG-encoded frames at ~12 fps. Serial-queue-confined +
/// `@unchecked Sendable`, the same pattern as `Central` — all mutable state
/// is touched only from `queue` (also the `sampleHandlerQueue` SCStream
/// delivers frames on), so `onFrame`/`onStopped` always fire from `queue`.
///
/// macOS 13 surface only (see `internal docs`):
/// nothing from the 14+ APIs (SCContentSharingPicker, SCScreenshotManager,
/// SCStreamConfiguration.streamName/captureResolution, etc.) is used.
final class ScreenStreamer: NSObject, @unchecked Sendable {

    /// C4: longest edge target, aspect preserved, dimensions rounded to even.
    static let maxEdge = 1280
    /// C4: target frame rate (`minimumFrameInterval`).
    static let targetFPS: Int32 = 12
    /// C4: JPEG quality.
    static let jpegQuality: CGFloat = 0.55

    private let log = Logger(subsystem: "it.aisma.penboard", category: "stream.capture")
    private let queue = DispatchQueue(label: "it.aisma.penboard.stream.capture")
    /// Reused across frames — creating a fresh `CIContext` per frame is the
    /// classic perf mistake this avoids (context setup is not cheap).
    private let ciContext = CIContext(options: nil)

    private var stream: SCStream?
    /// C4 backpressure: guards against re-entering the (synchronous) JPEG
    /// encode while one is still "in flight" on this same serial queue —
    /// belt-and-braces alongside `SCStreamConfiguration.queueDepth`, which is
    /// ScreenCaptureKit's own drop-stale-frames mechanism.
    private var isEncoding = false

    /// Confined to `queue`. Bumped by every teardown; the async capture-setup
    /// task snapshots it and re-checks before arming the stream. Without this,
    /// toggling OFF while `SCShareableContent` is still resolving (routinely
    /// hundreds of ms) let the in-flight task start capture anyway — screen
    /// recording live, purple indicator on, menu showing OFF — and two
    /// overlapping `start()`s could orphan an unstoppable second SCStream.
    private var captureGeneration = 0

    /// Always called on `queue`. C4: exactly one JPEG per delivered frame.
    var onFrame: ((Data) -> Void)?
    /// Always called on `queue`. Fires on any stream-ending error (including
    /// `addStreamOutput`/`startCapture` failures) — never on a normal `stop()`.
    var onStopped: ((Error?) -> Void)?

    /// C4/A3: begin (or, if already running, replace) capture of `displayID`.
    /// Safe to call repeatedly — always tears down any existing stream first.
    /// Async (never blocks the caller on this queue — the synchronous JPEG
    /// encode also runs here, so a `queue.sync` from the main actor was a
    /// visible UI hitch).
    func start(displayID: CGDirectDisplayID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownLocked()
            let generation = self.captureGeneration
            Task { [weak self] in
                guard let self else { return }
                do {
                    // async import of getExcludingDesktopWindows(_:onScreenWindowsOnly:completionHandler:).
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    // No fallback to "some other display": silently streaming
                    // the wrong screen to a remote tablet is a privacy failure,
                    // not a graceful degradation.
                    guard let display = content.displays.first(where: { $0.displayID == displayID })
                    else {
                        self.log.error("No capturable display found (requested id \(displayID, privacy: .public))")
                        self.onStopped?(nil)
                        return
                    }
                    self.beginCapture(on: display, generation: generation)
                } catch {
                    self.log.error("SCShareableContent fetch failed: \(String(describing: error), privacy: .public)")
                    self.onStopped?(error)
                }
            }
        }
    }

    /// A3: display switch — tear down the current stream (if any) and start
    /// fresh on the new display. `start(displayID:)` is already idempotent,
    /// so this is just the display-switch-intent-documenting name A3 wires to.
    func restart(displayID: CGDirectDisplayID) {
        start(displayID: displayID)
    }

    func stop() {
        queue.async { [weak self] in self?.teardownLocked() }
    }

    /// Must only run confined to `queue` (via `queue.async` from the entry
    /// points above — capture setup itself happens off-queue since it's async).
    private func teardownLocked() {
        captureGeneration += 1 // invalidate any in-flight capture-setup task
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        isEncoding = false
    }

    private func beginCapture(on display: SCDisplay, generation: Int) {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let size = Self.scaledSize(sourceWidth: display.width, sourceHeight: display.height)
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.targetFPS)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 4
        config.showsCursor = true

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            log.error("addStreamOutput failed: \(String(describing: error), privacy: .public)")
            onStopped?(error)
            return
        }
        var stale = false
        queue.sync {
            if generation == self.captureGeneration {
                self.stream = newStream
            } else {
                stale = true
            }
        }
        // A teardown ran while this setup task was resolving content — the
        // stream was never started, so simply abandoning it here is enough.
        if stale { return }
        newStream.startCapture { [weak self] error in
            guard let self else { return }
            if let error {
                self.log.error("startCapture failed: \(String(describing: error), privacy: .public)")
                self.onStopped?(error)
                return
            }
            // A teardown could also land between the assignment above and
            // capture actually starting; a capture that outlives its toggle
            // must be stopped, not leaked.
            self.queue.async {
                if generation != self.captureGeneration {
                    newStream.stopCapture(completionHandler: nil)
                }
            }
        }
    }

    /// C4: longest edge <= `maxEdge`, aspect preserved, dimensions rounded
    /// DOWN to even (never upscales a display smaller than `maxEdge`; floors
    /// rather than rounds-to-nearest so the cap is never exceeded by a
    /// half-pixel rounding tie).
    static func scaledSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (maxEdge, maxEdge) }
        let longestEdge = max(sourceWidth, sourceHeight)
        let scale = min(1.0, Double(maxEdge) / Double(longestEdge))
        let scaledWidth = Int((Double(sourceWidth) * scale).rounded())
        let scaledHeight = Int((Double(sourceHeight) * scale).rounded())
        return (evenFloor(scaledWidth), evenFloor(scaledHeight))
    }

    private static func evenFloor(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }
}

// MARK: - SCStreamOutput

extension ScreenStreamer: SCStreamOutput {

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard !isEncoding else { return } // C4 backpressure: drop while a previous encode is in flight
        guard isFrameComplete(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isEncoding = true
        defer { isEncoding = false }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard
            let data = ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: colorSpace,
                options: [qualityKey: Self.jpegQuality]
            )
        else { return }
        onFrame?(data)
    }

    /// Standard ScreenCaptureKit pattern: a delivered sample buffer can carry
    /// a non-`.complete` status (e.g. idle/blank/suspended) that shouldn't be
    /// encoded as a real frame.
    private func isFrameComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentsArray.first,
            let statusRawValue = attachments[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue)
        else { return false }
        return status == .complete
    }
}

// MARK: - SCStreamDelegate

extension ScreenStreamer: SCStreamDelegate {

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("Stream stopped with error: \(String(describing: error), privacy: .public)")
        queue.async { [weak self] in self?.stream = nil }
        onStopped?(error)
    }
}
