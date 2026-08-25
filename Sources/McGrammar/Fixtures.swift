import Foundation

/// One accuracy case for `--fixtures`. Assertions are on substrings, never exact output — a
/// future model point-release changing an optional comma must not turn the suite red. Required
/// substrings prove the target error class was actually caught; forbidden substrings catch the
/// opposite failure mode, where the prompt drifts from "correct" into "rewrite" and destroys
/// something that should have survived untouched (a fragment, a code snippet, a line break).
struct Fixture {
    let name: String
    /// The error classes (or preservation properties) this case exercises.
    let annotation: String
    let input: String
    let required: [String]
    let forbidden: [String]
}

/// `McGrammar --fixtures` — a deliberate accuracy suite for the pinned model. See CLAUDE.md and
/// issue #8: this proves the pinned small model still catches the errors a large one would,
/// without pinning the suite to one model's exact phrasing.
///
/// Deliberately NOT wired into `--selftest` or `swift test`: it costs money, needs a live login,
/// and should not fire on every pre-flight or in CI.
enum Fixtures {
    static let all: [Fixture] = [
        Fixture(
            name: "the-comparison-paragraph",
            annotation: "their/they're, me and him -> he and I, allready, then/than, whos/whose, "
                + "there/their, cant, its/it's, sigificantly, a issue -> an issue — the spec's own model-comparison case",
            input: """
                Their going to the conference next tuesday, and me and him has allready booked the \
                flights—which was cheaper then we expected. The teams whos deliverables are late \
                (mostly infra) needs to update there tickets before friday; otherwise the release \
                cant proceed. Its worth noting that the APIs response time have improved \
                sigificantly, however the p99 latency remain a issue.
                """,
            required: ["They're", "he and I", "already", "than we expected", "whose", "their tickets", "It's", "significantly", "an issue"],
            forbidden: ["Their going", "me and him has", "allready", "then we expected", "whos deliverables", "there tickets", "Its worth", "sigificantly", "a issue"]
        ),
        Fixture(
            name: "subject-verb-disagreement",
            annotation: "subject-verb disagreement",
            input: "The list of requirements are still growing, and each of the reviewers have their own concerns.",
            required: ["is still growing", "has"],
            forbidden: ["are still growing", "each of the reviewers have"]
        ),
        Fixture(
            name: "theyre-there-their",
            annotation: "their/there/they're",
            input: "Their going to leave they're bags over there house, and there not sure when there coming back.",
            required: ["They're going", "their bags", "their house", "they're not sure", "they're coming back"],
            forbidden: ["Their going", "they're bags", "there house", "there not sure", "there coming back"]
        ),
        Fixture(
            name: "whos-whose",
            annotation: "whos/whose",
            input: "The engineer whos code broke the build is the one whos going to fix it.",
            required: ["whose code", "who's going"],
            forbidden: ["whos code", "whos going"]
        ),
        Fixture(
            name: "then-than",
            annotation: "then/than",
            input: "This release is more stable then the last one, and we shipped it faster then we planned.",
            required: ["stable than", "faster than"],
            forbidden: ["stable then", "faster then"]
        ),
        Fixture(
            name: "comma-splice",
            annotation: "comma splice",
            input: "The build passed, the tests were still flaky, we merged it anyway, nobody was happy about it.",
            required: [],
            forbidden: ["passed, the tests were still flaky, we merged it anyway, nobody"]
        ),
        Fixture(
            name: "possessive-apostrophes",
            annotation: "possessive apostrophes",
            input: "The teams deliverable slipped again, and the managers report blamed the vendors delay for it.",
            required: ["team's deliverable", "manager's report", "vendor's delay"],
            forbidden: ["The teams deliverable", "the managers report", "the vendors delay"]
        ),
        Fixture(
            name: "pronoun-case",
            annotation: "pronoun case (object vs subject)",
            input: "Him and me are presenting the roadmap, and the client sent the follow-up notes to she and I.",
            required: ["He and I", "her and me"],
            forbidden: ["Him and me are presenting", "to she and I"]
        ),
        Fixture(
            name: "its-vs-its",
            annotation: "its/it's",
            input: "Its raining outside and the API lost it's connection right as its about to finish.",
            required: ["It's raining", "its connection", "it's about"],
            forbidden: ["Its raining", "it's connection", "its about"]
        ),
        Fixture(
            name: "misspellings",
            annotation: "misspellings",
            input: "We recieved the seperate reports and definately need to reccommend a diffrent aproach.",
            required: ["received", "separate", "definitely", "recommend", "different", "approach"],
            forbidden: ["recieved", "seperate", "definately", "reccommend", "diffrent", "aproach"]
        ),
        Fixture(
            name: "run-on-and-double-negative",
            annotation: "run-on sentence, double negative",
            input: "We dont have no time left so we should of shipped this yesterday and we didnt tell no one about the delay.",
            required: ["don't have any time", "should have shipped", "didn't tell anyone"],
            forbidden: ["dont have no time", "should of shipped", "didnt tell no one"]
        ),
        Fixture(
            name: "preserve-code-snippet",
            annotation: "must LEAVE ALONE: inline code / identifiers",
            input: "The fix is to call `fixSync(text)` instead of `fixAsync(text, completion:)`, since it dont block the caller no different.",
            required: ["`fixSync(text)`", "`fixAsync(text, completion:)`"],
            forbidden: ["fixSync (text)", "fix Sync(text)"]
        ),
        Fixture(
            name: "preserve-sentence-fragment",
            annotation: "must LEAVE ALONE: deliberate stylistic fragment",
            input: "Shipped the fix. Finally. No more flaky tests, no more late-night pages.",
            required: [],
            forbidden: ["Shipped the fix, finally", "It was finally shipped"]
        ),
        Fixture(
            name: "preserve-nested-quotes",
            annotation: "must LEAVE ALONE: nested quotation marks",
            input: "The reviewer wrote, \"Please rerun 'make test' before merging,\" in the PR comments.",
            required: ["\"Please rerun 'make test' before merging,\""],
            forbidden: ["“Please rerun “make test” before merging,”"]
        ),
        Fixture(
            name: "preserve-line-breaks",
            annotation: "must LEAVE ALONE: preserved line breaks (e.g. a list-like structure)",
            input: "Steps before release:\nrun the tests\ntag the build\nnotify the team",
            // This fixture proves ONE thing: the line breaks survive. It deliberately asserts
            // nothing about the text of each item, because the model legitimately (and only
            // sometimes) capitalises a list item and adds a terminal full stop — both are
            // punctuation and capitalisation fixes, which the prompt explicitly asks for. Two
            // earlier versions of this fixture asserted on "run the tests\n" and then on
            // "the tests\n", and both flaked for that reason rather than for anything to do
            // with line breaks. So the structure is checked negatively instead: every way the
            // three items could be collapsed onto one line is forbidden.
            required: ["tests", "build", "team"],
            forbidden: [
                "tests tag", "tests, tag", "tests. Tag", "tests and tag",
                "build notify", "build, notify", "build. Notify", "build and notify",
            ]
        ),
    ]

