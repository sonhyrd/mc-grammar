import AppKit

/// The Translate hand-off: opens the selection in Google Translate in the user's browser.
///
/// A hand-off, not a preset (see `CONTEXT.md`). Nothing is asked of the CLI and nothing is put
/// back into the host app, so `Preset` — which carries a prompt, a role and a ⌘V — is the wrong
/// shape for it, and `Preset.alternate` assumes there are exactly two of those anyway. What lives
/// here is the part `--selftest` needs headless: the URL builder, the target-language read, and
/// the one `NSMessage` string. See docs/adr/0003-translate-is-a-hand-off-not-a-preset.md.
enum Translate {
    /// The `NSMessage` string of the send-only Services entry and the `@objc` selector name on
    /// `ServiceProvider` it must equal. Pinned forever once shipped, like `fixGrammar`: renaming
    /// it unregisters the service under every existing install.
    static let serviceMessage = "translateText"

    /// Google Translate's text box holds 5,000 characters; past that the page keeps the first
    /// 5,000 and shows a banner. The page still opens; the caller's job is to say so, never to cut
    /// the text itself.
    static let googleCharacterLimit = 5_000

    /// Google's server answers HTTP 400 to a URL longer than this, whatever the character count
    /// (measured 2026-08-30: 16,412 bytes passed, 16,413 failed — see ADR 0003). Rounded down to
    /// a power of two. A URL over this opens an error page, so it is refused before the browser.
    static let maxURLBytes = 16_384

    /// Target language, as Google's code (`vi`, `ja`, `zh-CN`). Unvalidated on purpose: a bad
    /// code is reported by Google's page, visibly, and a language table here would not be.
    ///   defaults write com.zernonia.mcgrammar TranslateTarget ja
    static var target: String {
        let override = UserDefaults.standard.string(forKey: "TranslateTarget") ?? ""
        return override.isEmpty ? "vi" : override
    }

    /// RFC 3986 unreserved characters, spelled out as ASCII. Not `.alphanumerics`: that set is
    /// Unicode, so it leaves Vietnamese letters raw and `URL(string:)` returns nil. Not
    /// `.urlQueryAllowed` or `URLComponents.queryItems`: both leave `+` bare, which Google decodes
    /// as a space.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// The page to open for `text`. Source language is always auto-detected. The selection is
    /// percent-encoded byte by byte and never string-interpolated unencoded.
    static func url(for text: String, target: String = Translate.target) -> URL {
        // Every character outside `unreserved` is encoded, so this cannot return nil.
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: unreserved)!
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: unreserved)!
        return URL(string: "https://translate.google.com/?sl=auto&tl=\(encodedTarget)&text=\(encodedText)&op=translate")!
    }

    static func exceedsURLLimit(_ url: URL) -> Bool {
        url.absoluteString.utf8.count > maxURLBytes
    }

    /// Opens the page for `text`, from either trigger path. Never truncates: the cut past 5,000
    /// characters is Google's, and the toast says so. The only hard failure is the workspace
    /// refusing the URL. No success toast — the browser coming to the front is the signal.
    @discardableResult
    static func open(_ text: String) -> Bool {
        let url = url(for: text)
        guard !exceedsURLLimit(url) else {
            StatusIcon.shared.flashError()
            Toast.shared.show("Selection is too long for Google Translate's URL (\(url.absoluteString.utf8.count / 1024) KB, limit 16 KB). Your text was not changed.", isError: true, duration: 6)
            return false
        }
        guard NSWorkspace.shared.open(url) else {
            StatusIcon.shared.flashError()
            Toast.shared.show("McGrammar could not open your browser. Your text was not changed.", isError: true, duration: 5)
            return false
        }
        if text.count > googleCharacterLimit {
            Toast.shared.show("Google Translate only translates the first \(googleCharacterLimit) characters.", duration: 5)
        }
        return true
    }
}
