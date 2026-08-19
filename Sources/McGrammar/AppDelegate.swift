import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotKey = HotKey()
    private let serviceProvider = ServiceProvider()
    private let menu = NSMenu()

    private var claudeStatusItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?
    private var hotKeyRegistered = false
    private var isBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        buildMenu()
        StatusIcon.shared.install(menu: menu)

        // Services must be registered from a real .app bundle; this is a no-op when run loose.
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        hotKeyRegistered = hotKey.register { [weak self] in
            self?.fixSelectionViaHotKey()
        }

        DispatchQueue.global(qos: .utility).async {
            ClaudeRunner.shared.resolveBinary()
            DispatchQueue.main.async { self.refreshMenuState() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self

        let fixItem = NSMenuItem(
            title: "Fix Selected Text",
            action: #selector(fixSelectionMenuAction),
            keyEquivalent: "g"
        )
        fixItem.keyEquivalentModifierMask = [.control, .option]
        fixItem.target = self
        menu.addItem(fixItem)

        menu.addItem(.separator())

        let claudeItem = NSMenuItem(title: "Claude CLI: checking…", action: nil, keyEquivalent: "")
        claudeItem.isEnabled = false
        menu.addItem(claudeItem)
        claudeStatusItem = claudeItem

        let redetect = NSMenuItem(
            title: "Re-detect Claude CLI",
            action: #selector(redetectClaude),
            keyEquivalent: ""
        )
        redetect.target = self
        menu.addItem(redetect)

        let accessibility = NSMenuItem(
            title: "Accessibility: checking…",
            action: #selector(handleAccessibility),
            keyEquivalent: ""
        )
        accessibility.target = self
        menu.addItem(accessibility)
        accessibilityItem = accessibility

        let services = NSMenuItem(
            title: "Open Services Settings…",
            action: #selector(openServicesSettings),
            keyEquivalent: ""
        )
        services.target = self
        menu.addItem(services)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit McGrammar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func refreshMenuState() {
        if let path = ClaudeRunner.shared.binaryPath {
            claudeStatusItem?.title = "Claude CLI: \(path)"
        } else {
            claudeStatusItem?.title = "Claude CLI: not found — run `claude login`"
        }

        let granted = TextCapture.hasAccessibilityPermission
        if granted {
            accessibilityItem?.title = hotKeyRegistered
                ? "Accessibility: granted (hotkey ⌃⌥G active)"
                : "Accessibility: granted — hotkey ⌃⌥G is taken by another app"
        } else {
            accessibilityItem?.title = "Accessibility: not granted — click to fix hotkey"
        }
    }

    // MARK: - Actions

    @objc private func fixSelectionMenuAction() {
        fixSelectionViaHotKey()
    }

    @objc private func redetectClaude() {
        DispatchQueue.global(qos: .utility).async {
            ClaudeRunner.shared.resolveBinary()
            DispatchQueue.main.async {
                self.refreshMenuState()
                Toast.shared.show(ClaudeRunner.shared.resolutionDetail)
            }
        }
    }

    @objc private func handleAccessibility() {
        if TextCapture.hasAccessibilityPermission {
            Toast.shared.show("Accessibility is already granted to McGrammar.")
            return
        }
        TextCapture.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openServicesSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        Toast.shared.show("Keyboard → Keyboard Shortcuts → Services → Text → “Fix Grammar with McGrammar”", duration: 6)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkey path

    /// Copy the selection out of the focused app, correct it, paste it back, restore the clipboard.
    /// Requires Accessibility permission because it drives ⌘C/⌘V with synthetic events.
    private func fixSelectionViaHotKey() {
        guard !isBusy else {
            Toast.shared.show("Already working on a fix…")
            return
        }

        guard TextCapture.hasAccessibilityPermission else {
            Toast.shared.show(
                "McGrammar needs Accessibility permission for the hotkey. Grant it in System Settings → Privacy & Security → Accessibility.",
                isError: true,
                duration: 6
            )
            TextCapture.requestAccessibilityPermission()
            return
        }

        let snapshot = TextCapture.snapshotPasteboard()
        guard let selection = TextCapture.copySelection() else {
            TextCapture.restore(snapshot)
            Toast.shared.show("No text selected — highlight something first.", isError: true)
            return
        }

        isBusy = true
        StatusIcon.shared.setState(.working)

        ClaudeRunner.shared.fixAsync(selection) { [weak self] result in
            guard let self else { return }
            self.isBusy = false

            switch result {
            case .success(let corrected):
                TextCapture.paste(corrected)
                StatusIcon.shared.setState(.idle)
                DispatchQueue.main.asyncAfter(deadline: .now() + TextCapture.clipboardRestoreDelay) {
                    TextCapture.restore(snapshot)
                }
            case .failure(let failure):
                TextCapture.restore(snapshot)
                StatusIcon.shared.flashError()
                Toast.shared.show(failure.description, isError: true, duration: 5)
            }
        }
    }
}
