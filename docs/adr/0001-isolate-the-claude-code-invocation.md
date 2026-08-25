# 0001. Isolate the Claude Code invocation

## Status

Accepted

## Context

McGrammar shells out to the user's locally installed, locally authenticated `claude` CLI to
correct selected text (see root `CLAUDE.md` — credentials invariant). The original invocation
inherited the user's normal Claude Code configuration: whatever settings files, MCP servers,
tool permissions, and system prompt applied to their everyday interactive sessions applied here
too.

That is expensive and slow for what this app actually needs, which is a single deterministic
text transform with no tools, no MCP, and no multi-turn reasoning:

- **Cost.** The inherited invocation ran on whatever model the user's config pointed at — Opus 5
  in the measured case — with the full interactive system prompt and no bound on input tokens
  arising from project context, CLAUDE.md files, and enabled MCP tool schemas. Measured at
  ~30,000 input tokens and **$0.1497 per fix**.
- **Latency.** 5.51s / 6.59s / 9.47s wall clock across three runs, one machine, same input,
  `/usr/bin/time`.
- **Blast radius.** Whatever tools and MCP servers were enabled in the user's normal config were
  available to a process invoked by a background macOS utility, for a task that needs none of
  them.

We isolated the invocation instead: pin a model, drop the user's settings and tool config
entirely, replace the interactive system prompt with a one-line role, and cap the turn count.

## Decision

`ClaudeRunner.fixSync` invokes `claude` with this exact flag set (see `Sources/McGrammar/ClaudeRunner.swift`):

```
-p <prompt>
--max-turns 1
--model claude-haiku-4-5-20251001
--setting-sources ""
--tools ""
--strict-mcp-config
--system-prompt <role line>
--output-format json
```

plus `MAX_THINKING_TOKENS=0` in the child environment, and `ANTHROPIC_API_KEY` /
`ANTHROPIC_AUTH_TOKEN` stripped (credentials invariant, unrelated to isolation but same code
path).

Each flag is load-bearing:

- `--model claude-haiku-4-5-20251001` — a **dated** identifier, never a floating alias. An alias
  is what silently put the app on Opus in the first place: the user's config resolved a
  general-purpose alias to whatever model that alias currently means, at Opus pricing and
  latency, invisibly. A stale dated ID is a visible maintenance task (the CLI rejects it
  outright — see `FixError.rejectedInvocation`); a silently-upgraded alias is not.
- `--setting-sources ""` and `--tools ""` — refuse the user's settings files and tool
  permissions entirely rather than trying to guess which subset is safe. See "Rejected:
  `--settings`" below for why merging was not an option.
- `--strict-mcp-config` — refuse any MCP servers from ambient config; this invocation carries no
  MCP config of its own, so the effective set is empty.
- `--max-turns 1` — this is a single text transform, not an agentic task. One turn also bounds
  the worst case for the watchdog.
- `--system-prompt <role line>` — replaces the ~3,300-token interactive agent preamble (git
  status, tool discipline, output style) with one line: `"You are a grammar corrector. Output
  only corrected text."` None of the interactive preamble applies to this task.
- `--output-format json` — read the `result` field programmatically instead of parsing raw
  stdout, and get `modelUsage` (actual model served, not just the one requested) and thinking
  token counts for the self-test tripwire.
- `MAX_THINKING_TOKENS=0` — see "Measurements" below; this alone is roughly half the latency
  floor's headroom above pure process startup. Undocumented CLI env var, not a flag, so weaker
  than the rest of this list — `SelfTest` asserts `thinkingTokens == 0` on every run specifically
  to catch a future CLI that silently stops honoring it.

**Prompt placement is also part of this decision, and is the most important part** — see
"Finding: prompt placement" below. The correction rules live in `-p`, not in `--system-prompt`.

## Measurements

One machine, Claude Code 2.1.245, three runs each, wall clock via `/usr/bin/time`.

| Invocation | Wall clock (3 runs) | Cost / fix |
|---|---|---|
| Old, inherited config (Opus 5, ~30,000 input tokens) | 5.51s / 6.59s / 9.47s | $0.1497 |
| New, isolated (Haiku 4.5, thinking off, ~290 input tokens) | 2.24s / 2.31s / 2.26s | $0.0003 |
| New, end to end through `McGrammar --fix` | 2.40s / 2.80s / 2.44s | — |

Roughly a **2.6x wall-clock speedup** and a **~500x cost reduction**.

Model comparison, all with thinking disabled (CLI-internal `duration_ms`, **not** wall clock —
see the correction below for why that distinction matters):

| Model | Short input | Hard paragraph | Cost |
|---|---|---|---|
| Haiku 4.5 | 0.84s | 1.48s | $0.0007 |
| Sonnet 5 | 1.65s | 2.14s | $0.0031 |
| Opus 5 | 1.57s | 2.02s | $0.0060 |

Accuracy: on a deliberately nasty paragraph, Haiku's output was byte-identical to Opus's; Sonnet
differed by one optional comma. Haiku 4.5 was chosen on this basis — cheapest and fastest of the
three, with no accuracy loss on the one case that could plausibly show one, and the pinned model
now backing the `--fixtures` suite (`Sources/McGrammar/Fixtures.swift`, 15 cases).

### Correction: the first latency numbers were wrong

The model-comparison table above (`duration_ms` from `--output-format json`) is the CLI's
**internal request time**. It excludes the node runtime's boot and teardown, which dominates
wall clock and does not shrink with model choice, prompt size, or thinking tokens. It is a valid
way to compare models against each other; it is not a wall-clock latency figure, and was
originally reported as one.

