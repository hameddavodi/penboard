import Cocoa
import os

/// Menu-bar-only app: no dock icon, no windows (`.accessory` activation policy,
/// backed by `LSUIElement=true` in Info.plist for when it runs as a bundle).
///
/// Composition root + mode state machine (M2.2/M3.1/M3.2/M4.2): owns the overlay
/// window/canvas (Draw), the cursor injector (Laser), global hotkeys, and wires
/// Central's inbound CONTROL opcodes + STREAM point batches to whichever is
/// currently active.
@MainActor
@main
final class PenBoardApp: NSObject, NSApplicationDelegate {

    enum Mode: UInt8 {
        case draw = 0
        case laser = 1
    }

    private let log = Logger(subsystem: "it.aisma.penboard", category: "app")
    private var statusMenu: StatusMenu!
    private var central: Central!
    private var overlayWindow: OverlayWindow!
    private var canvasView: CanvasView!
    private var cursorInjector: CursorInjector!
    private var hotkeys: Hotkeys!
    private var streamController: StreamController!

    private var mode: Mode = .draw
    private var colorIndex: UInt8 = Prefs.colorIndex
    private var baseWidth: UInt8 = Prefs.baseWidth

    /// A3/C7: the display `overlayWindow`/`cursorInjector` are currently
    /// targeting — the value `applyDisplay` diffs against to decide whether a
    /// re-resolve is an effective change (retarget + clear) or a no-op
    /// (e.g. a screen-parameters notification about a display we're not on).
    private var currentDisplay: DisplaySelection.DisplayDescriptor?

