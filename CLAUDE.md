# CLAUDE.md — McGrammar

Context and hard invariants for Claude Code sessions in this repository.

## What this is

A macOS menu bar utility (Swift + AppKit, SPM, **zero third-party dependencies**) that rewrites the
user's selected text in any app by shelling out to their locally installed, locally authenticated
Claude Code CLI. Two presets — **Polish** (fluency, the default) and **Proofread** (surface errors
only) — reachable from two independent trigger paths: global hotkeys (⌃⌥D and ⌃⌥⇧D) and NSServices
menu items. Vocabulary is in `CONTEXT.md`; the preset decision is ADR 0002.

## Invariants — do not violate these

### Credentials
- **Never** add an API key path, token handling, or any login flow. The app invokes the official
  `claude` binary the user installed and authenticated themselves. That is the entire compliance
  position; an API-key mode is a roadmap item to be revisited only against current Anthropic policy.
- `ClaudeRunner.childEnvironment()` strips `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`. Keep it
  that way: a key in the environment takes precedence over the subscription login in the CLI.
- Never use `--bare` mode (API-key only).

### Sync/async structure (`ClaudeRunner`)
- `fixSync` is the core and blocks its calling thread. `fixAsync` is a thin wrapper for the hotkey
  path: background queue in, main-thread completion out.
- **The NSServices handler MUST call `fixSync` directly.** Never wrap `fixAsync` in a semaphore
  there — the handler runs on the main thread and the completion dispatches back to main, which
  deadlocks with certainty. This mistake has already been made once on this project.

### Binary discovery
- Resolve `claude` through a **zsh login shell** (`/bin/zsh -l -c 'command -v claude'`) and cache it.
  GUI-launched apps do not inherit the terminal PATH — this is the #1 silent failure mode.
- Keep the disk fallback list (`~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`,
  `/usr/local/bin`) and keep prepending those to the child PATH.
- The resolved path (or the not-found warning) must stay visible in the menu bar dropdown.

### Invocation
`ClaudeRunner.fixSync` calls `claude` with a deliberately isolated flag set. **The full set is an
INVARIANT, not a style choice** — every flag was measured (see
`docs/adr/0001-isolate-the-claude-code-invocation.md`), and dropping one silently reintroduces the
configuration this app exists to avoid: the user's inherited settings, MCP servers, tool
permissions, and a ~30,000-token interactive preamble, at Opus pricing ($0.1497/fix instead of
$0.0003) and roughly 2.6x the latency. Removing a flag here is a regression, not a cleanup.

```
-p <prompt>
--max-turns 1
--model claude-haiku-4-5-20251001
--setting-sources ""
--tools ""
--strict-mcp-config
--system-prompt <one-line role>
--output-format json
```

- The **pinned, dated model ID** (`ClaudeRunner.model`) is deliberate, not a placeholder: a
  floating alias is what put the app on Opus in the first place, invisibly. Bumping it requires
  re-running `--fixtures`, not just `--selftest`.
- `--setting-sources ""` and `--tools ""`, not `--settings <file>` — `--settings` *merges* into
  the user's resolved config rather than replacing it, so it cannot produce an isolated
  invocation. See the ADR's "Rejected alternatives."
- **A preset's rules live in `-p`, not `--system-prompt`, and that placement is an INVARIANT.**
  `--system-prompt` carries a one-line role only, per preset (`Preset.role`). Moving the rules into
  `--system-prompt` reads tidier and measures identically on a
  short input, but on a long multi-error paragraph it fails roughly half the time — 7/15 correct
  vs. 14/14 with the rules in `-p` — and the failures are silent: the user's text usually comes
  back unchanged, occasionally a list of corrections gets pasted over the selection instead of the
  fix. See the ADR for the full finding. Any change to `Preset.prompt` or `Preset.role` must be
  verified with `--fixtures` before merging; `--selftest`'s one easy sample would not have caught
  this. (ADR 0001 names these `ClaudeRunner.prompt` / `ClaudeRunner.systemPrompt`, which is where
  they lived when it was written; the decision it records is unchanged.)
- The user's selected text goes over **stdin**, written after the watchdog is armed — never
  interpolated into `-p`, the rest of the argument list, or a shell string.
- `MAX_THINKING_TOKENS=0` in the child environment (undocumented CLI env var, not a flag — hence
  weaker than the rest of this list). This is the single largest latency lever: without it the
  model spends most of its output budget reasoning about trivial corrections. `--selftest` asserts
  `thinkingTokens == 0` on every run specifically to catch a future CLI that silently stops
  honoring it.
