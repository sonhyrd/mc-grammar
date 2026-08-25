# McGrammar

A macOS menu bar utility that makes your writing read like a native speaker's, in **any** app —
powered by the Claude Code CLI you already have installed and logged into.

Highlight text anywhere, hit ⌃⌥D (or right-click → Services), and the selection is replaced in
place. Two presets:

- **Polish** (⌃⌥D, the default) — fixes the errors *and* the phrasing: idiomatic word choice,
  articles and prepositions, word order, sentence rhythm. For text that is already grammatical and
  still reads as stilted, which is the thing spellcheck cannot help with.
- **Proofread** (⌃⌥⇧D) — spelling, grammar and punctuation only. Minimum change. Reach for it when
  you want to be certain nothing but a mistake was touched.

Polish never changes what your text says. It may not add, remove or alter a fact, name, number,
quotation or link, and it will not make a tentative claim confident or a confident one tentative —
a guarantee the fixture suite tests on every run, because a rewrite is not something you can check
at a glance the way a spelling fix is.

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

There is no download — you build it on your own Mac, which takes about a minute. That is
deliberate: the app is ad-hoc signed locally, so it never passes through Gatekeeper quarantine and
you can read every line of what you are running.

**1. Check the prerequisites.** This must print corrected text, not an error:

```bash
echo "helo wrold, this are a test" | claude -p "Fix grammar. Output only the corrected text." --max-turns 1
```

If `claude` is not found, install Claude Code and run `claude login` first. If it answers but you
are on the free plan, it will fail — Claude Code needs a paid plan.

**2. Build and install:**

```bash
git clone https://github.com/zernonia/mc-grammar.git
cd mc-grammar
./scripts/local-test.sh   # pre-flight: toolchain, CLI, plist, build, a real fix
./make-app.sh             # build → ~/Applications/McGrammar.app → launch
```