    static func main() {
        let app = NSApplication.shared
        let delegate = PenBoardApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("PenBoard launching")

        // C7/A3: resolve the target display from the persisted preference +
        // whatever's currently attached, exactly as `applyDisplay` will later
        // re-resolve on menu pick / hotplug. Absent pref -> main (v1.0 exact).
        let resolved = resolveDisplay()
        currentDisplay = resolved.chosen
        let initialScreen = NSScreen.screens.first { Self.displayID(for: $0) == resolved.chosen.id }

        // Overlay is built first exactly as in v1.0; the injector's CG frame
        // is then derived from the overlay's AppKit frame (construction order
        // preserved from before A1/A2).
        let overlayWindow = OverlayWindow(screen: initialScreen ?? NSScreen.main)
        self.overlayWindow = overlayWindow
        let canvasView = CanvasView(frame: overlayWindow.contentRect)
        self.canvasView = canvasView
        overlayWindow.contentView = canvasView
        canvasView.setColor(paletteIndex: colorIndex)
        canvasView.setBaseWidth(points: CGFloat(baseWidth))

        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? overlayWindow.displayFrame.height
        cursorInjector = CursorInjector(cgDisplayFrame: CoordinateMapper.cgFrame(
            fromAppKitFrame: overlayWindow.displayFrame,
            primaryScreenHeight: primaryScreenHeight
        ))

        let central = Central()
        self.central = central

        let statusMenu = StatusMenu(central: central)
        self.statusMenu = statusMenu
        statusMenu.actionDelegate = self
        statusMenu.updateDisplaySelection(id: resolved.chosen.id, isFallback: resolved.isFallback)
        central.delegate = statusMenu
        central.packetDelegate = self

        let hotkeys = Hotkeys()
        self.hotkeys = hotkeys
        hotkeys.onToggleMode = { [weak self] in self?.toggleMode() }
        hotkeys.onClear = { [weak self] in self?.clearAll() }
        hotkeys.register()

        // A6/D-3: streaming always starts OFF and is never persisted — see
        // StreamController's own doc comment for why.
        let streamController = StreamController()
        self.streamController = streamController
        streamController.onStateChanged = { [weak self] isEnabled, needsPermission in
            guard let self else { return }
            self.statusMenu.updateStreaming(on: isEnabled)
            self.statusMenu.setScreenRecordingHintVisible(needsPermission)
        }

        // R6/A3: a hotplug (unplug, replug, resolution change, arrangement
        // change) posts this on the main run loop — re-resolve every time so
        // a temporarily-fallen-back display auto-returns when it reappears.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        applyMode(Mode(rawValue: Prefs.mode) ?? .draw, announceToTablet: false)
        central.start()

        if ProcessInfo.processInfo.arguments.contains("--debug-replay") {
            log.info("--debug-replay launch flag detected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.runDebugReplay()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("PenBoard terminating")
        hotkeys?.unregisterAll()
    }

    // MARK: Mode state machine (off/draw/laser — v1 has no "off", draw is the resting mode)

    private func applyMode(_ requested: Mode, announceToTablet: Bool) {
        if requested == .laser && !AccessibilityGate.isTrusted {
            log.error("Laser mode requested but Accessibility not trusted — refusing to arm")
            AccessibilityGate.requestAccess()
            statusMenu.setAccessibilityHintVisible(true)
            // Refused: `mode` stays whatever it already was (never `requested`).
            // Correct the tablet — it may be the one that sent SET_MODE(laser) and
            // otherwise would believe it succeeded — and make sure Central's
            // STATE_SYNC mirror reflects the mode actually in effect, not the
            // refused request.
            central.updateLocalState(mode: mode.rawValue, color: colorIndex, width: baseWidth)
            central.sendControl(.setMode(mode.rawValue))
            return
        }
        statusMenu.setAccessibilityHintVisible(false)

        let previousMode = mode
        mode = requested
        Prefs.mode = requested.rawValue

        switch requested {
        case .draw:
            overlayWindow.orderFrontRegardless()
        case .laser:
            if previousMode == .draw {
                canvasView.clear() // D5: Draw -> Laser clears strokes
                central.sendControl(.clear) // ...and the tablet's mirrored copies too
            }
            overlayWindow.orderOut(nil)
        }

        statusMenu.updateMode(isLaser: requested == .laser)
        central.updateLocalState(mode: requested.rawValue, color: colorIndex, width: baseWidth)
        if announceToTablet {
            central.sendControl(.setMode(requested.rawValue))
        }
    }

    private func toggleMode() {
        applyMode(mode == .draw ? .laser : .draw, announceToTablet: true)
    }

    private func clearAll() {
        canvasView.clear()
        central.sendControl(.clear)
    }

    private func runDebugReplay() {
        log.info("Running debug replay through the full Draw pipeline")
        if mode != .draw {
            applyMode(.draw, announceToTablet: false)
        }
        canvasView.runDebugReplay()
    }

    // MARK: Display selection (A3 — C7)

    /// C7: `CGDirectDisplayID` from an `NSScreen`'s device description.
    private static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func descriptors(from screens: [NSScreen]) -> [DisplaySelection.DisplayDescriptor] {
        screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            return DisplaySelection.DisplayDescriptor(id: id, appKitFrame: screen.frame, name: screen.localizedName)
        }
    }

    /// Re-reads `NSScreen.screens` + `Prefs.selectedDisplayID` and resolves
    /// which display should be effective right now. Pure read — callers
    /// (launch, menu pick, hotplug notification) decide what to do with the
    /// result via `applyDisplay`.
    private func resolveDisplay() -> (chosen: DisplaySelection.DisplayDescriptor, isFallback: Bool) {
        let screens = NSScreen.screens
        // AppKit convention: the primary screen is always screens[0].
        let mainID = screens.first.flatMap(Self.displayID(for:)) ?? 0
        return DisplaySelection.resolve(
            preferredID: Prefs.selectedDisplayID,
            displays: Self.descriptors(from: screens),
            mainID: mainID
        )
    }

    /// R6: single choke point for every post-launch display change (menu
    /// selection, hotplug re-resolve). Retargets overlay + injector and
    /// clears ink (stroke geometry can't survive a frame change) only when
    /// the effective frame actually changed — a screen-parameters
    /// notification about some other display, or one that resolves to the
    /// same frame we're already on, is a no-op here.
    private func applyDisplay(_ chosen: DisplaySelection.DisplayDescriptor, isFallback: Bool) {
        statusMenu.updateDisplaySelection(id: chosen.id, isFallback: isFallback)

        let frameChanged = currentDisplay?.appKitFrame != chosen.appKitFrame
        currentDisplay = chosen
        guard frameChanged else { return }
        guard let screen = NSScreen.screens.first(where: { Self.displayID(for: $0) == chosen.id }) else {
            log.error("Resolved display id \(chosen.id, privacy: .public) not found among current NSScreen.screens")
            return
        }

        log.info("Retargeting overlay to display \(chosen.id, privacy: .public) (fallback: \(isFallback, privacy: .public))")
        overlayWindow.retarget(to: screen)
        canvasView.resize(to: overlayWindow.contentRect.size)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? overlayWindow.displayFrame.height
        cursorInjector.update(cgDisplayFrame: CoordinateMapper.cgFrame(
            fromAppKitFrame: overlayWindow.displayFrame,
            primaryScreenHeight: primaryScreenHeight
        ))
        // D2: stroke geometry is stored in view-local points, so it can't
        // survive a frame change; clearAll() also syncs the tablet's mirror
        // via the existing CONTROL CLEAR opcode (PROTOCOL §5, zero protocol
        // change).
        clearAll()
        // Feature 2 (A6): restart capture on the new display if streaming.
        streamController.displayChanged(id: chosen.id)
    }

    @objc private func screenParametersDidChange() {
        let resolved = resolveDisplay()
        applyDisplay(resolved.chosen, isFallback: resolved.isFallback)
    }
}

// MARK: - CentralPacketDelegate

extension PenBoardApp: CentralPacketDelegate {

