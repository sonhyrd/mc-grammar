import Foundation

/// McGrammar itself persists nothing. The Claude Code CLI it invokes does: every `claude -p` run
/// writes a session transcript (containing the text that was corrected) under
/// `~/.claude/projects/<slug of the working directory>/<session>.jsonl`, and those accumulate.
///
/// To keep the privacy guarantee honest and stop that pile-up, McGrammar runs the CLI in a
/// dedicated working directory that nothing else uses, then deletes the transcripts that appear
/// for that directory after each fix.
///
/// Everything here is best-effort and deliberately narrow: only `.jsonl` files, only inside a
/// project directory whose name carries our marker, and only ones written during the run that just
/// finished. If the CLI ever changes where it stores transcripts, this finds nothing and does
/// nothing — it can never reach a directory McGrammar did not cause to exist.
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

    private static var projectsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Creates the workspace if needed and returns it, or nil if it cannot be created (in which
    /// case the caller should fall back to the home directory rather than fail the fix).
    static func prepareWorkspace() -> URL? {
        let url = workspaceURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    /// Directories under `~/.claude/projects` that belong to our workspace.
    private static func ourProjectDirectories() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return (contents ?? []).filter { $0.lastPathComponent.contains(marker) }
    }

    /// Deletes transcripts written at or after `date`. Returns how many were removed.
    @discardableResult
    static func purge(newerThan date: Date) -> Int {
        // One second of slack: filesystem timestamps and our clock reading are not the same clock.
        let cutoff = date.addingTimeInterval(-1)
        var removed = 0
        for directory in ourProjectDirectories() {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modified, modified >= cutoff else { continue }
                do {
                    try FileManager.default.removeItem(at: file)
                    removed += 1
                } catch {
                    // Best effort by design — a transcript we cannot delete is not worth an alert.
                }
            }
        }
        return removed
    }

    /// How many transcripts are sitting in our project directories right now. Used by --selftest
    /// so the cleanup can actually be observed rather than taken on faith.
    static func pendingCount() -> Int {
        ourProjectDirectories().reduce(0) { total, directory in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return total + files.filter { $0.hasSuffix(".jsonl") }.count
        }
    }
}
