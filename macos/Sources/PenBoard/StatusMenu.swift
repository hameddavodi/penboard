import Cocoa
import os

/// Actions the menu needs the mode/prefs state machine to perform. Kept separate
/// from `CentralStatusDelegate` (connection state, read-only) because this menu
/// never touches BLE directly — `PenBoardApp` owns mode/draw/laser state and is
/// the only conformer.
@MainActor
protocol StatusMenuActionDelegate: AnyObject {
    func statusMenuDidToggleMode()
    func statusMenuDidRequestClear()
    func statusMenuDidRequestDebugReplay()
    func statusMenuDidOpenAccessibilitySettings()
    /// A3: user picked a display from the Display submenu (`CGDirectDisplayID`).
    func statusMenuDidSelectDisplay(_ id: UInt32)
    /// A6: "Stream Screen to Tablet" checkbox toggled.
    func statusMenuDidToggleStreaming()
    func statusMenuDidOpenScreenRecordingSettings()
}

/// Menu bar UI: connection status + last RTT, mode toggle, Clear, Connect
/// (for first-time pairing / the post-flood manual-reconnect gate), Quit, and a
/// Debug submenu (replay harness + latency HUD). This file only owns
/// presentation — `Central` owns connection state, `PenBoardApp` owns mode state.
@MainActor
final class StatusMenu: NSObject {

    private let log = Logger(subsystem: "it.aisma.penboard", category: "statusmenu")
    private weak var central: Central?
    weak var actionDelegate: StatusMenuActionDelegate?

