import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// ⌃⌥D — runs `Preset.standard`.
    private let standardHotKey = HotKey()
    /// ⌃⌥⇧D — runs `Preset.alternate`. Both presets get a hotkey deliberately: some Electron and
    /// sandboxed apps expose no Services menu at all, and the alternate preset is precisely the one
    /// a user reaches for when the default did something they did not want. It must not be the one
    /// that is unreachable.
    private let alternateHotKey = HotKey()
    private let serviceProvider = ServiceProvider()
    private let menu = NSMenu()

    private var claudeStatusItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?
    private var standardHotKeyRegistration: HotKeyRegistration = .registrationFailed(noErr)
    private var alternateHotKeyRegistration: HotKeyRegistration = .registrationFailed(noErr)
    private var isBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The one place the policy is set. LSUIElement in Info.plist covers the bundled app; this
        // covers a loose binary. Setting it in main.swift as well drifts the two out of sync.
        NSApp.setActivationPolicy(.accessory)

        buildMenu()
        StatusIcon.shared.install(menu: menu)

        // Services must be registered from a real .app bundle; this is a no-op when run loose.
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        standardHotKeyRegistration = standardHotKey.register(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in
            self?.fixSelection(preset: .standard)
        }
        alternateHotKeyRegistration = alternateHotKey.register(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | optionKey | shiftKey)
        ) { [weak self] in
            self?.fixSelection(preset: .alternate)
        }

        DispatchQueue.global(qos: .utility).async {
            ClaudeRunner.shared.resolveBinary()
            DispatchQueue.main.async { self.refreshMenuState() }
        }

        promptForAccessibilityOnFirstLaunch()
    }

    /// macOS shows the "McGrammar would like to control this computer" dialog at most once per
    /// app identity, and only in response to a call from the running app — a build script cannot
    /// trigger it. So ask once, on the first launch of a freshly installed bundle, rather than
    /// leaving the user to discover the menu item. The Services path never needs this, which is
    /// why a decline is silent: the app stays fully usable.
    private func promptForAccessibilityOnFirstLaunch() {
        let key = "promptedForAccessibilityByBuild"
        let build = Self.installedBuildFingerprint()
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        UserDefaults.standard.set(build, forKey: key)
        guard !TextCapture.hasAccessibilityPermission else { return }
        TextCapture.requestAccessibilityPermission()
    }

    /// Identifies *this installed build*, not just "we have asked once before".
    ///
    /// A plain bool survives `rm -rf ~/Applications/McGrammar.app` — UserDefaults lives in
    /// ~/Library/Preferences — so a reinstalling user got no prompt at all unless they knew to run
    /// the `defaults delete` line in the README. Keying on the executable's path and modification
    /// date re-arms the prompt for every freshly installed bundle, which is what README's "the
    /// first launch of a newly installed bundle asks for it" actually promises.
    private static func installedBuildFingerprint() -> String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let modified = (try? FileManager.default.attributesOfItem(atPath: executable.path)[.modificationDate] as? Date)
            ?? nil
        let stamp = modified.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return "\(executable.path)@\(stamp)"
    }

    func applicationWillTerminate(_ notification: Notification) {
        standardHotKey.unregister()
        alternateHotKey.unregister()
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self

        let fixItem = NSMenuItem(
            title: "\(Preset.standard.displayName) Selected Text",
            action: #selector(runStandardPreset),
            keyEquivalent: "d"
        )
        fixItem.keyEquivalentModifierMask = [.control, .option]
        fixItem.target = self
        menu.addItem(fixItem)

        let alternateItem = NSMenuItem(
            title: "\(Preset.alternate.displayName) Selected Text",
            action: #selector(runAlternatePreset),
            keyEquivalent: "d"
        )
        alternateItem.keyEquivalentModifierMask = [.control, .option, .shift]
        alternateItem.target = self
        menu.addItem(alternateItem)

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
            // Report the actual registration outcome, not just "not active". A hotkey that does
            // nothing looks identical to a broken app from the outside, so the menu is the only
            // place the cause can surface.
            let standardDetail = standardHotKeyRegistration.isRegistered
                ? "⌃⌥D active"
                : "⌃⌥D \(standardHotKeyRegistration.detail)"
            let alternateDetail = alternateHotKeyRegistration.isRegistered
                ? "⌃⌥⇧D active"
                : "⌃⌥⇧D \(alternateHotKeyRegistration.detail)"
            accessibilityItem?.title = "Accessibility: granted (\(standardDetail), \(alternateDetail))"
        } else {
            accessibilityItem?.title = "Accessibility: not granted — click to fix hotkey"
        }
    }

    // MARK: - Actions

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

    // MARK: - Synthetic-keystroke path (hotkey and menu item)

    /// Copy the selection out of the focused app, correct it, paste it back, restore the clipboard.
    /// Requires Accessibility permission because it drives ⌘C/⌘V with synthetic events. Reached
    /// from both ⌃⌥D and the menu item — the Services path does not come through here.
    @objc private func runStandardPreset() {
        fixSelection(preset: .standard)
    }

    @objc private func runAlternatePreset() {
        fixSelection(preset: .alternate)
    }

    private func fixSelection(preset: Preset) {
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

        // Armed before the pasteboard is touched, not after. `copySelection` pumps the main run
        // loop for up to 250ms waiting on the synthetic ⌘C, so a second ⌃⌥D delivered in that
        // window re-enters this method; with the guard set later it passed, and snapshotted a
        // pasteboard that by then held the copied selection. That is the permanent loss of the
        // user's clipboard this guard exists to prevent.
        isBusy = true

        let snapshot = TextCapture.snapshotPasteboard()
        guard let selection = TextCapture.copySelection() else {
            TextCapture.restore(snapshot)
            isBusy = false
            Toast.shared.show("No text selected — highlight something first.", isError: true)
            return
        }

        StatusIcon.shared.setState(.working)

        ClaudeRunner.shared.fixAsync(selection, preset: preset) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let outcome):
                let pastedChangeCount = TextCapture.paste(outcome.text)
                StatusIcon.shared.setState(.idle)
                // Stay busy until the clipboard is back to how the user left it. Releasing the
                // guard at completion instead would let a second ⌃⌥D snapshot the correction that
                // is still sitting on the pasteboard, and the original would be lost for good.
                DispatchQueue.main.asyncAfter(deadline: .now() + TextCapture.clipboardRestoreDelay) {
                    TextCapture.restore(snapshot, ifUnchangedSince: pastedChangeCount)
                    self.isBusy = false
                }
            case .failure(let failure):
                TextCapture.restore(snapshot)
                self.isBusy = false
                StatusIcon.shared.flashError()
                Toast.shared.show(failure.description, isError: true, duration: 5)
            }
        }
    }
}