- `--output-format json`, read the `result` field — never parse raw stdout for the corrected text.
- Watchdog timeouts: **15s** on the hotkey path (`ClaudeRunner.hotkeyTimeout`, also used by
  `--fix`/`--selftest`), **10s** on the Services path (`ClaudeRunner.servicesTimeout`) — shorter
  because those seconds block the host application's main thread by design. SIGTERM first, SIGKILL
  after a 5s grace (`killGrace`) if the child ignores it. A tripped watchdog is a timeout, full
  stop — see "Privacy and cleanup" for why `terminationReason` is not also checked.
- `NSTimeout` in Info.plist stays **120000ms** on every preset entry regardless of the above — it
  bounds how long macOS waits for the whole Services round trip including its own dispatch
  overhead, not just the child process, and the default is far too short for Claude Code spin-up.
  The Translate hand-off entry deliberately has none: it runs no child, so the default is right.
- `sanitize()` was deleted because `--output-format json` removed the ambiguity it existed to
  resolve, **not** for any shell-safety reason. It was output hygiene — it stripped Markdown fences
  and preamble from the model's raw stdout — and never had anything to do with shell injection.
  With the JSON envelope, `result` is a typed string field, so a fence inside it is unambiguously
  content rather than framing, and there is nothing left to disambiguate. Do not restore
  fence-stripping: a selection that legitimately *is* a fenced code block, correctly returned
  unchanged, would have its fences eaten and be pasted back malformed. If the model ever starts
  emitting a fence the input did not have, that is a prompt regression and `--fixtures` is where it
  gets caught.
- Drain stdout and stderr concurrently; a blocked pipe buffer wedges the child.
- Real, measured numbers — old vs. isolated invocation, wall clock vs. the CLI's internal
  `duration_ms`, and why the first latency figures were wrong — live in
  `docs/adr/0001-isolate-the-claude-code-invocation.md`, not here. Read it before changing any
  number in this section.

### Presets
- Two, and **`Preset.standard` is the single line that decides which one the primary gesture runs**.
  Changing it must be accompanied by bumping `AppDelegate.defaultPresetNoticeGeneration`, or
  existing users get a gesture that quietly does something else. The flip and its on-screen signal
  ship together — a build where Polish is default and nothing says so silently rewrites the user's
  text.
- Every preset must be reachable from **both** trigger paths. The alternate preset is what a user
  reaches for when the default did something they did not want, so it must never be the one that is
  unreachable in an app that exposes only one path.
