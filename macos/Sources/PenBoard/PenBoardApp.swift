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

    private var mode: Mode = .draw
    private var colorIndex: UInt8 = Prefs.colorIndex
    private var baseWidth: UInt8 = Prefs.baseWidth

    static func main() {
        let app = NSApplication.shared
        let delegate = PenBoardApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("PenBoard launching")

        let overlayWindow = OverlayWindow()
        self.overlayWindow = overlayWindow
        let canvasView = CanvasView(frame: overlayWindow.contentRect)
        self.canvasView = canvasView
        overlayWindow.contentView = canvasView
        canvasView.setColor(paletteIndex: colorIndex)
        canvasView.setBaseWidth(points: CGFloat(baseWidth))

        cursorInjector = CursorInjector(displayFrame: overlayWindow.displayFrame)

        let central = Central()
        self.central = central

        let statusMenu = StatusMenu(central: central)
        self.statusMenu = statusMenu
        statusMenu.actionDelegate = self
        central.delegate = statusMenu
        central.packetDelegate = self

        let hotkeys = Hotkeys()
        self.hotkeys = hotkeys
        hotkeys.onToggleMode = { [weak self] in self?.toggleMode() }
        hotkeys.onClear = { [weak self] in self?.clearAll() }
        hotkeys.register()

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
}
