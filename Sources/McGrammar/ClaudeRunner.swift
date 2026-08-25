import Darwin
import Foundation

/// Everything `fixSync` learned about a successful run, decoded once from `--output-format json`
/// and carried back through the seam rather than discarded. `model` and `thinkingTokens` in
/// particular report what the CLI says actually happened, not what was requested — see the
/// decoding note on `ClaudeJSONResponse`.
struct FixOutcome {
    let text: String
    let model: String
    let thinkingTokens: Int
    let durationMs: Int
}

/// Errors surfaced by the Claude Code bridge. Every case is user-presentable.
enum FixError: Error, CustomStringConvertible {
    case claudeNotFound
    case emptyInput
    case timedOut(seconds: Int)
    case launchFailed(String)
    case exited(code: Int32, stderr: String)
    /// The installed CLI rejected the invocation outright — stderr matched a pattern for an
    /// unrecognized flag or an unrecognized/deprecated model identifier. Distinct from `.exited`
    /// so the user gets an action to take instead of a raw CLI error string. Two real causes
    /// produce this, and the message must stay honest about both: an old CLI that predates
    /// `--setting-sources`/`--tools`/`--system-prompt`/`--strict-mcp-config`, or a pinned model
    /// identifier that has since aged out. `claude update` is the fix for the first and, once a
    /// newer McGrammar ships a fresh pin, effectively the fix for the second too.
    case rejectedInvocation(String)
    case emptyOutput
    case workspaceUnavailable
    /// stdout did not contain a parseable `--output-format json` envelope — a CLI version skew,
    /// or something else writing to stdout ahead of the JSON. Distinct from `.exited` because the
    /// process itself reported success (exit code 0); it is the payload we could not trust.
    case malformedResponse(String)
    /// The JSON parsed cleanly and the process exited 0, but the envelope's own `is_error` field
    /// says the run did not succeed (e.g. it hit `--max-turns 1` without finishing). Exit code
    /// alone would have called this a success and pasted `result` over the user's selection.
    case claudeReportedError(String)

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
        case .rejectedInvocation(let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = detail.count > 300 ? String(detail.prefix(300)) + "…" : detail
            return "Your Claude CLI rejected McGrammar's invocation — try `claude update`."
                + (clipped.isEmpty ? "" : " (\(clipped))")
        case .emptyOutput:
            return "Claude returned an empty result."
        case .workspaceUnavailable:
            return "Could not create McGrammar's private CLI workspace, so the transcript the CLI "
                + "writes could not be cleaned up afterwards. Check free space and permissions on "
                + "~/Library/Application Support."
        case .malformedResponse(let raw):
            let clipped = raw.count > 300 ? String(raw.prefix(300)) + "…" : raw
            return "Claude's response could not be parsed as JSON: \(clipped)"
        case .claudeReportedError(let message):
            let clipped = message.count > 300 ? String(message.prefix(300)) + "…" : message
            return clipped.isEmpty ? "Claude reported an error." : "Claude reported an error: \(clipped)"
        }
    }
}

/// Decodes the `--output-format json` envelope. Field casing is exactly what the CLI emits —
/// mostly snake_case, except `modelUsage` and its contents, which are already camelCase — so this
/// spells out `CodingKeys` per level instead of a blanket `keyDecodingStrategy`.
///
/// `model` is deliberately NOT read from the invocation's `--model` flag: `modelUsage` reports
/// what the CLI actually billed and ran, which is the whole point of widening this seam. With
/// `--max-turns 1` there is exactly one entry; if a future CLI version ever reports more, the
/// first one found is used rather than failing the whole fix over a reporting nuance.
private struct ClaudeJSONResponse: Decodable {
    let isError: Bool
    let result: String
    let durationMs: Int
    let usage: Usage
    let modelUsage: [String: ModelUsageEntry]

    enum CodingKeys: String, CodingKey {
        case isError = "is_error"
        case result
        case durationMs = "duration_ms"
        case usage
        case modelUsage
    }

    struct Usage: Decodable {
        let outputTokensDetails: OutputTokensDetails?

        enum CodingKeys: String, CodingKey {
            case outputTokensDetails = "output_tokens_details"
        }

        struct OutputTokensDetails: Decodable {
            let thinkingTokens: Int

            enum CodingKeys: String, CodingKey {
                case thinkingTokens = "thinking_tokens"
            }
        }
    }

    struct ModelUsageEntry: Decodable {
        let canonicalModel: String
    }

