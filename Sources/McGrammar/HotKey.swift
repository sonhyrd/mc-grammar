import AppKit
import Carbon.HIToolbox

/// Why a `HotKey.register` call ended the way it did.
///
/// This exists because a dead hotkey is indistinguishable from a broken app: nothing happens when
/// the user presses the keys, and the previous `Bool` return collapsed two very different causes
/// into one `false`. "Another app owns this combination" is the user's problem to solve and they
/// can solve it; "the event handler would not install" is ours. The menu has to be able to say
/// which.
enum HotKeyRegistration {
    case registered
    /// `InstallEventHandler` failed, so no combination was ever attempted.
    case handlerInstallFailed(OSStatus)
    /// The combination is already owned by another process — the common, actionable case.
    case combinationTaken(OSStatus)
    /// `RegisterEventHotKey` failed for some other reason, or handed back no reference.
    case registrationFailed(OSStatus)

    var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }

    /// Menu-ready explanation. Carries the raw `OSStatus` in every failure case: without it a bug
    /// report is "the hotkey does nothing", which is not diagnosable.
    var detail: String {
        switch self {
        case .registered:
            return "active"
        case .handlerInstallFailed(let status):
            return "could not install the key handler (OSStatus \(status))"
        case .combinationTaken(let status):
            return "already taken by another app (OSStatus \(status))"
        case .registrationFailed(let status):
            return "registration failed (OSStatus \(status))"
        }
    }
}

/// Process-wide global hotkey via Carbon's `RegisterEventHotKey`. This is the only API that still
/// gives a true system-wide shortcut to a non-sandboxed menu bar app without an event tap.
final class HotKey {
    /// `eventHotKeyExistsErr` — returned when another process already owns the combination.
    ///
    /// Spelled out rather than imported: the Command Line Tools SDK on this machine ships no Carbon
    /// header declaring it, so there is nothing to import. The value is long-standing convention
    /// (Hammerspoon, CommandPost and others rely on it) rather than something verified against a
    /// header here, which is why an unrecognised status still reports its raw number instead of
    /// being silently bucketed as "taken".
    private static let eventHotKeyExistsErr: OSStatus = -9878

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

    /// Registers ⌃⌥D. The returned value distinguishes the failure causes — see
    /// `HotKeyRegistration` for why that distinction is worth a type.
    @discardableResult
    func register(handler: @escaping () -> Void) -> HotKeyRegistration {
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
            return .handlerInstallFailed(installStatus)
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
        if registerStatus == noErr, hotKeyRef != nil {
            return .registered
        }
        // Leave nothing half-registered behind: the event handler installed successfully above, so
        // without this an unregistered instance keeps a live handler and stays parked in `active`.
        unregister()
        if registerStatus == Self.eventHotKeyExistsErr {
            return .combinationTaken(registerStatus)
        }
        return .registrationFailed(registerStatus)
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
