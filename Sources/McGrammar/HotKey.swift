import AppKit
import Carbon.HIToolbox

/// Why a `HotKey.register` call ended the way it did.
///
/// This exists because a dead hotkey is indistinguishable from a broken app: nothing happens when
/// the user presses the keys, and a bare `Bool` return collapsed two very different causes into one
/// `false`. "Another app owns this combination" is the user's problem to solve and they can solve
/// it; "the event handler would not install" is ours. The menu has to be able to say which.
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
///
/// The app registers more than one combination, so dispatch is keyed on the `EventHotKeyID` carried
/// by the event rather than on a single "current instance" global. An earlier single-slot design
/// would have silently broken the first hotkey the moment a second one registered — the second
/// registration would take the slot and the first combination would fire the wrong handler, or
/// none. The Carbon event handler is likewise installed exactly once for the process, not once per
/// instance: two handlers on the same target both fire for every hotkey.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var identifier: UInt32?

    /// Every registered instance, keyed by the `EventHotKeyID.id` it registered under. Carbon
    /// dispatches through a C callback with no context pointer we control, so the routing table
    /// has to live at file scope.
    fileprivate static var registry: [UInt32: HotKey] = [:]
    private static var eventHandler: EventHandlerRef?
    private static var nextIdentifier: UInt32 = 1

    /// Signature shared by every McGrammar hotkey; the per-hotkey `id` is what distinguishes them.
    private static let signature = OSType(0x4D43_4752) // 'MCGR'

    /// Installs the process-wide Carbon handler on first use. Returns the failure status, or
    /// `noErr` if the handler is already installed.
    private static func installSharedHandlerIfNeeded() -> OSStatus {
        if eventHandler != nil { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        return InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCallback,
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    /// `eventHotKeyExistsErr` — returned when another process already owns the combination.
    ///
    /// Spelled out rather than imported: the Command Line Tools SDK on this machine ships no Carbon
    /// header declaring it, so there is nothing to import. The value is long-standing convention
    /// (Hammerspoon, CommandPost and others rely on it) rather than something verified against a
    /// header here, which is why an unrecognised status still reports its raw number instead of
    /// being silently bucketed as "taken".
    private static let eventHotKeyExistsErr: OSStatus = -9878

    /// Registers one combination. The returned value distinguishes the failure causes — see
    /// `HotKeyRegistration` for why that distinction is worth a type.
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) -> HotKeyRegistration {
        unregister()

        let installStatus = Self.installSharedHandlerIfNeeded()
        guard installStatus == noErr else {
            return .handlerInstallFailed(installStatus)
        }

        let id = Self.nextIdentifier
        Self.nextIdentifier += 1
        self.handler = handler
        self.identifier = id
        Self.registry[id] = self

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr, hotKeyRef != nil {
            return .registered
        }
        // Leave nothing half-registered behind: this instance is already in the routing table, so
        // without this it would keep a live handler it can never be reached through.
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
        if let identifier {
            Self.registry.removeValue(forKey: identifier)
            self.identifier = nil
        }
        handler = nil
        // The shared event handler is deliberately left installed. It is harmless with an empty
        // registry, and removing it here would break any hotkey still registered.
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
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    DispatchQueue.main.async {
        HotKey.registry[id]?.fire()
    }
    return noErr
}