    private let statusItem: NSStatusItem
    private let statusLine = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
    private let connectItem = NSMenuItem(title: "Connect", action: #selector(connectTapped), keyEquivalent: "")
    private let modeItem = NSMenuItem(title: "Mode: Draw (⌥⌘D)", action: #selector(modeTapped), keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
    private let displayMenu = NSMenu()
    private let displayFallbackHintItem = NSMenuItem(
        title: "Selected display disconnected — using main",
        action: nil,
        keyEquivalent: ""
    )
    private let streamToggleItem = NSMenuItem(
        title: "Stream Screen to Tablet",
        action: #selector(streamToggleTapped),
        keyEquivalent: ""
    )
    private let screenRecordingHintItem = NSMenuItem(
        title: "Streaming needs Screen Recording permission",
        action: nil,
        keyEquivalent: ""
    )
    private let openScreenRecordingSettingsItem = NSMenuItem(
        title: "Open System Settings…",
        action: #selector(openScreenRecordingSettingsTapped),
        keyEquivalent: ""
    )
    private let clearItem = NSMenuItem(title: "Clear (⌥⌘C)", action: #selector(clearTapped), keyEquivalent: "")
    private let accessibilityHintItem = NSMenuItem(
        title: "Laser needs Accessibility permission",
        action: nil,
        keyEquivalent: ""
    )
    private let openSettingsItem = NSMenuItem(
        title: "Open System Settings…",
        action: #selector(openSettingsTapped),
        keyEquivalent: ""
    )
    private let debugReplayItem = NSMenuItem(
        title: "Run Debug Replay",
        action: #selector(debugReplayTapped),
        keyEquivalent: ""
    )
    private let latencyHUDItem = NSMenuItem(
        title: "Show Latency HUD",
        action: #selector(latencyHUDTapped),
        keyEquivalent: ""
    )

    private var lastState: Central.ConnectionState = .disconnected
    private var lastRTTMillis: Double?
    private let latencyHUD = LatencyHUDWindow()

    /// A3: the effective display's id, as last pushed by `updateDisplaySelection`
    /// — used only to checkmark the right item next time `displayMenu` opens.
    private var currentDisplaySelectionID: UInt32?

    init(central: Central) {
        self.central = central
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        for item in [
            connectItem, modeItem, clearItem, openSettingsItem, debugReplayItem, latencyHUDItem,
            streamToggleItem, openScreenRecordingSettingsItem,
        ] {
            item.target = self
        }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "PenBoard")
        }

        let debugMenu = NSMenu()
        debugMenu.addItem(debugReplayItem)
        debugMenu.addItem(latencyHUDItem)
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu

        accessibilityHintItem.isEnabled = false
        accessibilityHintItem.isHidden = true
        openSettingsItem.isHidden = true

        // A3: rebuilt lazily on open (menuNeedsUpdate below) so a hotplug
        // between menu opens never leaves stale/disconnected items showing.
        displayMenu.delegate = self
        displayItem.submenu = displayMenu
        displayFallbackHintItem.isEnabled = false
        displayFallbackHintItem.isHidden = true

        screenRecordingHintItem.isEnabled = false
        screenRecordingHintItem.isHidden = true
        openScreenRecordingSettingsItem.isHidden = true

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(connectItem)
        menu.addItem(modeItem)
        menu.addItem(displayItem)
        menu.addItem(displayFallbackHintItem)
        menu.addItem(streamToggleItem)
        menu.addItem(screenRecordingHintItem)
        menu.addItem(openScreenRecordingSettingsItem)
        menu.addItem(clearItem)
        menu.addItem(accessibilityHintItem)
        menu.addItem(openSettingsItem)
        menu.addItem(.separator())
        menu.addItem(debugItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PenBoard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        refreshStatusLine()
    }

    private func refreshStatusLine() {
        let label: String
        switch lastState {
        case .disconnected: label = "Disconnected"
        case .pairing: label = "Pairing…"
        case .connected: label = "Connected"
        }
        if lastState == .connected, let rtt = lastRTTMillis {
            statusLine.title = "\(label) · RTT \(Int(rtt.rounded())) ms"
        } else {
            statusLine.title = label
        }
    }

    // MARK: Mode / accessibility hint (driven by PenBoardApp)

    func updateMode(isLaser: Bool) {
        modeItem.title = isLaser ? "Mode: Laser (⌥⌘D)" : "Mode: Draw (⌥⌘D)"
    }

    func setAccessibilityHintVisible(_ visible: Bool) {
        accessibilityHintItem.isHidden = !visible
        openSettingsItem.isHidden = !visible
    }

    // MARK: Display submenu (A3, driven by PenBoardApp.applyDisplay)

    /// Pushed by `PenBoardApp` after every resolve (launch, menu pick, hotplug
    /// re-resolve). `id` is the *effective* (possibly-fallback) display —
    /// StatusMenu owns no display state itself, just renders what it's told.
    func updateDisplaySelection(id: UInt32, isFallback: Bool) {
        currentDisplaySelectionID = id
        displayFallbackHintItem.isHidden = !isFallback
    }

    private static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Rebuilds the Display submenu from `NSScreen.screens` right before it
    /// opens (see `menuNeedsUpdate` below) so a hotplug between two menu
    /// opens never leaves a stale/disconnected entry checked or listed.
    private func rebuildDisplayMenu() {
        displayMenu.removeAllItems()
        let screens = NSScreen.screens
        let mainScreen = screens.first
        for screen in screens {
            guard let id = Self.displayID(for: screen) else { continue }
            let title = screen === mainScreen ? "\(screen.localizedName) (main)" : screen.localizedName
            let item = NSMenuItem(title: title, action: #selector(displayTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (id == currentDisplaySelectionID) ? .on : .off
            displayMenu.addItem(item)
        }
    }

    @objc private func displayTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UInt32 else { return }
        actionDelegate?.statusMenuDidSelectDisplay(id)
    }

    // MARK: Streaming toggle (A6, driven by StreamController)

    /// Pushed by `PenBoardApp` after every `StreamController.onStateChanged`.
    func updateStreaming(on: Bool) {
        streamToggleItem.state = on ? .on : .off
    }

    func setScreenRecordingHintVisible(_ visible: Bool) {
        screenRecordingHintItem.isHidden = !visible
        openScreenRecordingSettingsItem.isHidden = !visible
    }

    // MARK: Actions

    @objc private func connectTapped() {
        central?.userInitiatedConnect()
    }

    @objc private func modeTapped() {
        actionDelegate?.statusMenuDidToggleMode()
    }

    @objc private func clearTapped() {
        actionDelegate?.statusMenuDidRequestClear()
    }

    @objc private func openSettingsTapped() {
        actionDelegate?.statusMenuDidOpenAccessibilitySettings()
    }

    @objc private func debugReplayTapped() {
        actionDelegate?.statusMenuDidRequestDebugReplay()
    }

    @objc private func streamToggleTapped() {
        actionDelegate?.statusMenuDidToggleStreaming()
    }

    @objc private func openScreenRecordingSettingsTapped() {
        actionDelegate?.statusMenuDidOpenScreenRecordingSettings()
    }

    @objc private func latencyHUDTapped() {
        let showing = !latencyHUD.isVisible
        latencyHUD.setVisible(showing)
        latencyHUDItem.state = showing ? .on : .off
        if showing {
            latencyHUD.update(rttMillis: lastRTTMillis)
        }
    }
}

// MARK: - NSMenuDelegate

extension StatusMenu: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === displayMenu else { return }
        rebuildDisplayMenu()
    }
}

// MARK: - CentralStatusDelegate

extension StatusMenu: CentralStatusDelegate {

    func central(_ central: Central, didChangeState state: Central.ConnectionState) {
        lastState = state
        if state != .connected {
            lastRTTMillis = nil
        }
        refreshStatusLine()
    }

    func central(_ central: Central, didUpdateRTTMillis ms: Double) {
        lastRTTMillis = ms
        refreshStatusLine()
        latencyHUD.update(rttMillis: ms)
    }
}

/// Debug-only floating RTT readout, hidden behind the menu bar's Debug submenu
/// (M4.2: "latency HUD hidden behind a debug menu item").
@MainActor
private final class LatencyHUDWindow {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "RTT: — ms")

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 32),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.autoresizingMask = [.width, .height]
        if let contentView = panel.contentView {
            label.frame = contentView.bounds
            contentView.addSubview(label)
        }

        if let screenFrame = NSScreen.main?.frame {
            panel.setFrameOrigin(NSPoint(x: screenFrame.maxX - 160, y: screenFrame.maxY - 60))
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func update(rttMillis: Double?) {
        label.stringValue = rttMillis.map { "RTT: \(Int($0.rounded())) ms" } ?? "RTT: — ms"
    }
}
