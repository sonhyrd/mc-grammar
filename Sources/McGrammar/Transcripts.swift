import Foundation

/// McGrammar itself persists nothing. The Claude Code CLI it invokes does: every `claude -p` run
/// writes a session transcript (containing the text that was corrected) under
/// `~/.claude/projects/<slug of the working directory>/<session>.jsonl`, and those accumulate.
///
/// To keep the privacy guarantee honest and stop that pile-up, McGrammar runs the CLI in a
/// dedicated working directory that nothing else uses, then deletes the transcripts that appear
/// for that directory after each fix.
///
/// Everything here is best-effort and deliberately narrow: only `.jsonl` files, and only inside a
/// project directory whose name carries our marker. It is deliberately NOT narrowed by
/// modification time — see `purge()` for why that filter leaks. If the CLI ever changes where it
/// stores transcripts, this finds nothing and does nothing — it can never reach a directory
/// McGrammar did not cause to exist.
enum Transcripts {
    /// Distinctive enough that a slugified path can only match if it is ours.
    static let marker = "McGrammar-cli-workspace"

    /// The working directory handed to the child process. Running the CLI here (rather than in the
    /// user's home) is what isolates our transcripts into their own project directory.
    static var workspaceURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("McGrammar/cli-workspace", isDirectory: true)
    }

    /// Used only if Application Support is unavailable. The path still carries the marker, so
    /// transcripts written here remain isolated and purgeable — the invariant survives the fallback.
    private static var fallbackWorkspaceURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("McGrammar-cli-workspace", isDirectory: true)
    }

    private static var projectsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Creates the workspace if needed and returns it, or nil if no isolated workspace can be made.
    ///
    /// Callers must NOT fall back to the home directory on nil. Transcripts written there land in
    /// an unmarked project folder that `purge` and `pendingCount` both ignore, so the CLI's copies
    /// of the user's text would accumulate for good while the self-test still reported a clean
    /// workspace. Failing the fix is the honest outcome: the promise is that nothing is left on
    /// disk, and here we cannot keep it.
    static func prepareWorkspace() -> URL? {
        for url in [workspaceURL, fallbackWorkspaceURL] {
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
                return url
            }
        }
        return nil
    }

    /// Directories under `~/.claude/projects` that belong to our workspace.
    private static func ourProjectDirectories() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return (contents ?? []).filter { $0.lastPathComponent.contains(marker) }
    }

    /// Every transcript sitting in our project directories. The single definition of "ours" —
    /// `purge` and `pendingCount` must agree on it, or the self-test reports clean on files the
    /// sweep never touches.
    private static func transcriptFiles() -> [URL] {
        ourProjectDirectories().flatMap { directory -> [URL] in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return files.filter { $0.pathExtension == "jsonl" }
        }
    }

    /// Deletes every transcript in our project directories. Returns how many were removed.
    ///
    /// Deliberately not filtered by modification time. Restricting the sweep to files written by
    /// the run that just finished sounds safer but leaks: a transcript that misses its own purge —
    /// flushed late, delete failed once, app quit or crashed mid-fix — is older than every
    /// subsequent run's cutoff and so survives for good, holding the user's text forever.
    ///
    /// Dropping the date costs nothing, because these directories exist only because McGrammar ran
    /// the CLI in a working directory it created. The narrowing that matters is unchanged: the
    /// marker-matched folder, and `.jsonl` only.
    @discardableResult
    static func purge() -> Int {
        var removed = 0
        for file in transcriptFiles() {
            do {
                try FileManager.default.removeItem(at: file)
                removed += 1
            } catch {
                // Best effort by design — a transcript we cannot delete is not worth an alert.
                // The next fix sweeps it up, which is exactly what the date filter prevented.
            }
        }
        return removed
    }

    /// How many transcripts are sitting in our project directories right now. Used by --selftest
    /// so the cleanup can actually be observed rather than taken on faith.
    static func pendingCount() -> Int {
        transcriptFiles().count
    }
}