    /// First entry in `modelUsage`, or `nil` if the CLI reported none — that shape is itself a
    /// malformed response, not a model to guess at.
    var canonicalModel: String? {
        modelUsage.values.first?.canonicalModel
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
    /// Grace period between SIGTERM and SIGKILL for a child that refuses to exit.
    static let killGrace: TimeInterval = 5

    /// Dated identifier, never a floating alias — an alias is what silently put the app on Opus in
    /// the first place. A stale dated ID becomes a visible maintenance task instead of an invisible
    /// cost or behaviour change.
    static let model = "claude-haiku-4-5-20251001"

    /// The single source of truth for the correction rules, carried by `--system-prompt`. Tuned and
    /// deliberately strict — loosening this makes Claude rewrite instead of correct. Do not
    /// duplicate any of this text into `promptPointer`; that string exists only to select print mode.
    static let systemPrompt = """
        Fix the grammar, spelling, and punctuation of the text provided via stdin. \
        Preserve the author's voice, tone, formatting, and line breaks. \
        Do NOT rewrite or rephrase beyond what is needed for correctness. \
        Output ONLY the corrected text. No preamble, no quotes, no explanations, no markdown fences.
        """

    /// `-p` cannot be empty — it is what selects print mode — but it must not duplicate
    /// `systemPrompt`. Kept as a bare pointer so the rules live in exactly one constant.
    static let promptPointer = "Correct the text on stdin."

    /// Written by `resolveBinary()` on a background queue and read from the main thread (menu,
    /// self-test) and from `fixSync` on either. Every access goes through `lock` — an
    /// unsynchronised read of a `String?` is not merely stale, it can tear the reference.
    private var _binaryPath: String?
    private var _resolutionDetail: String = "Not detected yet"

    private let lock = NSLock()

    var binaryPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return _binaryPath
    }

