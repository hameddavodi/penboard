import Cocoa

/// M2.2: the transparent, click-through overlay for Draw mode. PLAN.md: this is
/// always the live screen showing through underneath — never a whiteboard or a
/// screenshot. `ignoresMouseEvents = true` is the core UX property: the mouse
/// stays fully usable in whatever app is underneath while pen ink renders above
/// it. A1/A2 (v1.1): any attached display, not just main — `retarget(to:)`
/// moves/resizes the overlay when the user picks a different display or a
/// hotplug event changes the effective one (`PenBoardApp.applyDisplay`, A3).
final class OverlayWindow: NSWindow {

    /// The display frame this window covers (AppKit space, bottom-left origin)
    /// — the value `CoordinateMapper`/`CursorInjector` must stay in sync with.
    /// Settable only via `retarget(to:)`.
    private(set) var displayFrame: CGRect

    /// `contentView`'s local bounds: same size as `displayFrame`, zero origin.
    var contentRect: CGRect { CGRect(origin: .zero, size: displayFrame.size) }

    /// `screen` is the AppKit screen to cover at launch (the result of A1's
    /// `DisplaySelection.resolve`); `nil` keeps v1.0 behavior (`NSScreen.main`).
    init(screen: NSScreen?) {
        let frame = (screen ?? NSScreen.main)?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        displayFrame = frame
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        // R3: .statusBar first; .screenSaver is the documented fallback if the
        // overlay ever fails to show over a full-screen Space in practice.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        setFrame(frame, display: true)
    }

    /// A3: move/resize the overlay onto `screen` (menu selection, or hotplug
    /// re-resolve via `didChangeScreenParametersNotification`). Updates
    /// `displayFrame` and the window/content-view geometry only — callers own
    /// any further display-switch side effects (CanvasView's stroke cache and
    /// history, CursorInjector's CG frame), since those need domain knowledge
    /// this generic window class doesn't have.
    func retarget(to screen: NSScreen) {
        let frame = screen.frame
        displayFrame = frame
        setFrame(frame, display: true)
        contentView?.setFrameSize(frame.size)
    }

    // A borderless, mouse-transparent overlay must never become key/main —
    // doing so would steal focus from whatever app the user is actually using.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