`local-test.sh` should end with `0 failed`. It is worth running: it catches the common setup
problems (no paid plan, an `ANTHROPIC_API_KEY` shadowing your login, `claude` missing from the
login shell's PATH) before you go looking for bugs in the app.

**3. Allow Accessibility when asked.** On first launch macOS shows
"McGrammar would like to control this computer using accessibility features". Click **Open System
Settings** and enable McGrammar. This is only needed for the ⌃⌥D hotkey — see below. Declining is
fine; the Services menu path works without it.

**4. Try it.** Open TextEdit or Notes, type `this are a sentense with mistake`, select it, and
press ⌃⌥D. A few seconds later it is replaced.

The menu bar shows `✒︎` when idle, `⋯` while Claude is working, `✒︎!` briefly on an error. Click it
for **Fix Selected Text** (⌃⌥D), the resolved `claude` path, **Re-detect Claude CLI**, the
Accessibility state, **Open Services Settings…**, and Quit.

### Updating

```bash
git pull && ./make-app.sh
```

Your Accessibility grant survives rebuilds: the bundle pins its designated requirement to the
bundle identifier rather than to the binary's hash.

### Uninstalling

```bash
rm -rf ~/Applications/McGrammar.app
rm -rf "$HOME/Library/Application Support/McGrammar"
rm -rf ~/.claude/projects/*McGrammar-cli-workspace   # the CLI's (already emptied) project folder
defaults delete com.zernonia.mcgrammar 2>/dev/null
tccutil reset Accessibility com.zernonia.mcgrammar
```

Quit the app from the menu bar first. The third line removes the folder the Claude Code CLI made
for McGrammar's working directory — the transcripts inside were deleted as each fix finished, but
the empty folder itself stays behind.

## The two ways to fix text

| | Hotkey | Services menu |
|---|---|---|
| Trigger | ⌃⌥D (Polish), ⌃⌥⇧D (Proofread) | select → right-click → Services → **Polish with McGrammar** or **Proofread with McGrammar** |
| Permission | Accessibility required | none |
| Behaviour | copies the selection, pastes the fix back, restores your clipboard | macOS replaces the selection natively |
| Confirmation | McGrammar posts the ⌘V itself, so the toast means the paste was delivered | McGrammar hands the text back and macOS replaces the selection afterwards, with no callback — the toast means the text was returned, not that the replacement landed |
| Caveat | some apps block synthetic keystrokes | the calling app freezes while Claude thinks |

Both exist on purpose: whichever one a given app blocks, the other usually works.

The Services item also gets a system shortcut, **⌘⌃⇧G**, remappable under System Settings →
Keyboard → Keyboard Shortcuts → Services.

### Where each path works

Because the service declares a return type, macOS only offers it where it can replace what you
selected — so it appears for **editable** text (a document, a text field, a compose window) and
not for read-only text such as an article body or a PDF.

**Chrome, and Electron apps generally, do not show Services in their right-click menu.** Those
menus are drawn by the app itself rather than by macOS, and they simply leave Services out. It is
not a McGrammar bug and nothing in the app can change it. In Chrome, use ⌃⌥D or ⌃⌥⇧D, or reach the same
services from the menu bar via **Chrome → Services**. This is exactly why both paths exist.

### Granting Accessibility (hotkey only)

The first launch of a newly installed bundle asks for it: macOS shows a
"McGrammar would like to control this computer using accessibility features" dialog with an
**Open System Settings** button. Declining is harmless — the Services path never needs the
permission, and the menu bar dropdown keeps an "Accessibility: not granted" item that re-opens
the pane whenever you want it.

To grant it by hand: System Settings → Privacy & Security → Accessibility → enable **McGrammar**.

McGrammar asks once per installed build — reinstalling re-arms the prompt. macOS itself, though,
shows its dialog at most once per app identity, so if you have dismissed it before you may only
get the settings pane rather than a new prompt.

The grant attaches to the *launching* process. If you run the binary straight from a terminal,
macOS asks Terminal for the permission, not McGrammar — always test the hotkey from
`~/Applications/McGrammar.app`.

**If McGrammar keeps asking although the checkbox is already ticked**, the listed entry is stale.
macOS matches the grant against the bundle's designated requirement, and a bundle signed before
this was pinned to an exact `cdhash`, so any rebuild invalidated it while leaving the ticked entry
behind. Remove **McGrammar** from the Accessibility list with the **−** button, then relaunch and
allow it once. Bundles built by the current `make-app.sh` pin the requirement to the bundle
identifier instead, so the grant now survives rebuilds.

### If the Services menu item does not appear

macOS caches the Services menu aggressively. This looks like a bug and is not one.

1. `./make-app.sh` already runs `pbs -flush` and `pbs -update`.
2. Enable them: System Settings → Keyboard → Keyboard Shortcuts → Services → Text →
   **Polish with McGrammar** and **Proofread with McGrammar**.
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

1. Open Notes, type `We would like to make a discussion about the issue.`, select it.
2. Press ⌃⌥D. After a few seconds it is replaced, and a toast says **Polished**.
3. Undo (⌘Z), reselect, press ⌃⌥⇧D: Proofread leaves the phrasing alone.
4. Undo, reselect, and try right-click → Services → Polish with McGrammar.
5. Paste (⌘V) somewhere: your original clipboard should still be there.

## What to expect

- **3–8 seconds per fix.** Each invocation spins up a Claude Code session. This is inherent to the
  approach, not a bug — the menu bar glyph tells you when it is working.
- Headless `claude -p` draws on your subscription's programmatic credit pool, which is capped
  monthly. Fine for everyday fixes; worth knowing if you lean on it hard.
- Inside a Claude Code session, `/status` should show a Login method row and no API key row.

## Privacy

Your text goes to exactly one place: the `claude` process on your machine. McGrammar writes no
logs, keeps no history, and persists nothing of its own to disk. The clipboard is snapshotted in
memory only long enough to restore it after a paste.

One limit of that restore, stated plainly: *promised* clipboard flavours cannot be put back. Some
apps advertise a type on the pasteboard and only render it when a receiver asks — file promises,
certain app-private formats. There is nothing for a snapshot to copy, so those flavours are lost
when the hotkey path restores your clipboard. Ordinary text, RTF, HTML and images round-trip
intact, in their original preference order. The Services path never touches your clipboard at all.

One caveat worth stating plainly, because it is not McGrammar's code: the Claude Code CLI keeps a
session transcript of each `claude -p` run — including the text it corrected — under
`~/.claude/projects/<slug of the working directory>/`. Left alone those accumulate, one per fix.

So McGrammar runs the CLI in a directory nothing else uses,
`~/Library/Application Support/McGrammar/cli-workspace`, which isolates those transcripts into
their own project folder, and deletes every one of them after every fix.

The cleanup is deliberately narrow: `.jsonl` files only, and only inside a project folder whose
name carries McGrammar's marker — a folder that exists only because McGrammar created the working
directory it is named after. If the CLI ever changes where it stores transcripts, the cleanup
finds nothing and does nothing rather than touching anything else.

It sweeps the whole folder rather than only the fix that just ran. Anything left behind by an
interrupted run — the app quit mid-fix, a delete that failed once — is collected by the next fix
instead of sitting there for good. And if the private workspace cannot be created at all,
McGrammar falls back to a temp directory that still carries the marker; if that fails too, the fix
returns an error rather than running the CLI somewhere it cannot clean up afterwards.

Verify it yourself — both of these should report zero leftovers:

```bash
./scripts/local-test.sh                                        # step 8
~/Applications/McGrammar.app/Contents/MacOS/McGrammar --selftest
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu says "Claude CLI: not found" | `claude login` in a terminal, then **Re-detect Claude CLI** in the menu |
| Hotkey does nothing | Accessibility not granted to *McGrammar.app*, or another app owns ⌃⌥D (the menu tells you which) |
| Services item missing | see the Services section above |
| No Services item in Chrome / Slack / VS Code | expected — those draw their own menus. Use ⌃⌥D, or the app's own **menu bar → Services** |
| Item missing on read-only text | expected — it only appears where the selection is editable |
| Accessibility keeps prompting although the box is ticked | the listed entry is stale. `tccutil reset Accessibility com.zernonia.mcgrammar`, then relaunch and allow once |
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
  main.swift              entry point, --selftest / --fix / --help CLI modes
  AppDelegate.swift       menu bar, menu state, hotkey path
  ClaudeRunner.swift      the Claude Code bridge (fixSync core + fixAsync wrapper)
  ServiceProvider.swift   NSServices handler
  TextCapture.swift       clipboard snapshot/restore, synthetic ⌘C/⌘V
  HotKey.swift            Carbon RegisterEventHotKey
  StatusIcon.swift        menu bar glyph states
  Toast.swift             permission-free HUD notifications
  Transcripts.swift       isolates and deletes the CLI's session transcripts
  SelfTest.swift          headless checks
  CommandLineFix.swift    the --fix stdin filter
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