    var resolutionDetail: String {
        lock.lock()
        defer { lock.unlock() }
        return _resolutionDetail
    }

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
        _binaryPath = path
        _resolutionDetail = detail
        lock.unlock()
    }

    private func isExecutable(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Grace for the login-shell lookup. A zsh **login** shell sources the user's whole profile,
    /// so a version manager that phones home, a hung completion init, or an interactive `read` in
    /// `.zprofile` can block indefinitely. This call is reached from `fixSync` — on the main thread
    /// via the Services path — long before the 60s watchdog is armed, so it needs its own bound.
    static let discoveryTimeout: TimeInterval = 10

    private func runCapturing(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = ClaudeRunner.discoveryTimeout
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // No spawn, so nothing will close the write end for us; the drain below would block
            // on read() forever. Same reasoning as the launch-failure path in fixSync.
            try? pipe.fileHandleForWriting.close()
            return nil
        }

        var data = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if group.wait(timeout: .now() + Self.killGrace) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            group.wait()
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Never let an API key shadow the user's subscription login (it takes precedence in the CLI).
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")

        // Latency lever, not a credential concern: the model was spending ~90% of its output budget
        // reasoning about a six-word typo. Undocumented CLI env var, so weaker than a real flag —
        // a future self-test tripwire on thinkingTokens would catch a CLI change that ignores it.
        environment["MAX_THINKING_TOKENS"] = "0"

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
    func fixSync(_ text: String) -> Result<FixOutcome, FixError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyInput) }

        let resolved = binaryPath ?? resolveBinary()
        guard let executable = resolved else { return .failure(.claudeNotFound) }

        // The CLI writes a session transcript keyed to its working directory. Running it in a
        // dedicated workspace keeps those out of the user's own project histories and lets us
        // delete ours afterwards — see Transcripts.
        // Never run the CLI somewhere we cannot clean up afterwards — see Transcripts.
        guard let workspace = Transcripts.prepareWorkspace() else {
            return .failure(.workspaceUnavailable)
        }
        defer { Transcripts.purge() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Deliberately blinded, single-purpose invocation — see CLAUDE.md "Invocation". Every flag
        // here is load-bearing and was measured; do not drop one to "restore" the user's settings.
        process.arguments = [
            "-p", Self.promptPointer,
            "--max-turns", "1",
            "--model", Self.model,
            "--setting-sources", "",
            "--tools", "",
            "--strict-mcp-config",
            "--system-prompt", Self.systemPrompt,
            "--output-format", "json",
        ]
        process.environment = childEnvironment()
        process.currentDirectoryURL = workspace

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
            // No spawn happened, so nothing will ever close the write ends for us. Close them by
            // hand or the two drain closures block on read() forever, leaking a thread and three
            // descriptors on every failed launch.
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            group.wait()
            return .failure(.launchFailed(error.localizedDescription))
        }

        // Arm the watchdog BEFORE writing stdin. `write(contentsOf:)` on a pipe blocks once the
        // kernel buffer (16–64 KB) fills, so a large selection handed to a child that stalls
        // before draining would wedge fixSync — on the main thread, via the Services path — with
        // no timer yet running to break it.
        let watch = ProcessWatch()
        let killer = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            watch.trip()
            process.terminate()
        }
        // SIGTERM is a request. If the child is wedged and ignores it, escalate — otherwise
        // waitUntilExit below never returns and the fix never completes.
        let hardKiller = DispatchWorkItem { [weak process] in
            guard let process else { return }
            let pid = process.processIdentifier
            // Checked and signalled atomically against `finish()`: `cancel()` cannot stop a work
            // item that has already started, so without the lock the child could be reaped — and
            // its PID recycled — between the liveness check and the kill, sending SIGKILL to an
            // unrelated process on the user's machine.
            watch.escalate { if process.isRunning { kill(pid, SIGKILL) } }
        }
        let queue = DispatchQueue.global(qos: .utility)
        queue.asyncAfter(deadline: .now() + Self.timeout, execute: killer)
        queue.asyncAfter(deadline: .now() + Self.timeout + Self.killGrace, execute: hardKiller)

        // The selected text goes in over stdin — never interpolated into the argument list, so
        // quotes, backticks and newlines in the user's text cannot be misread as shell syntax.
        // The throwing variant matters: if claude dies before reading, the plain `write` would
        // raise an uncatchable exception (SIGPIPE itself is ignored process-wide in main.swift).
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        process.waitUntilExit()
        watch.finish()
        killer.cancel()
        hardKiller.cancel()
        group.wait()

        // The flag alone, deliberately. Also requiring `terminationReason == .uncaughtSignal`
        // avoids a spurious timeout when the watchdog trips in the microseconds between a normal
        // exit and our reading of it — but it fails in the far worse direction: a child that
        // catches SIGTERM and exits 0 having flushed only part of its answer is then reported as a
        // success, and that truncated text gets pasted over the user's selection. Fail closed. The
        // cost is a rare, honest "took longer than 60s" on a fix that finished within a hair of the
        // deadline; the alternative is silently corrupting the text we were asked to correct.
        if watch.tripped {
            return .failure(.timedOut(seconds: Int(Self.timeout)))
        }
        // Exit code is authoritative for whether the process itself completed normally — it is
        // guaranteed by the OS even if stdout is truncated, empty, or not JSON at all, so it is
        // checked first and short-circuits straight to `.exited` without attempting to parse
        // anything. `is_error` below is a second, independent signal that only means something
        // once we already trust the JSON: the CLI can exit 0 (a clean process exit) while its own
        // envelope reports a logical failure, e.g. hitting `--max-turns 1` without finishing.
        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            if Self.looksLikeRejectedInvocation(stderr) {
                return .failure(.rejectedInvocation(stderr))
            }
            return .failure(.exited(code: process.terminationStatus, stderr: stderr))
        }

        let raw = String(data: stdoutData, encoding: .utf8) ?? ""
        guard let response = Self.parseResponse(raw) else {
            return .failure(.malformedResponse(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if response.isError {
            return .failure(.claudeReportedError(response.result))
        }
        guard let model = response.canonicalModel else {
            return .failure(.malformedResponse(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let text = response.result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyOutput) }

        return .success(FixOutcome(
            text: text,
            model: model,
            thinkingTokens: response.usage.outputTokensDetails?.thinkingTokens ?? 0,
            durationMs: response.durationMs
        ))
    }

    /// Async wrapper for the hotkey path only: runs the sync core off-main, completes on main.
    func fixAsync(_ text: String, completion: @escaping (Result<FixOutcome, FixError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.fixSync(text)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stderr substrings that indicate the CLI rejected the invocation itself, rather than the
    /// model failing to produce a result. Deliberately no capability probe and no graceful
    /// degradation here — see the ticket for why both were rejected. This is intentionally a
    /// pattern match against known CLI error phrasing (commander-style "unknown option", and the
    /// enum-style rejection an invalid `--model` value produces), not an attempt to parse every
    /// possible CLI failure; anything that does not match falls through to the generic `.exited`
    /// case with the raw stderr still visible to the user.
    private static let rejectedInvocationPatterns = [
        "unknown option",
        "unrecognized option",
        "unrecognized arguments",
        "unknown arguments",
        "not a valid choice",
        "invalid model",
        "unrecognized model",
        "unknown model",
        "model not found",
        "no such model",
    ]

    private static func looksLikeRejectedInvocation(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return rejectedInvocationPatterns.contains { lowered.contains($0) }
    }

    // MARK: - Response parsing

    /// Decodes the `--output-format json` envelope from raw stdout. Stdout is expected to be
    /// nothing but that one JSON object, but this is defensive about it not being the only thing
    /// there: it locates the outermost `{...}` span and decodes that, rather than requiring the
    /// whole buffer to be valid JSON on the nose. Returns `nil` for anything that does not decode
    /// — callers turn that into `.malformedResponse`, never a guess at the text.
    private static func parseResponse(_ raw: String) -> ClaudeJSONResponse? {
        guard let firstBrace = raw.firstIndex(of: "{"),
              let lastBrace = raw.lastIndex(of: "}"),
              firstBrace <= lastBrace else { return nil }
        let jsonSlice = raw[firstBrace...lastBrace]
        guard let data = jsonSlice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeJSONResponse.self, from: data)
    }
}

/// Thread-safe state shared between the two watchdog timers and the thread waiting on the child.
private final class ProcessWatch {
    private let lock = NSLock()
    private var timedOut = false
    private var finished = false

    var tripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func trip() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    /// Marks the child as waited-for. After this, `escalate` can never fire.
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// Runs `signal` only while the child is still ours to signal, holding the lock across the
    /// call so the decision cannot race `finish()`.
    func escalate(_ signal: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard timedOut, !finished else { return }
        signal()
    }
}