- `factualIntegrity` is stated ahead of every other instruction in Polish's prompt — after the
  one framing sentence, and claiming that primacy in its own words ("Before anything else, and
  above every other instruction here") — with its reason, and is proved by the
  `polish-factual-integrity` fixture. The clause, the fixture and `CONTEXT.md` share the name on
  purpose. Weakening the fixture silently unbacks the guarantee the README makes.
- **The success toast is not decoration.** Under Polish the user cannot see what changed — that is
  the point — so the toast naming the preset is the only signal that a rewrite rather than a
  correction happened. It fires on every successful fix, on both paths.
- **The two paths know different things and must not claim the same thing.** The hotkey path posts
  the ⌘V itself and reports whether it was delivered; the Services path hands the text back and
  macOS replaces the selection afterwards with no callback, so it can only report the handover.
  Do not "unify" the wording.

### NSServices (Info.plist)
- `NSMessage` must exactly equal the `@objc` selector name on `NSApp.servicesProvider`:
  `fixGrammar` ↔ `fixGrammar(_:userData:error:)`, `polishText` ↔ `polishText(_:userData:error:)`.
  `--selftest` checks every declared `NSMessage` against a real selector, because nothing validates
  these strings at build time and a typo registers a menu item that silently does nothing.
- Service selectors bind to a **preset**, not to whichever preset is default, so flipping the
  default cannot change what an entry does. `fixGrammar` predates the split and means Proofread.
  The `NSMessage` strings live on `Preset.serviceMessage` so the plist, `ServiceProvider` and
  `--selftest` name one set rather than three.
- **The plist's entry order is not derived from `Preset.standard`** — it is hardcoded, so flipping
  the default in code would otherwise leave the Services menu still leading with the old one.
  `--selftest` asserts that the first entry's `NSMessage` equals `Preset.standard.serviceMessage`;
  a flip means editing the plist order and titles too.
- **No `NSKeyEquivalent`.** It used to declare ⌘⌃⇧G, which the app never registered. The Carbon
  hotkeys are the single keyboard mechanism; adding one back binds the same gesture twice on an
  action that irreversibly overwrites the selection.
- `NSSendTypes` **and** `NSReturnTypes` both `NSStringPboardType` on every **preset** entry.
  Removing `NSReturnTypes` makes the service send-only and selection replacement silently stops
  working. The one exception is the **Translate hand-off** (`translateText`, last in the list):
  it is send-only *by design* — it must never declare `NSReturnTypes`, or macOS pastes the
  selection over itself — and its handler never writes to any pasteboard. `--selftest` asserts
  both directions. Its `NSMessage` string lives on `Translate.serviceMessage` and is pinned
  forever, like `fixGrammar`.
- `NSTimeout` = `120000` ms on preset entries. The default is far too short for Claude Code
  spin-up. The hand-off entry omits it — no child process — and `--selftest` asserts that split.
- Register at launch: `NSApp.servicesProvider = provider; NSUpdateDynamicServices()`.
- macOS caches the Services menu aggressively — `make-app.sh` runs `pbs -flush`/`-update`, and the
  README documents the manual steps. Do not chase this as a bug.

### Bundle
- `LSUIElement = true` plus `NSApp.setActivationPolicy(.accessory)` — menu bar only, no Dock icon.
- Ad-hoc `codesign --force --sign -` **plus an explicit designated requirement**:
  `-r='designated => identifier "com.zernonia.mcgrammar"'`. This is what makes Accessibility (TCC)
  grants survive rebuilds. `--identifier` alone does NOT: it sets the bundle ID in the code
  directory, while codesign still derives a DR that pins the exact `cdhash`. Every rebuild then
  changes the hash and silently voids the grant, and the symptom is nasty — System Settings keeps
  showing a ticked McGrammar entry that no longer matches the binary, so the app re-prompts while
  the user is looking at a checkbox that says it is already allowed. Verify after any change to the
  signing step with `codesign -d --requirements - <app>`; it must print the identifier form, not a
  `cdhash H"..."`. Kill any running instance before replacing the bundle.
- Accessibility permission attaches to the *launching* process — test the hotkey from the .app,
  never from a terminal-launched binary.

### Privacy and cleanup
- Never log, cache, or persist user text anywhere. The README states this as a guarantee. The one
  gesture that sends text off the machine is the Translate hand-off (⌃⌥F → Google, in the URL, so
  it lands in browser history); see "Hand-offs" below. Everything in this section is about the
  fix paths.
- The CLI itself persists what the app does not: `claude -p` writes a session transcript containing
  the corrected text under `~/.claude/projects/<cwd slug>/`. The child therefore runs in
  `~/Library/Application Support/McGrammar/cli-workspace` so those transcripts land in a project
  folder only McGrammar causes to exist, and `Transcripts.purge` deletes them after every fix.
  Keep that purge narrow — `.jsonl` only, marker-matched folder only — so an unknown CLI layout
  degrades to a no-op instead of deleting someone's history. Do **not** re-add a modification-time
  filter: it sounds safer and leaks. A transcript that misses its own run's purge (flushed late,
  delete failed, app quit mid-fix) is then older than every later cutoff and survives for good.
  The folder is ours by construction, so sweeping all of it is both safe and the point.
- `prepareWorkspace()` returning nil must fail the fix (`.workspaceUnavailable`), never fall back
  to the home directory: transcripts there land in an unmarked project folder that the purge and
  `pendingCount` both ignore, so they would pile up while the self-test still reported a clean
  workspace. The temp-directory fallback exists because its path still carries the marker.
- A tripped watchdog is a timeout, full stop. Do not also require `terminationReason ==
  .uncaughtSignal`: a child that catches SIGTERM and exits 0 having flushed a partial answer would
  then be reported as success, and that truncated text gets pasted over the user's selection.
- Every run must leave the machine as it found it: no temp files, no stray child processes, and the
  user's clipboard byte-identical to before. `--selftest` and `scripts/local-test.sh` both assert
  the transcript half of this; do not let it regress.

### Process and clipboard lifecycle
- `TextCapture.copySelection` asks Accessibility whether the focused text element's selection is
  empty **before** posting ⌘C, and returns nil on a definite "empty". Code editors copy the whole
  current line on ⌘C with nothing selected, and the pasteboard-changed probe alone cannot tell
  that line from a selection — so without this a bare ⌃⌥F translates, and a bare ⌃⌥D overwrites,
  a line of code the user never picked. Gated on the text-field/text-area role; when AX cannot
  answer it degrades to the ⌘C probe. Do not drop the pre-check, and do not widen it past a
  definite empty answer.
- If `process.run()` throws, close all three pipe write ends by hand and `group.wait()` before
  returning. No spawn means nothing else will ever close them, and the drain closures would block
  on `read()` forever — a leaked thread and three descriptors per failed launch.
- The watchdog (15s hotkey / 10s Services, see "Invocation") sends SIGTERM, then SIGKILL after a
  5s grace. Without the escalation a wedged child blocks `waitUntilExit` indefinitely and the fix
  never completes.
