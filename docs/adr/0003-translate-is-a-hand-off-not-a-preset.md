# 0003. Translate is a hand-off, not a preset

## Status

Accepted

## Context

The roadmap listed Translate as a future *preset*: a third prompt, sent to the CLI like Polish and
Proofread, with the result pasted over the selection. The user who asked for it (issue #21) wants
the opposite of that shape. They read English in chat clients, editors and mail, and want a
paragraph in Vietnamese *next to* the original — not instead of it. A Claude preset would overwrite
the selection, hide the source, cost money and take seconds, and it is exactly the
register-shifting behaviour the roadmap note already said must never be a default.

The app also carried a privacy guarantee that this feature breaks: "your text never leaves your
machine except through your own Claude Code CLI", stated in the README and in the bundle's
`NSHumanReadableCopyright`. Adding a gesture that sends the selection to Google is the first
exception, and an exception to a guarantee needs to be recorded, not slipped in.

## Decision

**Translate is a hand-off — a new concept in `CONTEXT.md` — not a preset.** ⌃⌥F copies the
selection, restores the clipboard, and opens
`https://translate.google.com/?sl=auto&tl=vi&text=<encoded>&op=translate` in the default browser.
Nothing in the host app changes. The same action is a send-only Services item ("Translate with
McGrammar", `NSSendTypes` only) and a menu bar item.

- `Preset` stays at two cases. `Preset.alternate`, the `allCases`-driven selftest expectations and
  `--fix` parsing assume that, and a hand-off has no prompt or role to carry anyway. A new
  `Translate` type owns the URL builder, the target read and the `NSMessage` string.
- **`translateText` is pinned forever**, like `fixGrammar`: renaming an `NSMessage` unregisters the
  service under every existing install.
- The privacy statement in README and `NSHumanReadableCopyright` now names Google Translate, the
  URL, and browser history.
- The hotkey path takes the busy guard (it writes the general pasteboard) and needs Accessibility;
  the Services path takes neither. No success toast: the browser in front is the signal.

## Measured: what Google actually does with long text

Measured 2026-08-30, macOS 26.5.2, default browser Helium 0.15.7.1 (Chromium), opened via
`NSWorkspace`/`open` with real Vietnamese prose, and confirmed with `curl`:

| Input | URL size | Result |
|---|---|---|
| 5,000 chars Vietnamese prose | 16,340 B | HTTP 200. Page opens, "Vietnamese — Detected", full text, counter reads 5,000. `sl=auto` and `op=translate` behave. |
| 5,024 chars Vietnamese prose | 16,412 B | HTTP 200 |
| 5,025 chars Vietnamese prose | 16,413 B | **HTTP 400** "Error 400 (Bad Request)!!1" |
| 8,000 chars ASCII | 8,062 B | HTTP 200. Page keeps the first 5,000, counter 5,000, banner "To translate text longer than 5,000 characters, copy and paste instead." |
| 16,300 chars ASCII | 16,362 B | HTTP 200 |
| 16,400 chars ASCII | 16,462 B | HTTP 400 |

So there are **two ceilings, not one**, and the plan's assumption — "the page opens anyway and
Google shows a counter" — held for only the first:

1. **5,000 characters** is the text box. Past it the page still opens and Google visibly keeps
   the first 5,000. McGrammar opens the page and shows a non-error toast saying so.
2. **~16,412 bytes of URL** is the server. Past it Google returns 400 and the tab is an error
   page. `NSWorkspace.open` reports success, so the app cannot learn this afterwards; it refuses
   beforehand (`Translate.maxURLBytes = 16_384`) with an error toast. Vietnamese prose reaches this
   at about 5,000 characters; text dense in diacritics (three UTF-8 bytes, nine encoded, per
   letter) reaches it sooner. The grill's "≈45 KB" estimate assumed every character was such a
   letter; real prose is about a third.

McGrammar never truncates in either case. Which part of the text to send is not its call.

## Rejected alternatives

- **A Translate preset through Claude.** Overwrites the selection with the translation, hides the
  source, costs money per use, takes seconds, and depends on the CLI being installed. Everything
  the requester did not want. The roadmap entry is struck.
- **Truncating to 5,000 characters or 16 KB.** Silent choice of which part of the user's text gets
  translated — the same class of failure ADR 0001 records for the prompt placement.
- **`URLComponents.queryItems` / `.urlQueryAllowed` for encoding.** Both leave `+` bare and Google
  decodes it as a space. `.alphanumerics` is Unicode and leaves Vietnamese letters raw, so
  `URL(string:)` returns nil. The encoder spells out the ASCII unreserved set.
- **A generic `HandOff` abstraction.** One hand-off exists.

## Consequences

- The privacy guarantee has one named exception, and it requires a deliberate chord.
- Version 1.1.0 (`CFBundleVersion` 2): a new gesture plus a changed privacy statement.
- `--selftest` gains two pure checks (encoding, URL ceiling) and asserts the send-only shape of
  the Services entry in both directions. `scripts/local-test.sh`'s plist assertions, which had been
  asserting the pre-ADR-0002 entry order and failing, now match the plist.
- ⌃⌥⇧F stays free. A second hand-off would be the moment to reconsider a shared shape.

## References

- Issue #21, `CONTEXT.md` (Hand-off, Translate, Trigger path), ADR 0002.
