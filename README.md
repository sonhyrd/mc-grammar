# McGrammar

A macOS menu bar utility that fixes grammar, spelling, and punctuation in **any** app — powered by
the Claude Code CLI you already have installed and logged into.

Highlight text anywhere, hit ⌃⌥G (or right-click → Services), and the selection is replaced in
place with a corrected version.

**No API key. Ever.** McGrammar shells out to the official `claude` binary that you installed and
authenticated yourself. It never sees, stores, or transmits a credential, and it strips
`ANTHROPIC_API_KEY` from the CLI's environment so inference always bills to your subscription
login rather than an API org.

---

## Requirements

- macOS 13 or later
- Xcode command line tools (`xcode-select --install`)
- A **paid** Claude plan (Pro / Max / Team / Enterprise). The free plan does not include Claude Code.
- Claude Code installed and authenticated: `claude login`

## Install

```bash
git clone https://github.com/zernonia/mc-grammar.git
cd mc-grammar
./scripts/local-test.sh   # verify everything before installing
./make-app.sh             # build → ~/Applications/McGrammar.app → launch
```

The menu bar shows `✒︎` when idle, `⋯` while Claude is working, `✒︎!` briefly on an error.

## The two ways to fix text

| | Hotkey | Services menu |
|---|---|---|
| Trigger | ⌃⌥G | select → right-click → Services → **Fix Grammar with McGrammar** |
| Permission | Accessibility required | none |
| Behaviour | copies the selection, pastes the fix back, restores your clipboard | macOS replaces the selection natively |
| Caveat | some apps block synthetic keystrokes | the calling app freezes while Claude thinks |

Both exist on purpose: whichever one a given app blocks, the other usually works.

### Granting Accessibility (hotkey only)

System Settings → Privacy & Security → Accessibility → enable **McGrammar**.

The grant attaches to the *launching* process. If you run the binary straight from a terminal,
macOS asks Terminal for the permission, not McGrammar — always test the hotkey from
`~/Applications/McGrammar.app`.

### If the Services menu item does not appear

macOS caches the Services menu aggressively. This looks like a bug and is not one.

1. `./make-app.sh` already runs `pbs -flush` and `pbs -update`.
2. Enable it: System Settings → Keyboard → Keyboard Shortcuts → Services → Text →
   **Fix Grammar with McGrammar**.
3. Some apps only rebuild their Services menu on launch — restart the app you are testing in.
4. Worst case, log out and back in once.

Services only register from a real `.app` bundle, so `swift run` will never show the menu item.

## Verifying your setup

```bash
./scripts/local-test.sh
```

Checks platform, toolchain, that `claude` resolves through a **login** shell, that no API key is
shadowing your subscription, a real `claude -p` round trip, Info.plist wiring, and then runs the
app's own self-test. You can also run that self-test directly at any time:

```bash
~/Applications/McGrammar.app/Contents/MacOS/McGrammar --selftest
```

And correct text straight from a pipe, no GUI involved:

```bash
echo "this are a sentense with mistake" | \
  ~/Applications/McGrammar.app/Contents/MacOS/McGrammar --fix
```

### Manual smoke test

1. Open Notes, type `this are a sentense with mistake`, select it.
2. Press ⌃⌥G. After a few seconds the text is replaced.
3. Undo (⌘Z), reselect, and try right-click → Services → Fix Grammar with McGrammar.
4. Paste (⌘V) somewhere: your original clipboard should still be there.

## What to expect

- **3–8 seconds per fix.** Each invocation spins up a Claude Code session. This is inherent to the
  approach, not a bug — the menu bar glyph tells you when it is working.
- Headless `claude -p` draws on your subscription's programmatic credit pool, which is capped
  monthly. Fine for grammar fixes; worth knowing if you lean on it hard.
- Inside a Claude Code session, `/status` should show a Login method row and no API key row.

## Privacy

Your text goes to exactly one place: the `claude` process on your machine. McGrammar writes no
logs, keeps no history, and persists nothing of its own to disk. The clipboard is snapshotted in
memory only long enough to restore it after a paste.

One caveat worth stating plainly, because it is not McGrammar's code: the Claude Code CLI keeps a
session transcript of each `claude -p` run — including the text it corrected — under
`~/.claude/projects/<slug of the working directory>/`. Left alone those accumulate, one per fix.

So McGrammar runs the CLI in a directory nothing else uses,
`~/Library/Application Support/McGrammar/cli-workspace`, which isolates those transcripts into
their own project folder, and deletes them after every fix. The cleanup is deliberately narrow:
only `.jsonl` files, only inside a project folder whose name carries McGrammar's marker, and only
ones written during the fix that just ran. If the CLI ever changes where it stores transcripts,
the cleanup finds nothing and does nothing rather than touching anything else.

Verify it yourself — both of these should report zero leftovers:

```bash
./scripts/local-test.sh                                        # step 8
~/Applications/McGrammar.app/Contents/MacOS/McGrammar --selftest
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu says "Claude CLI: not found" | `claude login` in a terminal, then **Re-detect Claude CLI** in the menu |
| Hotkey does nothing | Accessibility not granted to *McGrammar.app*, or another app owns ⌃⌥G (the menu tells you which) |
| Services item missing | see the Services section above |
| "claude exited with code…" | run the same fix with `--fix` from a terminal to see the CLI's own error |
| Fix takes forever, then times out | 60s watchdog fired (SIGTERM, then SIGKILL 5s later); check `claude -p` works in a terminal |
| Transcripts left in `~/.claude/projects` | see Privacy above — report it, the cleanup is meant to leave none |

## Project layout

```
Package.swift             SPM, macOS 13+, no third-party dependencies
Info.plist                LSUIElement + the NSServices declaration
make-app.sh               build → bundle → ad-hoc sign → flush pbs → launch
scripts/local-test.sh     pre-flight verification
CLAUDE.md                 invariants for Claude Code sessions in this repo
HANDOFF.md                original product/research brief
Sources/McGrammar/
  main.swift              entry point, --selftest / --fix CLI modes
  AppDelegate.swift       menu bar, menu state, hotkey path
  ClaudeRunner.swift      the Claude Code bridge (fixSync core + fixAsync wrapper)
  ServiceProvider.swift   NSServices handler
  TextCapture.swift       clipboard snapshot/restore, synthetic ⌘C/⌘V
  HotKey.swift            Carbon RegisterEventHotKey
  StatusIcon.swift        menu bar glyph states
  Toast.swift             permission-free HUD notifications
  Transcripts.swift       isolates and deletes the CLI's session transcripts
  SelfTest.swift          headless checks
```

## Roadmap

1. Diff preview HUD before applying (Tab accept / R regenerate / Esc cancel)
2. Streaming via `--output-format stream-json`
3. Prompt presets (Fix / Polish / Translate / Casual↔Formal) with per-preset hotkeys
4. Opt-in async Services variant that unblocks the calling app
5. Optional direct-API fallback for sub-second fixes
6. Per-app tone profiles; fix-line-at-cursor when nothing is selected; notarized releases

## License

MIT
