import Carbon.HIToolbox
import Foundation
import os

/// M4.2/D6: global hotkeys — Opt+Cmd+D toggles Draw/Laser, Opt+Cmd+C clears.
/// Uses Carbon `RegisterEventHotKey` (not an `NSEvent` monitor): it fires while
/// any other app has keyboard focus and needs no extra TCC permission, unlike
/// Accessibility-gated global event monitors.
@MainActor
final class Hotkeys {
    private static let log = Logger(subsystem: "it.aisma.penboard", category: "hotkeys")

    private enum HotKeyID: UInt32 {
        case toggleMode = 1
        case clear = 2
    }

    /// Carbon's hotkey-pressed callback is a plain C function pointer with no
    /// captures, so it can't close over a `Hotkeys` instance directly — it looks
    /// the instance up here by the `EventHotKeyID.id` it registered with.
    fileprivate static var registry: [UInt32: Hotkeys] = [:]
    private static let signature: OSType = fourCharCode("PnBd")

    var onToggleMode: (@MainActor () -> Void)?
    var onClear: (@MainActor () -> Void)?

    private var toggleModeRef: EventHotKeyRef?
    private var clearRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Installs the process-wide hotkey dispatcher and registers both hotkeys.
    /// Safe to call once per app launch.
    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, &eventHandlerRef)

        Self.registry[HotKeyID.toggleMode.rawValue] = self
        Self.registry[HotKeyID.clear.rawValue] = self

        register(id: .toggleMode, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey), ref: &toggleModeRef)
        register(id: .clear, keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey), ref: &clearRef)
    }

    private func register(id: HotKeyID, keyCode: UInt32, modifiers: UInt32, ref: inout EventHotKeyRef?) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            Self.log.error("RegisterEventHotKey failed for id \(id.rawValue, privacy: .public): status \(status, privacy: .public)")
        }
    }

    func unregisterAll() {
        if let toggleModeRef {
            UnregisterEventHotKey(toggleModeRef)
        }
        if let clearRef {
            UnregisterEventHotKey(clearRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        toggleModeRef = nil
        clearRef = nil
        eventHandlerRef = nil
        Self.registry[HotKeyID.toggleMode.rawValue] = nil
        Self.registry[HotKeyID.clear.rawValue] = nil
    }

    fileprivate func fire(id: UInt32) {
        switch HotKeyID(rawValue: id) {
        case .toggleMode: onToggleMode?()
        case .clear: onClear?()
        case nil: Self.log.error("Unknown hotkey id fired: \(id, privacy: .public)")
        }
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}

/// Carbon hotkey dispatch callback. Always fires on the main thread (Carbon's
/// application event target is pumped by the main run loop), so
/// `MainActor.assumeIsolated` safely bridges this non-isolated C callback into
/// the `@MainActor`-isolated `Hotkeys` registry/instance.
private func hotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        Hotkeys.registry[id]?.fire(id: id)
    }
    return noErr
}
