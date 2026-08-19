import Foundation

/// Errors surfaced by the Claude Code bridge. Every case is user-presentable.
enum FixError: Error, CustomStringConvertible {
    case claudeNotFound
    case emptyInput
    case timedOut(seconds: Int)
    case launchFailed(String)
    case exited(code: Int32, stderr: String)
    case emptyOutput

    var description: String {
        switch self {
        case .claudeNotFound:
            return "Claude Code CLI not found. Install it and run `claude login`, then use “Re-detect Claude CLI”."
        case .emptyInput:
            return "Nothing to fix — the selection was empty."
        case .timedOut(let seconds):
            return "Claude took longer than \(seconds)s and was stopped."
        case .launchFailed(let message):
            return "Could not launch claude: \(message)"
        case .exited(let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = detail.count > 300 ? String(detail.prefix(300)) + "…" : detail
            return clipped.isEmpty ? "claude exited with code \(code)." : "claude exited with code \(code): \(clipped)"
        case .emptyOutput:
            return "Claude returned an empty result."
        }
    }
}

/// Bridge to the user's locally installed, locally authenticated Claude Code CLI.
///
/// INVARIANT: this app never handles API keys, tokens, or any credential. It shells out to the
/// official `claude` binary the user installed and authenticated themselves, and it strips
/// `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` from the child environment so that inference is
/// always billed to the user's subscription login and never to an API org.
final class ClaudeRunner {
    static let shared = ClaudeRunner()

    static let timeout: TimeInterval = 60

    /// Tuned and deliberately strict. Loosening this makes Claude rewrite instead of correct.
    static let prompt = """
        Fix the grammar, spelling, and punctuation of the text provided via stdin. \
        Preserve the author's voice, tone, formatting, and line breaks. \
        Do NOT rewrite or rephrase beyond what is needed for correctness. \
        Output ONLY the corrected text. No preamble, no quotes, no explanations, no markdown fences.
        """

    private(set) var binaryPath: String?
    private(set) var resolutionDetail: String = "Not detected yet"

    private let lock = NSLock()

    /// Common install locations, prepended to the child PATH. GUI-launched apps do not inherit the
    /// terminal PATH — this plus the login-shell lookup is the fix for the #1 silent failure mode.
    private var searchDirectories: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    // MARK: - Binary discovery

    /// Resolves `claude` through a zsh **login** shell so the user's real PATH is used, then falls
    /// back to scanning well-known install directories. Result is cached; call again to re-detect.
    @discardableResult
    func resolveBinary() -> String? {
        if let viaShell = runCapturing("/bin/zsh", ["-l", "-c", "command -v claude"]),
           let first = viaShell.split(separator: "\n").first {
            let candidate = String(first).trimmingCharacters(in: .whitespaces)
            if isExecutable(candidate) {
                store(path: candidate, detail: "Found via login shell: \(candidate)")
                return candidate
            }
        }

        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent("claude")
            if isExecutable(candidate) {
                store(path: candidate, detail: "Found on disk: \(candidate)")
                return candidate
            }
        }

        store(path: nil, detail: "claude not found — install Claude Code and run `claude login`")
        return nil
    }

    private func store(path: String?, detail: String) {
        lock.lock()
        binaryPath = path
        resolutionDetail = detail
        lock.unlock()
    }

    private func isExecutable(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    private func runCapturing(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Never let an API key shadow the user's subscription login (it takes precedence in the CLI).
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")

        let existing = environment["PATH"] ?? ""
        let prefix = searchDirectories.joined(separator: ":")
        environment["PATH"] = existing.isEmpty ? prefix : "\(prefix):\(existing)"
        return environment
    }

    // MARK: - Correction

    /// Synchronous core. Blocks the calling thread until Claude answers or the watchdog fires.
    ///
    /// CRITICAL INVARIANT: the NSServices handler must call this directly. Never wrap `fixAsync`
    /// in a semaphore from the services handler — that handler runs on the main thread and the
    /// async completion dispatches back to main, which deadlocks with certainty.
    func fixSync(_ text: String) -> Result<String, FixError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyInput) }

        let resolved = binaryPath ?? resolveBinary()
        guard let executable = resolved else { return .failure(.claudeNotFound) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", Self.prompt, "--max-turns", "1"]
        process.environment = childEnvironment()
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes concurrently so a chatty stderr can never fill its buffer and wedge the child.
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        // The selected text goes in over stdin — never interpolated into the argument list, so
        // quotes, backticks and newlines in the user's text cannot be misread as shell syntax.
        // The throwing variant matters: if claude dies before reading, the plain `write` would
        // raise an uncatchable exception (SIGPIPE itself is ignored process-wide in main.swift).
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let watchdog = Watchdog()
        let killer = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            watchdog.trip()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout, execute: killer)

        process.waitUntilExit()
        killer.cancel()
        group.wait()

        if watchdog.tripped {
            return .failure(.timedOut(seconds: Int(Self.timeout)))
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            return .failure(.exited(code: process.terminationStatus, stderr: stderr))
        }

        let raw = String(data: stdoutData, encoding: .utf8) ?? ""
        let cleaned = Self.sanitize(raw)
        guard !cleaned.isEmpty else { return .failure(.emptyOutput) }
        return .success(cleaned)
    }

    /// Async wrapper for the hotkey path only: runs the sync core off-main, completes on main.
    func fixAsync(_ text: String, completion: @escaping (Result<String, FixError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.fixSync(text)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Output hygiene

    /// Trims and strips the occasional markdown fence. If preamble ever leaks through, switch the
    /// invocation to `--output-format json` and read the `result` field instead of over-tuning the prompt.
    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }

        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
}

/// One-bit, thread-safe flag shared between the watchdog and the waiting thread.
private final class Watchdog {
    private let lock = NSLock()
    private var value = false

    var tripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func trip() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
