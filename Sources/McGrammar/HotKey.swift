import AppKit
import Carbon.HIToolbox

/// Process-wide global hotkey via Carbon's `RegisterEventHotKey`. This is the only API that still
/// gives a true system-wide shortcut to a non-sandboxed menu bar app without an event tap.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    /// Carbon dispatches through a C callback with no context pointer we control here, so the
    /// active instance is parked in a file-private global.
    fileprivate static var active: HotKey?

    /// The one combination McGrammar registers. Inlined rather than parameterised: no caller ever
    /// passed anything else, and configurable hotkeys are a roadmap item (prompt presets), not a
    /// need the app has today.
    private static let keyCode = UInt32(kVK_ANSI_D)
    private static let modifiers = UInt32(controlKey | optionKey)

    /// Registers ⌃⌥D. Returns false if another app already owns the combination.
    @discardableResult
    func register(handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler
        HotKey.active = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCallback,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else {
            // Do not leave a half-registered instance parked in the global: `fire()` would then
            // reach an object that never installed a handler.
            self.handler = nil
            if HotKey.active === self { HotKey.active = nil }
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D43_4752) /* 'MCGR' */, id: 1)
        let registerStatus = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registerStatus == noErr && hotKeyRef != nil
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        handler = nil
        if HotKey.active === self { HotKey.active = nil }
    }

    fileprivate func fire() {
        handler?()
    }
}

private func hotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        HotKey.active?.fire()
    }
    return noErr
}
