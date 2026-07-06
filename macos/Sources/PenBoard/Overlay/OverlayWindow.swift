import Cocoa

/// M2.2: the transparent, click-through overlay for Draw mode. PLAN.md: this is
/// always the live screen showing through underneath — never a whiteboard or a
/// screenshot. `ignoresMouseEvents = true` is the core UX property: the mouse
/// stays fully usable in whatever app is underneath while pen ink renders above
/// it. D1: main display only; sized to `NSScreen.main`'s frame.
final class OverlayWindow: NSWindow {

    /// The display frame this window covers (AppKit space, bottom-left origin)
    /// — the value `CoordinateMapper`/`CursorInjector` must stay in sync with.
    let displayFrame: CGRect

    /// `contentView`'s local bounds: same size as `displayFrame`, zero origin.
    var contentRect: CGRect { CGRect(origin: .zero, size: displayFrame.size) }

    init() {
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
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

    // A borderless, mouse-transparent overlay must never become key/main —
    // doing so would steal focus from whatever app the user is actually using.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
