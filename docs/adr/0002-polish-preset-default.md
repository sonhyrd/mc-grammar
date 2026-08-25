# 0002. A Polish preset, made the default, with a factual-integrity guarantee

## Status

Accepted

## Context

McGrammar corrected grammar, spelling and punctuation. For its actual user — a fluent non-native
speaker of English — that fixes the wrong problem. Their text is usually already grammatically
correct and still reads as stilted.

The gap is not a matter of degree, and it is not something a correction prompt reaches by being
loosened. Choosing which of several grammatical paraphrases a native writer would actually use is a
separate competence from grammar: what the applied-linguistics literature calls nativelike
selection, and what corpus linguistics describes as the idiom principle — that fluent language is
largely assembled from semi-preconstructed phrases rather than from free slot-filling. A prompt told
to fix errors and change nothing else is *correct* to leave "we would like to make a discussion
about the issue" alone. There is no error in it.

So the fluency pass had to be a second preset rather than a relaxed first one, and `ClaudeRunner`'s
own comment — "loosening this makes Claude rewrite instead of correct" — is the reason why: that
strictness is load-bearing for correction and incompatible with fluency in the same prompt.

## Decision

**Two presets. `Proofread` is the shipped correction prompt, byte for byte. `Polish` is new, and is
the default.** The names are the copy desk's own: proofreading is the final surface pass,
copy-editing is the style pass. "Fix" is deliberately not a preset name — it is the operation the
app performs (`fixSync`, `FixError`, `--fix`, the pinned `fixGrammar` selector), and spending it on
one preset would overload a word this codebase already relies on.

Both presets carry their rules in `-p` and a one-line role in `--system-prompt`. **ADR 0001's
prompt-placement finding is not reopened**, and the Polish prompt was written into `-p` from the
start because of it.

### Polish's prompt shape

Two things about it are deliberate.

It **enumerates the levels it may operate on** — collocation, article and preposition idiom,
information order, verb over abstract noun, sentence rhythm — rather than asking for natural-sounding
text. "Make this sound natural" gives the model no way to distinguish an improvement it was asked
for from one it was not, and that is the instruction that produces over-rewriting. It likewise
enumerates what is held fixed: register, voice, claim strength, and length to within about a tenth.

**`factualIntegrity` is stated ahead of every other instruction, with its reason attached.**
It is first because it is the one guarantee the user cannot check for themselves. A grammar
correction is verifiable at a glance; a fluency rewrite is not, because the whole point is that it
reads better than what they wrote. A fact quietly altered here survives into whatever they send
next.

### The pin

ADR 0001 pinned `claude-haiku-4-5-20251001` on a real result: byte-identical output to Opus on a
hard **correction** paragraph. That evidence does not transfer to Polish. Idiomatic selection is
precisely where model capability stops being interchangeable, and its failures are invisible — the
output is fluent, just not the choice a native writer would make — so no existing fixture could have
caught a shortfall.

Two things were separated here, and only one was inherited:

- **The discipline is binding.** Pin by dated identifier, never a floating alias. An alias is what
  silently moved this app to Opus. This holds regardless of which model is pinned.
- **The identifier was an open question**, to be settled by fixtures rather than by inheritance.

**Result: 21/21 in 59.7s on `claude-haiku-4-5-20251001`.** The original fifteen correction cases
still pass, which is what proves the preset split disturbed nothing, and all six new Polish cases
pass. The pin stands unchanged.

**What that does and does not establish.** It establishes that Haiku removes the specific stilted
constructions the fixtures name, preserves planted facts through a rewrite, and leaves a fenced
block intact. It does **not** establish that Haiku produces the *best* idiom available — the suite
asserts removal, so a larger model and Haiku can both pass while differing in quality. If Polish
output ever reads as flat rather than wrong, that is the hypothesis to test, and the test is a
model comparison on these fixtures, not a prompt change.

### Fixture design: assert removal, not replacement