Re-measured end to end with `/usr/bin/time` under the isolated invocation: 2.24s / 2.31s / 2.26s,
not the ~0.84s the `duration_ms` figure implied. **The floor is CLI process startup — roughly
1.4s of the ~2.25s — not inference.** No further prompt or context reduction moves this number;
the isolation work above already removed everything that could.

Two consequences, both recorded so nobody re-derives them the hard way:

- The "under 1.5s" acceptance criterion on the original invocation ticket was unmeetable given
  that floor. The implementation was correct; the criterion was wrong, and was retracted rather
  than chased.
- `StatusIcon.elapsedCounterThreshold` moved from 3s to 5s. 3s was chosen against the wrong
  ~0.84s baseline and would fire on *ordinary* fixes at the real ~2.4–2.8s baseline — exactly
  the visual noise the delay exists to suppress. 5s clears a long paragraph with headroom and
  still appears well before the 10s Services / 15s hotkey watchdog timeouts.

**This is precisely the mistake the next person benchmarking this invocation will make** if they
reach for `duration_ms` as a wall-clock number. Measure end to end, with a wall clock, through
the actual child process McGrammar spawns — not the CLI's self-reported internal timing.

### Finding: prompt placement (discovered late, most surprising result)

Moving the correction rules out of `-p` and into `--system-prompt` — leaving `-p` as a bare
pointer like `"Fix the grammar in the text on stdin."` — reads tidier, and on a short input it
measures identically to keeping the rules in `-p`. On a long, multi-error paragraph it silently
fails roughly half the time:

| Rules location | Hard-fixture accuracy |
|---|---|
| `--system-prompt` | 7/15 correct |
| `-p` (current) | 14/14 correct |

The failures are silent, which is what makes this dangerous rather than merely annoying: usually
the user's text comes back **completely unchanged** (a no-op that looks like "nothing needed
fixing"), occasionally the model returns a list of corrections instead of corrected text (e.g.
`their → they're`) — and that list, not the corrected text, is what gets pasted over the user's
selection. There is no error, no non-zero exit, nothing for `fixSync`'s error handling to catch.
It was caught by `Sources/McGrammar/Fixtures.swift` (`McGrammar --fixtures`) on its first real
run against a hard multi-error case — a single easy fixture would not have shown the gap.

**This is the single most "helpful" refactor a future contributor could make to this code**, and
it must not be made again without re-running `--fixtures` against the change. The correction
rules stay in `-p`. `--system-prompt` stays a one-line role only. See the comment on
`ClaudeRunner.prompt`.

## Rejected alternatives

- **`--settings <empty-file>`.** `--settings` *merges* into the resolved configuration rather
  than replacing it; pointing it at an empty or minimal file does not suppress the user's other
  active settings sources (global, project, local). It cannot produce the "nothing but what we
  pass" invocation this app needs. `--setting-sources ""` does — it disables sourcing settings
  files at all, rather than trying to merge one into irrelevance.
- **Prompt caching.** Anthropic's minimum cacheable prefix is 2,048 tokens. The isolated
  invocation's prompt prefix is ~250 tokens — under the floor, so nothing is eligible to cache,
  and prefilling ~250 tokens is already free regardless. The *old* inherited invocation only
  looked fast on repeated runs because it had ~30,000 tokens of stable prefix to warm; that was
  never a property worth preserving; it was a symptom of the bloat this ADR removes.
  Caching is not a lever available to (or needed by) the isolated invocation.
- **Capability probing at discovery time** (spawn `claude --help` or similar to detect which
  flags an installed CLI version supports, then build the argument list conditionally). Adds a
  process spawn to the fast path for every fix, defeating the latency work this ADR is about, to
  guard against a CLI version skew that `FixError.rejectedInvocation`'s stderr-pattern matching
  already surfaces as an actionable error (`claude update`) after the fact, without a tax on
  every successful run.
- **Graceful degradation** (catch a rejected flag and retry without it). Silently reintroduces
  exactly the failure mode this ADR exists to prevent: drop `--setting-sources`/`--tools` and the
  invocation is back to ~30,000 input tokens and $0.1497/fix, invisibly, on whatever machine
  happens to have an older CLI. `.rejectedInvocation` is deliberately a hard failure with a
  message telling the user to update, not a fallback path.

## Consequences

- A pinned dated model (`ClaudeRunner.model`) is a recurring maintenance cost: it will age out of
  the CLI's supported set and needs bumping, verified against `--fixtures` before shipping. This
  is accepted as strictly better than a floating alias silently drifting cost and latency.
- The ~1.4s of the ~2.25s floor is CLI process startup and is out of this app's control short of
  a different provider path entirely (see root `CLAUDE.md` roadmap item 5, "Fallback provider
  toggle" — direct API, no CLI process, is the only way to move this floor).
- Any future change to `ClaudeRunner.prompt`, `ClaudeRunner.systemPrompt`, or the flag list must
  re-run `McGrammar --fixtures` (15 cases, ~40s, costs money) before merging — not just
  `--selftest`, which uses one easy sample and would not have caught the prompt-placement
  regression above.

## References

- Issue #1 (spec) and its correction comment (wall-clock re-measurement).
- Issue #9 (this ADR's ticket) and its comment (authoritative figures to use here).
- Issue #7 (elapsed-counter threshold, 3s → 5s, same root cause).
- `Sources/McGrammar/ClaudeRunner.swift` — `prompt`, `systemPrompt`, `fixSync` argument list.
- `Sources/McGrammar/Fixtures.swift` — the accuracy suite that caught the prompt-placement
  regression.
- `Sources/McGrammar/SelfTest.swift` — the `MAX_THINKING_TOKENS` tripwire.
