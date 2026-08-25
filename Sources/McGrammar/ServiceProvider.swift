import AppKit

/// Handles the right-click → Services → “Fix Grammar with McGrammar” path.
///
/// macOS hands us the selected text on a pasteboard and replaces the user's selection with
/// whatever we write back, natively — no Accessibility permission, no synthetic keystrokes.
/// That only works because `NSReturnTypes` is declared in Info.plist alongside `NSSendTypes`.
final class ServiceProvider: NSObject {
    /// The selector name here must stay exactly in sync with `NSMessage` in Info.plist.
    ///
    /// CRITICAL INVARIANT: this runs on the main thread and must call `fixSync` directly.
    /// Wrapping `fixAsync` in a semaphore here deadlocks — the completion dispatches to main,
    /// which this handler is blocking. Do not "improve" it that way.
    @objc func fixGrammar(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = "No text was selected." as NSString
            Toast.shared.show("Nothing to fix — the selection was empty.", isError: true)
            return
        }

        StatusIcon.shared.setState(.working)
        let result = ClaudeRunner.shared.fixSync(text)

        switch result {
        case .success(let corrected):
            // declareTypes clears the pasteboard and re-declares in one step; macOS reads the
            // string back out of this same pasteboard to replace the user's selection.
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(corrected, forType: .string)
            StatusIcon.shared.setState(.idle)
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
