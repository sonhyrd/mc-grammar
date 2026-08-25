# McGrammar — Project Handoff Document

> **Purpose of this doc:** Complete context for building a macOS grammar-fixing utility powered by the user's local Claude Code CLI. Written to seed a fresh repo — drop this in as `HANDOFF.md` (or split into `README.md` + `CLAUDE.md`) and start building with Claude Code. Everything below was validated through research; gotchas listed were discovered the hard way, so treat them as constraints, not suggestions.

> **Status:** implemented. The product shipped as **McGrammar**; this document is kept as the
> original brief. Two deviations from §3: the sources are split into focused files under
> `Sources/McGrammar/` instead of one `main.swift`, and user-facing messages use an in-app HUD
> panel rather than `UNUserNotificationCenter` (no authorization prompt, reliable for ad-hoc
> signed bundles). See `README.md` and `CLAUDE.md` for the as-built description.

---

## 1. Product Vision

A lightweight macOS menu bar app: the user highlights text in **any** application, triggers a fix (hotkey or right-click menu), and the highlighted text is replaced in place with a grammar/spelling/punctuation-corrected version.

**The defining constraint:** corrections run through the user's **locally installed, locally authenticated Claude Code CLI** (`claude -p`) — **never** an Anthropic API key. The user's Claude Pro/Max subscription pays for inference; the app never touches credentials, tokens, or auth of any kind.

