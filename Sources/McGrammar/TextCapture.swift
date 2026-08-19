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
    static let clipboardRestoreDelay: TimeInterval = 0.6

    struct Snapshot {
        let items: [[String: Data]]
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
        var items: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var stored: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    stored[type.rawValue] = data
                }
            }
            if !stored.isEmpty { items.append(stored) }
        }
        return Snapshot(items: items)
    }

    static func restore(_ snapshot: Snapshot) {
        let pasteboard = NSPasteboard.general
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

    /// Puts `text` on the clipboard and simulates ⌘V into the focused app.
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Give the pasteboard server a beat to publish before the paste lands.
        usleep(60_000)
        sendKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
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