- The hotkey path stays "busy" until the clipboard has been restored, not merely until Claude
  answers. Releasing the guard earlier lets a second trigger snapshot the correction still sitting
  on the pasteboard, permanently losing the user's original clipboard.

## Testing

- `./scripts/local-test.sh` — full pre-flight (macOS only).
- `McGrammar --selftest` — headless: CLI discovery, env hygiene, Info.plist wiring, and one real
  fix **per preset** — two CLI calls, so it costs and takes roughly twice what it did before the
  presets split.
- `McGrammar --fix` — stdin → corrected text on stdout, byte-faithful (it writes rather than
  prints, so the text's own trailing whitespace is not doubled). Takes `--polish` / `--proofread`.
- `McGrammar --fixtures` — the live accuracy suite (21 cases, ~60s, costs money, needs a login).
  Polish's idiom cases assert **removal, not replacement**: the stilted phrasing is forbidden and no
  particular replacement is required. A fixture that demanded specific wording would go red on a
  good rewrite, and a suite that fails on good output gets ignored.
  Not part of `--selftest` or `swift test` because it isn't free to run on every build, but it is
  mandatory after touching `Preset.prompt`, `Preset.role`, or any invocation
  flag — it is what caught the prompt-placement failure recorded in the ADR, and `--selftest`'s
  one easy sample would not have.
- The Services path cannot be tested from `swift run`; it requires the .app bundle.

### Hand-offs
- A hand-off (`CONTEXT.md`) sends the selection out and changes nothing in the host app. Translate
  is the only one. It is **not** a `Preset` — `Preset.alternate`, the `allCases`-driven selftest
  expectations and `--fix` parsing all assume exactly two — and it never touches `ClaudeRunner`,
  the workspace or the purge; it must work when the CLI is not installed.
- It is the one exception to the privacy guarantee: the text goes to Google in the URL. README and
  `NSHumanReadableCopyright` say so; keep them saying so.
- **Translate's input is the clipboard on the hotkey path and the selection on the Services path,
  and that asymmetry is deliberate.** ⌃⌥F reads `NSPasteboard.general` and posts no ⌘C: the
  gesture is for text the user has already copied, so it needs no Accessibility grant, no busy
  guard and no snapshot/restore, and it cannot disturb the pasteboard. The Services entry gets the
  selection because that is what macOS hands it. Do not "unify" these onto the selection — the
  permission-free, side-effect-free hotkey is the point.
- No success toast — the browser in front is the signal. No `.working` state.
- **Never truncate.** Two ceilings, both Google's and both measured (ADR 0003): the text box keeps
  5,000 characters (open anyway, non-error toast); the server answers 400 past ~16 KB of URL
  (`Translate.maxURLBytes`, refuse with an error toast instead of opening an error page).
- Encoding: an explicit ASCII unreserved set, never `.alphanumerics` (Unicode — leaves Vietnamese
  letters raw) or `.urlQueryAllowed` / `queryItems` (leave `+` bare; Google reads it as a space).

## Roadmap (post-v1, priority order)

1. **Diff preview HUD** before applying: floating panel, Tab = accept, R = regenerate, Esc = cancel.
   Biggest UX win over blind replacement, and worth more now that the default rewrites phrasing.
2. **Streaming** via `--output-format stream-json` for perceived speed.
3. ~~**Prompt presets**~~ — Proofread and Polish shipped with per-preset hotkeys (ADR 0002).
   Remaining: a settings window, and Casual↔Formal as a further preset. Translate shipped as a
   **hand-off** (⌃⌥F → Google Translate, ADR 0003), not a preset. A register-shifting
   preset is the one licensed to change what the text says about itself; keep it an explicit choice
   and never a default.
4. **Async services variant**: return immediately and paste when done. Unblocks the calling app at
   the cost of requiring Accessibility — make it opt-in.
5. **Fallback provider toggle**: direct Anthropic API (Haiku) for sub-second fixes. Also the
   policy hedge.
6. Per-app tone profiles; fix-line-at-cursor when nothing is selected; notarized release packaging.

## Watch items

- Anthropic's stance on third-party subscription usage changed twice in 2026. Re-read
  code.claude.com/docs/en/legal-and-compliance before any distribution, and get written sign-off
  before charging money.
- Agent SDK / programmatic credit caps may change; heavy users can hit monthly limits.
- CLI flags (`-p`, `--max-turns`, `--output-format`) are stable today — verify against current docs
  when upgrading.
- Some Electron and sandboxed apps expose neither Services nor synthetic keystrokes. Having both
  paths is the mitigation; do not remove either.

## Agent skills

### Issue tracker

GitHub Issues on the fork `sonhyrd/mc-grammar` (via `gh --repo`). See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, label strings unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` + `docs/adr/`. See `docs/agents/domain.md`.