Inspiration: [GhostEdit](https://github.com/nareshnavinash/GhostEdit-mac-app) (open-source, similar concept, supports AI CLIs). We're building our own because of GhostEdit installation issues and to have full control. Borrow its good ideas: streaming diff preview HUD, accept/regenerate/cancel keys, undo, fix-line-at-cursor when nothing is selected.

---

## 2. Feasibility & Compliance (settled questions — don't re-litigate)

### 2.1 No API key needed — confirmed
- Claude Code works on Pro/Max/Team/Enterprise subscriptions via `claude login` (browser OAuth). Credentials persist in the keychain. Headless `claude -p "..."` uses the stored subscription login by default.
- An API key is only used if `ANTHROPIC_API_KEY` is set in the environment — and **it takes precedence over the subscription login**. The app's docs must tell users to verify with `/status` (should show a Login method row, no API key row) and to keep the env var out of the app's process environment.
- Free Claude plan does NOT include Claude Code. Paid plan is a hard requirement.

### 2.2 Terms-of-service position — the line we stay behind
- **Allowed:** invoking the real, official `claude` binary that the user installed and authenticated themselves. GUI wrappers around the official binary that never touch credentials have been treated as compliant.
- **Banned:** extracting/using OAuth tokens in any other client, offering Claude.ai login inside a third-party app, routing requests through Free/Pro/Max plans on behalf of others. Anthropic's official guidance says third-party products should use API keys — our app sidesteps this by being a local utility where each user brings their own CLI.
- **If ever commercialized:** the safe structure is selling the *software* (one-time payment), with each customer using their own subscription + binary. Before charging money: (a) re-read code.claude.com/docs/en/legal-and-compliance (policy flip-flopped twice in 2026), (b) email Anthropic for a written OK, (c) ship an optional API-key mode as a policy-change hedge.

### 2.3 Usage limits reality
- Headless `claude -p` draws from the subscription's programmatic/Agent-SDK credit pool (capped monthly on Pro/Max, e.g. ~$20-equivalent on Pro as of mid-2026; pay-as-you-go beyond). Fine for personal grammar fixes; document it so users aren't surprised.
- Each invocation spins up a CC session: expect **3–8 seconds per fix**. This is inherent, not a bug. Design UX around it (spinner states, streaming preview later).

---

## 3. Architecture

**Stack:** Swift + AppKit, Swift Package Manager (no Xcode project needed), zero third-party dependencies. Single executable target wrapped into a `.app` bundle by a build script.

**Components:**

```
McGrammar/
├── Package.swift              # SPM, macOS 13+, executable target
├── Info.plist                 # LSUIElement=true, NSServices declaration
├── make-app.sh                # build → assemble .app → codesign → register services → launch
├── CLAUDE.md                  # project context + invariants for Claude Code sessions
└── Sources/McGrammar/
    └── main.swift             # AppDelegate, hotkey, keyboard sim, ClaudeRunner, ServiceProvider
```

### 3.1 Two independent trigger paths (build both)

| | Path A: Global hotkey | Path B: Right-click context menu |
|---|---|---|
| Trigger | ⌃⌥D (Carbon `RegisterEventHotKey`) | Selection → right-click → Services → "Fix Grammar with McGrammar" |
| Capture | Simulate ⌘C via `CGEvent`, read `NSPasteboard` after ~250ms | macOS hands text on a pasteboard (`NSServices` with `NSSendTypes`) |
| Replace | Write result to pasteboard, simulate ⌘V, restore original clipboard ~600ms later | Write result back to the same pasteboard before the handler returns — macOS replaces the selection **natively** because `NSReturnTypes` is declared |
| Permissions | **Requires Accessibility** (System Settings → Privacy & Security). Permission attaches to the *launching* process (Terminal vs the .app) — document this | **No Accessibility needed** — the cleaner path |
| Caveat | Some apps block synthetic keystrokes | Calling app blocks while Claude thinks (synchronous by design); services only register from a real `.app` bundle |

### 3.2 ClaudeRunner (the CC bridge)

- **Binary discovery:** resolve `claude` via a **zsh login shell** (`/bin/zsh -l -c 'command -v claude'`) at startup and cache the path. GUI-launched apps don't inherit terminal PATH — this is the #1 silent failure mode. Additionally prepend common install dirs to the child PATH: `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, `/usr/local/bin`. Show the resolved path (or a warning) in the menu bar dropdown.
- **Invocation:** `claude -p "<PROMPT>" --max-turns 1`, selected text piped via **stdin** (never shell-interpolated — avoids escaping/injection issues). 60s process timeout watchdog; terminate if exceeded.
- **Prompt (tuned, keep strict):**
  > Fix the grammar, spelling, and punctuation of the text provided via stdin. Preserve the author's voice, tone, formatting, and line breaks. Do NOT rewrite or rephrase beyond what is needed for correctness. Output ONLY the corrected text. No preamble, no quotes, no explanations, no markdown fences.
- **Output hygiene:** trim whitespace. If preamble ever leaks ("Here is the corrected…"), switch to `--output-format json` and parse the `result` field instead of tightening the prompt further.
- **Sync/async structure — CRITICAL INVARIANT:** implement a **synchronous core** (`fixSync`, blocks calling thread) and an async wrapper for the hotkey path (background queue → completion on main). The Services handler MUST call the sync core directly. Do **not** wrap the async path with a semaphore for the services handler: the handler runs on the main thread and the async completion dispatches to main → **guaranteed deadlock**. This mistake was made once already; CLAUDE.md must forbid it.

### 3.3 NSServices declaration (Info.plist) — the fiddly bits

- `NSMessage` must exactly equal the `@objc` selector name on `NSApp.servicesProvider` (e.g. `fixGrammar` ↔ `func fixGrammar(_:userData:error:)`).
- `NSSendTypes` + `NSReturnTypes` both `NSStringPboardType` — **removing NSReturnTypes turns it send-only and selection replacement stops.**
- `NSTimeout` = `120000` (ms). Default service timeout is far too short for CC spin-up.
- Optional `NSKeyEquivalent` gives a system-managed shortcut (user-remappable in System Settings → Keyboard → Keyboard Shortcuts → Services).
- Register in code: `NSApp.servicesProvider = provider; NSUpdateDynamicServices()`.
- **macOS caches the Services menu aggressively.** Build script should run `/System/Library/CoreServices/pbs -flush` / `-update`; users may still need to tick the item in System Settings or log out/in once. Document this prominently — it looks like a bug but isn't.

### 3.4 App bundle & signing

- `LSUIElement = true` (menu bar only, no Dock icon); `NSApp.setActivationPolicy(.accessory)`.
- `make-app.sh`: `swift build -c release` → assemble `~/Applications/McGrammar.app/Contents/{MacOS,Info.plist}` → `codesign --force --sign -` (ad-hoc, so TCC/Accessibility grants survive rebuilds) → flush pbs → `open`.
- Kill any running instance before replacing the binary.

---

## 4. UX Details

- Menu bar icon states: idle `✒︎`, working `⋯`, error `✒︎!` (revert after ~3s).
- Menu contents: "Fix Selected Text (⌃⌥D)", resolved claude path / not-found warning, Quit.
- Notifications for: no selection, claude not found, fix failed (include first ~300 chars of stderr).
- Empty/whitespace-only selection → friendly notification, restore clipboard, bail.
- Never log or persist user text anywhere. State it in the README as a privacy guarantee.

## 5. First-run / verification checklist (put in README)

1. Paid Claude plan + `claude login` done.
2. Terminal sanity check: `echo "helo wrold, this are a test" | claude -p "Fix grammar. Output only the corrected text." --max-turns 1`
3. Inside a CC session, `/status` shows Login method (not API key). No `ANTHROPIC_API_KEY` exported in shell profiles.
4. One-time billing sanity check: after a test `-p` run, confirm nothing appears on the Console/platform billing dashboard (known edge case for accounts also linked to an API org).
5. `./make-app.sh`, grant Accessibility for the hotkey path, tick the Service if the menu item is hidden.
6. Test in Notes: select `this are a sentense with mistake` → both paths.

## 6. Roadmap (post-v1, in priority order)

1. **Diff preview HUD** before applying (GhostEdit-style): floating panel, Tab=accept, R=regenerate, Esc=cancel. Biggest UX win over blind replacement.
2. **Streaming** via `--output-format stream-json` for perceived speed.
3. **Prompt presets** (Fix / Polish / Translate / Casual↔Formal) — settings window, per-preset hotkeys.
4. **Async services variant**: service returns immediately, app pastes when done (unblocks the calling app; costs the Accessibility requirement — make it opt-in).
5. **Fallback provider toggle**: direct Anthropic API (Haiku) for sub-second fixes, for users who prefer speed over subscription billing — also the ToS hedge.
6. Per-app tone profiles; fix-line-at-cursor when nothing selected; proper release packaging (notarization) if ever distributed.

## 7. Known risks & watch items

- **Policy volatility:** Anthropic's stance on third-party subscription usage changed twice in 2026. Re-check before any distribution.
- **Agent SDK credit caps** may change; heavy users could hit monthly programmatic limits.
- **CC CLI flags** (`-p`, `--max-turns`, `--output-format`) are stable today but verify against current docs when upgrading; `--bare` mode must never be used (API-key only).
- Some Electron/sandboxed apps don't expose Services or block synthetic keys — hotkey path is the fallback for the former, services path for the latter; having both is the mitigation.

## 8. Suggested first Claude Code prompt for the new repo

> Read HANDOFF.md fully. Scaffold the project exactly as described in §3: Package.swift (macOS 13+, SPM executable), Info.plist per §3.3, make-app.sh per §3.4, and main.swift implementing both trigger paths per §3.1–3.2. Respect every invariant marked CRITICAL. Then generate a CLAUDE.md containing the invariants from §3.2/§3.3 and the roadmap from §6. Do not add third-party dependencies.
