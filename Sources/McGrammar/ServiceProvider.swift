import AppKit

/// Handles the right-click → Services → “Polish with McGrammar” / “Proofread with McGrammar” paths.
///
/// macOS hands us the selected text on a pasteboard and replaces the user's selection with
/// whatever we write back, natively — no Accessibility permission, no synthetic keystrokes.
/// That only works because `NSReturnTypes` is declared in Info.plist alongside `NSSendTypes`.
///
/// Every `@objc` entry point here must stay exactly in sync with an `NSMessage` in Info.plist, and
/// each one binds to a preset rather than to whichever preset is default, so flipping the default
/// cannot change what a menu item does.
final class ServiceProvider: NSObject {
    /// Whether the provider actually implements the selector an `NSMessage` names.
    ///
    /// `NSMessage` is a string in Info.plist and nothing checks it at build time: a typo registers
    /// a menu item that silently does nothing when clicked. `--selftest` asks this so the mismatch
    /// is caught on the bench instead of by a user.
    static func responds(to message: String) -> Bool {
        let selector = NSSelectorFromString("\(message):userData:error:")
        return ServiceProvider.instancesRespond(to: selector)
    }

    /// Proofread. The selector name is pinned by `NSMessage` in Info.plist and predates the preset
    /// split, so it keeps its original spelling — renaming it would unregister the service. It is
    /// bound to a *preset*, not to whichever preset happens to be the default, so flipping the
    /// default never changes what this entry does.
    ///
    /// CRITICAL INVARIANT: this runs on the main thread and must call `fixSync` directly.
    /// Wrapping `fixAsync` in a semaphore here deadlocks — the completion dispatches to main,
    /// which this handler is blocking. Do not "improve" it that way.
    @objc func fixGrammar(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        handle(pasteboard, preset: .proofread, error: error)
    }

    /// Polish. Same contract as `fixGrammar`, same main-thread rule, different preset.
    @objc func polishText(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        handle(pasteboard, preset: .polish, error: error)
    }

    private func handle(
        _ pasteboard: NSPasteboard,
        preset: Preset,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = "No text was selected." as NSString
            Toast.shared.show("Nothing to fix — the selection was empty.", isError: true)
            return
        }

        // mainThreadBlocked: true — this handler calls fixSync synchronously on the main thread
        // right below, so the elapsed-counter timer is allowed to mutate the status button
        // directly off-main. See the comment on StatusIcon.setState.
        StatusIcon.shared.setState(.working, mainThreadBlocked: true)
        // Shorter timeout than the hotkey path: these seconds block the host application's main
        // thread, so a wedged fix should unfreeze it as fast as possible.
        let result = ClaudeRunner.shared.fixSync(text, preset: preset, timeout: ClaudeRunner.servicesTimeout)

        switch result {
        case .success(let outcome):
            // declareTypes clears the pasteboard and re-declares in one step; macOS reads the
            // string back out of this same pasteboard to replace the user's selection.
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(outcome.text, forType: .string)
            StatusIcon.shared.setState(.idle)
            // Worded more weakly than the hotkey path's toast, and that difference is deliberate.
            // There, the app posts the ⌘V itself and can say the paste was delivered. Here it
            // writes to the return pasteboard and returns; macOS performs the replacement
            // afterwards with no callback, so there is nothing to observe. Claiming the selection
            // was replaced would be asserting something this path cannot know.
            Toast.shared.show(
                "\(preset.completionVerb) — returned to the app",
                duration: Toast.successDuration
            )
        case .failure(let failure):
            // Clear the return pasteboard explicitly. NSReturnTypes is declared, so leaving the
            // incoming text sitting there invites macOS to "replace" the selection with a plain
            // copy of itself — silently flattening any attributes the selection carried. An empty
            // return pasteboard alongside the error leaves the user's selection alone.
            pasteboard.clearContents()
            error?.pointee = failure.description as NSString
            StatusIcon.shared.flashError()
            Toast.shared.show(failure.description, isError: true, duration: 5)
        }
    }
}
