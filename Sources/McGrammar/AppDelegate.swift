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
    /// ⌃⌥F — the Translate hand-off. Not a preset: nothing is asked of the CLI and nothing is
    /// pasted back. See `Translate`.
    private let translateHotKey = HotKey()
    private let serviceProvider = ServiceProvider()
    private let menu = NSMenu()

    private var claudeStatusItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?
    private var standardHotKeyRegistration: HotKeyRegistration = .notAttempted
    private var alternateHotKeyRegistration: HotKeyRegistration = .notAttempted
    private var translateHotKeyRegistration: HotKeyRegistration = .notAttempted
    private var isBusy = false

    /// Bumped whenever the default preset changes, so a future change can notify again instead of
    /// being permanently silenced by this one. A plain boolean would have been a one-shot.
    private static let defaultPresetNoticeGeneration = 1

    /// Holds a build fingerprint, not a flag — see `installedBuildFingerprint`. Named once because
    /// two call sites reading it under different spellings is exactly how the upgrade notice came
    /// to be gated on a key nothing wrote.
    private static let accessibilityPromptKey = "promptedForAccessibilityByBuild"

    /// Named for the same reason as `accessibilityPromptKey`: a defaults key spelled out at its
    /// read site is a key the next edit can misspell in silence.
    private static let defaultPresetNoticeKey = "defaultPresetNoticeGeneration"

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
        translateHotKeyRegistration = translateHotKey.register(
            keyCode: UInt32(kVK_ANSI_F),
            modifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in
            self?.translateSelection()
        }

        DispatchQueue.global(qos: .utility).async {
            ClaudeRunner.shared.resolveBinary()
            DispatchQueue.main.async { self.refreshMenuState() }
        }

        // Sampled BEFORE promptForAccessibilityOnFirstLaunch, which writes this key on its way
        // through and would otherwise make every fresh install look like an upgrade.
        let hasRunPreviously = UserDefaults.standard.string(forKey: Self.accessibilityPromptKey) != nil
        promptForAccessibilityOnFirstLaunch()
        // One main-queue hop later, not inline. promptForAccessibilityOnFirstLaunch can put the
        // system TCC dialog on screen, and an upgrading user without the grant would otherwise
        // get our modal stacked on top of it at launch of an app with no Dock icon to explain
        // where either came from.
        DispatchQueue.main.async { [weak self] in
            self?.announceDefaultPresetChangeIfNeeded(hasRunPreviously: hasRunPreviously)
        }
    }

    /// macOS shows the "McGrammar would like to control this computer" dialog at most once per
    /// app identity, and only in response to a call from the running app — a build script cannot
    /// trigger it. So ask once, on the first launch of a freshly installed bundle, rather than
    /// leaving the user to discover the menu item. The Services path never needs this, which is
    /// why a decline is silent: the app stays fully usable.
    private func promptForAccessibilityOnFirstLaunch() {
        let build = Self.installedBuildFingerprint()
        guard UserDefaults.standard.string(forKey: Self.accessibilityPromptKey) != build else { return }
        UserDefaults.standard.set(build, forKey: Self.accessibilityPromptKey)
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

    /// Tells an existing installation, once, that the gesture it has been using now does something
    /// different — and how to get the old behaviour back.
    ///
    /// Only existing installations. A fresh install never had the old behaviour, so announcing a
    /// change to it is noise. `hasRunPreviously` must be sampled by the caller before the
    /// Accessibility prompt runs, because that prompt writes the very key this reads. Fresh
    /// installs still get the generation recorded, so they are not told about this change later.
    ///
    /// An alert rather than a toast, deliberately. The default of a destructive-by-nature gesture
    /// changed: a toast at launch is missable, and a notice about a surprise that the user misses
    /// is the surprise, not the notice. It carries the remedy, because announcing that something
    /// someone relies on has moved without saying where it went converts a surprise into a
    /// complaint.
    private func announceDefaultPresetChangeIfNeeded(hasRunPreviously: Bool) {
        let defaults = UserDefaults.standard
        let key = Self.defaultPresetNoticeKey
        guard defaults.integer(forKey: key) < Self.defaultPresetNoticeGeneration else { return }

        // Recorded here for a fresh install, which has no old behaviour to be surprised by and so
        // must not be told about this change later. For an upgrading user it is recorded only
        // after the alert has actually been on screen: spending the generation before `runModal`
        // returns would leave anyone whose alert did not display permanently un-notified about a
        // default that now rewrites their wording.
        guard hasRunPreviously else {
            defaults.set(Self.defaultPresetNoticeGeneration, forKey: key)
            return
        }

        let alert = NSAlert()
        alert.messageText = "⌃⌥D now runs \(Preset.standard.displayName)"
        alert.informativeText = """
            McGrammar used to correct only grammar, spelling and punctuation. \
            ⌃⌥D now also rewrites your selection to read more naturally, which means it can change \
            wording you did not think was wrong.

            To get the old behaviour, use ⌃⌥⇧D, or right-click → Services → \
            "\(Preset.alternate.displayName) with McGrammar".
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        defaults.set(Self.defaultPresetNoticeGeneration, forKey: key)
    }

    func applicationWillTerminate(_ notification: Notification) {
        standardHotKey.unregister()
        alternateHotKey.unregister()
        translateHotKey.unregister()
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

        let translateItem = NSMenuItem(
            title: "Translate Selected Text",
            action: #selector(runTranslate),
            keyEquivalent: "f"
        )
        translateItem.keyEquivalentModifierMask = [.control, .option]
        translateItem.target = self
        menu.addItem(translateItem)

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
            accessibilityItem?.title = "Accessibility: granted (\(hotKeyStatusSummary()))"
        } else {
            // The registration status is reported here too. Carbon registration does not need
            // Accessibility — only the synthetic keystrokes do — so a combination can be taken by
            // another app while the grant is also missing, and this is the state a user debugging
            // a dead hotkey is most likely to be in.
            accessibilityItem?.title =
                "Accessibility: not granted — click to fix (\(hotKeyStatusSummary()))"
        }
    }

    private func hotKeyStatusSummary() -> String {
        let standard = standardHotKeyRegistration.isRegistered
            ? "⌃⌥D active"
            : "⌃⌥D \(standardHotKeyRegistration.detail)"
        let alternate = alternateHotKeyRegistration.isRegistered
            ? "⌃⌥⇧D active"
            : "⌃⌥⇧D \(alternateHotKeyRegistration.detail)"
        let translate = translateHotKeyRegistration.isRegistered
            ? "⌃⌥F active"
            : "⌃⌥F \(translateHotKeyRegistration.detail)"
        return "\(standard), \(alternate), \(translate)"
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
        Toast.shared.show(
            "Keyboard → Keyboard Shortcuts → Services → Text → “\(Preset.standard.displayName) with McGrammar” and “\(Preset.alternate.displayName) with McGrammar”",
            duration: 6
        )
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

    @objc private func runTranslate() {
        translateSelection()
    }

    /// The Translate hand-off from ⌃⌥F and the menu item: copy the selection, hand the clipboard
    /// straight back, open Google Translate. Nothing is pasted, so there is no restore delay to
    /// wait out and no `.working` state — the browser coming to the front is the success signal,
    /// which is also why there is no success toast.
    private func translateSelection() {
        // Same guard as a fix, for the same reason: this writes the general pasteboard, and
        // running it during a fix's restore window would snapshot the correction as if it were
        // the user's clipboard.
        guard !isBusy else {
            Toast.shared.show("Already working on a fix…")
            return
        }
        guard TextCapture.hasAccessibilityPermission else {
            Toast.shared.show(
                "McGrammar needs Accessibility permission for the hotkey. Grant it in System Settings → Privacy & Security → Accessibility, or use right-click → Services → Translate with McGrammar.",
                isError: true,
                duration: 6
            )
            TextCapture.requestAccessibilityPermission()
            return
        }
        isBusy = true
        let snapshot = TextCapture.snapshotPasteboard()
        let selection = TextCapture.copySelection()
        TextCapture.restore(snapshot)
        isBusy = false

        guard let selection else {
            Toast.shared.show("No text selected — highlight something first.", isError: true)
            return
        }
        Translate.open(selection)
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
                let paste = TextCapture.paste(outcome.text)
                StatusIcon.shared.setState(.idle)
                // Report the paste, not the call. They are different moments: the CLI can return a
                // clean result and the keystroke can still never be delivered, if the Accessibility
                // grant was revoked while the fix was in flight. A toast saying "Polished" when
                // nothing was replaced is worse than no toast at all, because this signal exists
                // precisely so the user knows a rewrite happened to their text.
                if paste.delivered {
                    Toast.shared.show(preset.completionVerb, duration: Toast.successDuration)
                } else {
                    StatusIcon.shared.flashError()
                    Toast.shared.show(
                        "McGrammar could not paste the result — check Accessibility permission. Your text was not changed.",
                        isError: true,
                        duration: 6
                    )
                }
                // Stay busy until the clipboard is back to how the user left it. Releasing the
                // guard at completion instead would let a second ⌃⌥D snapshot the correction that
                // is still sitting on the pasteboard, and the original would be lost for good.
                DispatchQueue.main.asyncAfter(deadline: .now() + TextCapture.clipboardRestoreDelay) {
                    TextCapture.restore(snapshot, ifUnchangedSince: paste.changeCount)
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