    func central(_ central: Central, didReceivePointBatch batch: PointBatch) {
        switch mode {
        case .draw:
            canvasView.ingest(points: batch.points)
        case .laser:
            cursorInjector.handle(points: batch.points)
        }
    }

    func central(_ central: Central, didReceiveTabletControl packet: ControlPacket) {
        switch packet {
        case .setMode(let raw):
            guard let requested = Mode(rawValue: raw) else { return }
            applyMode(requested, announceToTablet: false) // tablet already knows; don't echo
        case .setColor(let index):
            colorIndex = index
            Prefs.colorIndex = index
            canvasView.setColor(paletteIndex: index)
            central.updateLocalState(mode: mode.rawValue, color: index, width: baseWidth)
        case .setWidth(let width):
            let clamped = min(max(width, 1), 64) // §5: SET_WIDTH is 1-64 pt, clamp
            baseWidth = clamped
            Prefs.baseWidth = clamped
            canvasView.setBaseWidth(points: CGFloat(clamped))
            central.updateLocalState(mode: mode.rawValue, color: colorIndex, width: clamped)
        case .undo:
            canvasView.undo()
        case .clear:
            canvasView.clear()
        default:
            break // Central only forwards these five opcodes to this delegate method.
        }
    }

    func centralDidDetectStreamSequenceGap(_ central: Central) {
        // A dropped STREAM notification might have carried this stroke's PEN_UP;
        // force-close so the next surviving PEN_MOVE doesn't get appended to a
        // stroke the tablet already considers finished. No-op if nothing is open.
        canvasView.forceCloseOpenStroke()
    }
}

// MARK: - StatusMenuActionDelegate

extension PenBoardApp: StatusMenuActionDelegate {

    func statusMenuDidToggleMode() {
        toggleMode()
    }

    func statusMenuDidRequestClear() {
        clearAll()
    }

    func statusMenuDidRequestDebugReplay() {
        runDebugReplay()
    }

    func statusMenuDidOpenAccessibilitySettings() {
        AccessibilityGate.openSystemSettings()
    }

    func statusMenuDidSelectDisplay(_ id: UInt32) {
        // C7: an explicit menu pick is persisted even if it happens to be the
        // main display — unlike a fallback, this is never overwritten behind
        // the user's back.
        Prefs.selectedDisplayID = id
        let resolved = resolveDisplay()
        applyDisplay(resolved.chosen, isFallback: resolved.isFallback)
    }

    func statusMenuDidToggleStreaming() {
        streamController.setEnabled(!streamController.isEnabled, displayID: currentDisplay?.id ?? 0)
    }

    func statusMenuDidOpenScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