Idiom cases forbid the stilted phrasing from the input and require nothing about the wording that
replaces it. `required` carries planted facts only.

This is the load-bearing detail of the whole suite. A fixture that required a particular replacement
would assert one right answer where many exist, and would go red on a perfectly good rewrite. A
suite that fails on good output gets ignored, and an ignored suite is strictly worse than no suite,
because it still reads as protection.

### Signals

Every successful fix toasts, naming the preset, for two seconds against the error toast's five.
Silence cannot be the signal: it would be ambiguous between the other preset running, the gesture
never firing, and the app not running.

**The two trigger paths know different things and say different things.** The hotkey path posts the
⌘V itself, so it reports whether the keystroke was delivered and toasts only then — the Accessibility
grant can be revoked while the CLI call is in flight. The Services path writes to the return
pasteboard and returns; macOS performs the replacement afterwards with no callback, so its toast
says the text was returned to the app and claims nothing about the replacement. This asymmetry is
recorded in `CLAUDE.md` and in the README's trigger table, which is the only place a user sees which
path they are on.

## Rejected alternatives

- **A `Formal` (register-shifting) preset.** It is the one preset licensed to change what the text
  says about itself, and nothing asked for it. It would have cost a trigger surface and a fixture
  for a gesture that may never be pressed.
- **Few-shot examples in the prompts.** Anthropic's own guidance requires examples to be *diverse*.
  The input distribution here is unbounded — Slack messages, commit messages, emails, docs, code
  comments, any domain — so three to five examples cannot span it, and non-diverse examples pull
  every input toward their own register. That is the voice-flattening failure the prompt is written
  to avoid, reintroduced by the mitigation. A *user-specific* example set learned from accepted
  corrections would be genuinely good, and collides head-on with the never-persist guarantee.
- **`--safe-mode` in place of `--setting-sources ""` / `--strict-mcp-config`.** Verified not to
  alter credential resolution and to honour the configured model — but verified *safe*, never
  measured *better*. It reaches roughly $0.002 per fix against the shipped ~$0.0003, and is less
  surgical. Safety is not superiority. Recorded here so it is not re-proposed on the strength of
  the safety finding alone.
- **A sticky "default preset" toggle** instead of a second hotkey and a second Services entry. A
  hidden mode that changes what gets pasted irreversibly over a selection, with no feedback at the
  moment of the gesture, is the worst available design for this app.
- **Restoring `sanitize()`** now that Polish sees richer selections. It cuts the other way: a
  likelier fenced selection argues for never stripping, which is what deletion already gives. The
  residual risk is Polish *emitting* a fence the input lacked, and the control for that is a
  fixture, not a string heuristic. See `CLAUDE.md` for the corrected justification — the recorded
  reason had been shell safety, which `sanitize()` never had anything to do with.

## Consequences

- Any change to `Preset.prompt` or `Preset.role` must re-run `McGrammar --fixtures` before merging,
  now 21 cases and ~60s of billed calls. `--selftest`'s samples would not catch a prompt regression.
- Polish's guarantee is only as good as `polish-factual-integrity`. If that case is ever weakened or
  removed, the guarantee in the README is no longer backed by anything.
- The default is one line, `Preset.standard`. Changing it again requires bumping
  `AppDelegate.defaultPresetNoticeGeneration` so existing users are told, exactly as they were here.
- ADR 0001 names the prompts `ClaudeRunner.prompt` / `ClaudeRunner.systemPrompt`. They now live on
  `Preset`. The decision ADR 0001 records is unchanged; only the symbols moved.

## References

- Issue #11 (spec) and tickets #12–#19.
- `docs/adr/0001-isolate-the-claude-code-invocation.md` — the invocation this builds on, and the
  prompt-placement finding that shaped Polish's prompt.
- `docs/research/prompt-fluency-polish.md` — the research note, including a headline recommendation
  ADR 0001 refutes; see its correction header.
- `Sources/McGrammar/Preset.swift`, `Sources/McGrammar/Fixtures.swift`.
