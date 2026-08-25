import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Clipboard round-trip used by the hotkey path: copy the selection out of whatever app has focus,
/// paste the correction back, then hand the user their clipboard back untouched.
enum TextCapture {
    /// How long to wait for the focused app to answer a synthetic ⌘C.
    private static let copySettleTimeout: TimeInterval = 0.25
    /// How long the correction stays on the clipboard before the original contents are restored.
    ///
    /// This is a race by construction: it has to outlast the focused app processing the synthetic
    /// ⌘V, and nothing on the pasteboard tells us when that has happened. A loaded Electron app, a
    /// busy main thread or a VM target can lose it, and the symptom is a selection left unchanged
    /// with no error. Overridable so a user on a slow target can raise it without a rebuild:
    ///   defaults write com.zernonia.mcgrammar ClipboardRestoreDelay -float 1.2
    static var clipboardRestoreDelay: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "ClipboardRestoreDelay")
        return override > 0 ? override : defaultClipboardRestoreDelay
    }

    static let defaultClipboardRestoreDelay: TimeInterval = 0.6

    struct Snapshot {
        /// Ordered (type, data) pairs per pasteboard item. Ordered on purpose: a pasteboard item's
        /// type order is its preference order, and the dictionary this used to be scrambled it, so
        /// a restored clipboard could hand a pasting app the wrong flavour first.
        let items: [[(type: String, data: Data)]]
        /// The pasteboard's change count when the snapshot was taken. Lets `restore` tell "nothing
        /// has touched the clipboard since" from "we replaced it and must put it back".
        let changeCount: Int
        /// True when at least one item declared a type whose data could not be read — promised or
        /// lazily-rendered flavours (file promises, some app-private types) return nil from
        /// `data(forType:)` until a receiver asks for them, and no snapshot API can materialise
        /// them on our behalf. Such flavours cannot be restored; see `restore`.
        let hasUnreadableFlavors: Bool
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Opens the Accessibility pane prompt. Only call this from an explicit user action.
    static func requestAccessibilityPermission() {
        // Spelled literally rather than via kAXTrustedCheckOptionPrompt: that constant's Swift
        // import shape (Unmanaged<CFString> vs CFString) has shifted between SDKs.
        let options: [String: Bool] = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Clipboard preservation

    static func snapshotPasteboard() -> Snapshot {
        let pasteboard = NSPasteboard.general
        var items: [[(type: String, data: Data)]] = []
        var unreadable = false
        for item in pasteboard.pasteboardItems ?? [] {
            var stored: [(type: String, data: Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    stored.append((type: type.rawValue, data: data))
                } else {
                    unreadable = true
                }
            }
            if !stored.isEmpty { items.append(stored) }
        }
        return Snapshot(
            items: items,
            changeCount: pasteboard.changeCount,
            hasUnreadableFlavors: unreadable
        )
    }

    /// Puts the snapshot back. Clears first, so it must never run on a pasteboard we never
    /// replaced — that would destroy the contents it exists to preserve.
    ///
    /// Known gap: flavours flagged by `hasUnreadableFlavors` are gone. A promised type cannot be
    /// read without a receiver asking for it, so there is nothing to write back; the readable
    /// flavours of the same item are restored in their original order. README documents this.
    static func restore(_ snapshot: Snapshot) {
        let pasteboard = NSPasteboard.general
        // Nothing has touched the clipboard since the snapshot — the commonest case being a ⌘C
        // the focused app never answered. Clearing here would wipe a clipboard we never replaced.
        guard pasteboard.changeCount != snapshot.changeCount else { return }
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.items.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Copy / paste

    /// Simulates ⌘C and returns whatever the focused app put on the pasteboard, or nil if it put
    /// nothing there (no selection, or an app that blocks synthetic keystrokes).
    static func copySelection() -> String? {
        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount

        sendKeystroke(virtualKey: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)

        let deadline = Date().addingTimeInterval(copySettleTimeout)
        while Date() < deadline {
            if pasteboard.changeCount != changeCountBefore { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard pasteboard.changeCount != changeCountBefore else { return nil }

        let text = pasteboard.string(forType: .string)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Puts `text` on the clipboard and simulates ⌘V into the focused app. Returns the pasteboard's
    /// change count afterwards, so the caller can tell whether anything else has written to the
    /// clipboard before it restores — see `restore(_:ifUnchangedSince:)`.
    @discardableResult
    static func paste(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Give the pasteboard server a beat to publish before the paste lands.
        usleep(60_000)
        sendKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        return pasteboard.changeCount
    }

    /// Restores the snapshot only if the clipboard still holds what we put there. If something
    /// else has written to it in the meantime — a clipboard manager, the user copying something —
    /// that content is newer than the snapshot and putting the snapshot back would destroy it.
    static func restore(_ snapshot: Snapshot, ifUnchangedSince changeCount: Int) {
        guard NSPasteboard.general.changeCount == changeCount else { return }
        restore(snapshot)
    }

    private static func sendKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