    static func run() -> Int32 {
        print("McGrammar fixture suite — \(all.count) case(s)")
        print(String(repeating: "─", count: 52))

        var failureCount = 0
        let started = Date()

        for fixture in all {
            let caseStarted = Date()
            print("· \(fixture.name) [\(fixture.annotation)]")

            switch ClaudeRunner.shared.fixSync(fixture.input) {
            case .failure(let failure):
                failureCount += 1
                print("  ✗ CLI call failed: \(failure.description)")

            case .success(let outcome):
                let text = outcome.text
                var caseFailed = false

                for needle in fixture.required where !text.contains(needle) {
                    caseFailed = true
                    print("  ✗ missing required substring: \"\(needle)\"")
                }
                for needle in fixture.forbidden where text.contains(needle) {
                    caseFailed = true
                    print("  ✗ found forbidden substring: \"\(needle)\"")
                }

                let elapsed = Date().timeIntervalSince(caseStarted)
                if caseFailed {
                    failureCount += 1
                    print("  → \(text)")
                    print("  (\(String(format: "%.1f", elapsed))s)")
                } else {
                    print("  ✓ (\(String(format: "%.1f", elapsed))s)")
                }
            }
        }

        let totalElapsed = Date().timeIntervalSince(started)
        print(String(repeating: "─", count: 52))
        if failureCount == 0 {
            print("All \(all.count) fixture(s) passed in \(String(format: "%.1f", totalElapsed))s.")
            return 0
        }
        print("\(failureCount)/\(all.count) fixture(s) failed in \(String(format: "%.1f", totalElapsed))s.")
        return 1
    }
}
