import AppKit

/// Headless checks so the whole Claude bridge can be validated from a terminal, without the
/// menu bar, Accessibility grants, or the Services cache being involved.
enum SelfTest {
    /// Proofread's sample: obvious surface errors, so a correct answer is unambiguous.
    private static let proofreadSample = "this are a sentense with mistake, and it dont have good puncutation"
    /// Polish's sample: deliberately grammatical. Nothing here is an *error*, which is the point —
    /// a preset that only corrects would return this unchanged, and that is the regression this
    /// round trip is here to notice.
    private static let polishSample = "We would like to make a discussion about the problem which was happened in the last week."

    static func run() -> Int32 {
        var failures = 0
        print("McGrammar self-test")
        print(String(repeating: "─", count: 52))

        // 1. Environment hygiene: an API key would silently take precedence over the subscription login.
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            print("!  ANTHROPIC_API_KEY is set in this shell.")
            print("   McGrammar strips it from the child process, so the fix below still uses your")
            print("   subscription login — but unset it in your shell profile to avoid surprises.")
        } else {
            print("✓  No ANTHROPIC_API_KEY in the environment (subscription login will be used).")
        }

        // 2. Binary discovery — the failure mode that bites GUI launches.
        let path = ClaudeRunner.shared.resolveBinary()
        if let path {
            print("✓  Claude CLI resolved: \(path)")
        } else {
            print("✗  Claude CLI not found. \(ClaudeRunner.shared.resolutionDetail)")
            failures += 1
        }

        // 3. Bundle wiring, when running from inside McGrammar.app.
        if let services = Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]] {
            // Every NSMessage must name a selector that actually exists on the provider. A typo
            // here is silent: macOS registers the menu item and the click does nothing.
            let declared = services.compactMap { $0["NSMessage"] as? String }
            let expected = ["fixGrammar", "polishText"]
            if Set(declared) == Set(expected) {
                print("✓  Info.plist declares both services: \(declared.joined(separator: ", "))")
            } else {
                print("✗  Info.plist declares \(declared) — expected exactly \(expected)")
                failures += 1
            }
            for message in declared where !ServiceProvider.responds(to: message) {
                print("✗  Info.plist NSMessage=\(message) has no matching @objc selector on ServiceProvider")
                failures += 1
            }
            // NSReturnTypes is what makes a service replace the selection instead of merely
            // receiving it. Missing on any one entry and that entry silently stops working.
            let missingReturnTypes = services.filter { ($0["NSReturnTypes"] as? [String])?.isEmpty ?? true }
            if missingReturnTypes.isEmpty {
                print("✓  Every service declares NSReturnTypes (selection replacement will work)")
            } else {
                print("✗  \(missingReturnTypes.count) service(s) missing NSReturnTypes — they would be send-only")
                failures += 1
            }
        } else {
            print("·  Not running from the .app bundle — skipping Info.plist checks.")
        }

        // 4. Accessibility is informational: only the hotkey path needs it.
        if TextCapture.hasAccessibilityPermission {
            print("✓  Accessibility permission granted (hotkey path available).")
        } else {
            print("·  Accessibility not granted for this process — the Services path still works.")
        }

        // 5. Output shaping, proved without spawning the CLI. These assertions cost nothing, so
        //    they run unconditionally — including when the CLI is missing entirely.
        for check in whitespaceChecks() {
            if check.passed {
                print("\u{2713}  \(check.name)")
            } else {
                print("\u{2717}  \(check.name) — \(check.detail)")
                failures += 1
            }
        }

        // 6. The real round trip.
        guard path != nil else {
            print(String(repeating: "─", count: 52))
            print("FAILED — install Claude Code and run `claude login`, then re-run.")
            return 1
        }

        for (preset, sample) in [(Preset.proofread, proofreadSample), (Preset.polish, polishSample)] {
            failures += roundTrip(preset: preset, sample: sample)
        }

        // 7. Nothing should be left behind by the run that just happened.
        let leftover = Transcripts.pendingCount()
        if leftover == 0 {
            print("✓  No CLI transcripts left behind (\(Transcripts.workspaceURL.path))")
        } else {
            // A failure, not a warning. The privacy guarantee is that nothing is left on disk, and
            // README points at this check as the thing that proves it — counting it as a note let
            // a broken purge exit 0 and report "All checks passed" over a pile of the user's text.
            print("✗  \(leftover) transcript(s) still in McGrammar's CLI workspace.")
            print("   Expected 0 — the cleanup either did not match the CLI's storage layout or")
            print("   another fix was running concurrently. Inspect ~/.claude/projects.")
            failures += 1
        }

        print(String(repeating: "─", count: 52))
        if failures == 0 {
            print("All checks passed.")
            return 0
        }
        print("\(failures) check(s) failed.")
        return 1
    }

    private struct Check {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// Deterministic coverage for `ClaudeRunner.restoreOuterWhitespace`.
    ///
    /// The last case is the one that matters: a response of nothing but whitespace must fail as
    /// empty output rather than being decorated with the selection's own whitespace and pasted
    /// back as a success.
    private static func whitespaceChecks() -> [Check] {
        func shaping(_ name: String, from original: String, onto raw: String, expect: String) -> Check {
            guard case .success(let value) = ClaudeRunner.restoreOuterWhitespace(from: original, onto: raw) else {
                return Check(name: name, passed: false, detail: "expected success, got a failure")
            }
            return Check(name: name, passed: value == expect, detail: "got \(String(reflecting: value))")
        }

        var checks: [Check] = []

        checks.append(shaping(
            "A trailing newline in the selection survives the round trip",
            from: "Fix this.\n", onto: "Fixed this.", expect: "Fixed this.\n"
        ))
        checks.append(shaping(
            "Leading indentation is taken from the selection, not the model",
            from: "    indented line", onto: "  indented line  ", expect: "    indented line"
        ))
        checks.append(shaping(
            "Leading and trailing whitespace are both restored",
            from: "\n\n  padded  \n\n", onto: "padded", expect: "\n\n  padded  \n\n"
        ))
        checks.append(shaping(
            "A selection with no outer whitespace gains none",
            from: "no padding", onto: "no padding", expect: "no padding"
        ))

        var blankRejected = false
        if case .failure(let error) = ClaudeRunner.restoreOuterWhitespace(from: "Fix this.\n", onto: "   \n\t  \n "),
           case .emptyOutput = error {
            blankRejected = true
        }
        checks.append(Check(
            name: "A whitespace-only response fails as empty output, before whitespace is restored",
            passed: blankRejected,
            detail: blankRejected ? "" : "it was NOT rejected — it would be pasted over the selection"
        ))

        return checks
    }

    /// One live fix per preset. Returns the number of failures it found.
    private static func roundTrip(preset: Preset, sample: String) -> Int {
        var failures = 0
        print("·  \(preset.displayName): \"\(sample)\"")
        let started = Date()
        let result = ClaudeRunner.shared.fixSync(sample, preset: preset)
        let elapsed = Date().timeIntervalSince(started)

        switch result {
        case .success(let outcome):
            print("✓  \(preset.displayName) round trip completed in \(String(format: "%.1f", elapsed))s (CLI reported \(outcome.durationMs)ms, model \(outcome.model), \(outcome.thinkingTokens) thinking tokens)")
            print("   → \(outcome.text)")
            if outcome.text == sample {
                print("!  Output is identical to the input — check the prompt or the CLI version.")
            }
            if outcome.thinkingTokens == 0 {
                print("✓  Extended thinking is off (0 thinking tokens).")
            } else {
                // A failure, not a warning. MAX_THINKING_TOKENS=0 is an environment variable, not a
                // documented CLI flag, and it is the single largest latency lever we have — see
                // docs/adr/0001-isolate-the-claude-code-invocation.md for the measured wall-clock
                // figures (~2.25s with thinking off, floored by CLI process startup, not inference).
                // The model was previously spending ~90% of its output budget reasoning about a
                // six-word typo. A future CLI that silently ignores the variable would reintroduce
                // that cost and latency with nothing else failing, so this tripwire exists
                // specifically to catch that regression.
                print("✗  Extended thinking is ON (\(outcome.thinkingTokens) thinking tokens).")
                print("   MAX_THINKING_TOKENS=0 is being ignored by the installed CLI. Latency will")
                print("   have roughly doubled as a result. Check the CLI version and the environment")
                print("   passed to the child process.")
                failures += 1
            }
        case .failure(let failure):
            print("✗  Round trip failed: \(failure.description)")
            failures += 1
        }
        return failures
    }
}
