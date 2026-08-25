# Prompt design for fluency polish, not just grammar correction

Research note for McGrammar. Written 2026-08-25 against Claude Code CLI **v2.1.245** (the version
installed on this machine — `claude --version`).

Scope: how to design the prompt(s) so the app can go beyond `Fix` (grammar/spelling/punctuation) to
`Polish` (natural, idiomatic, native-sounding English) without violating any invariant in
`CLAUDE.md`.

Every factual claim below carries its source URL. Claims I could not verify from a first-party
source are marked **UNVERIFIED**.

---

## 0. TL;DR — what I recommend

1. **Pass the instructions as a system prompt, not as the `-p` argument.** Use
   `--system-prompt "<TEXT>"`. This is documented
   ([code.claude.com/docs/en/cli-reference](https://code.claude.com/docs/en/cli-reference)) and is
   present in the local `claude --help`. It works on the subscription login — it is *not* an
   API-key feature, and it is not `--bare`.
2. **Add `--safe-mode` and `--tools ""`.** `--safe-mode` disables CLAUDE.md, skills, plugins,
   hooks, MCP, output styles, while explicitly keeping auth working; `--tools ""` disables all
   built-in tools. Together with `--system-prompt` this collapses the prompt down to just our
   instructions. Measured on this machine: **$0.150 → $0.002** for the same one-sentence fix, and
   the answer arrived in ~1.5–2.1 s instead of ~2.1 s+ of extra startup. See §2.4 for the numbers.
3. **Three presets** (`Fix`, `Polish`, `Formal`) sharing one common "contract" block. Ready to
   paste as Swift multiline strings in §4.
4. **Switch the invocation to `--output-format json` and read `result`.** CLAUDE.md already names
   this as the escape hatch for preamble leakage; it is also the only way to make the current
   `sanitize()` fence-stripping safe (§5.3), and it gets you a hard "did it actually succeed"
   signal (`is_error`, `subtype`). Verified live (§2.5).
5. **Do not use few-shot examples in the shipped prompts.** Reasoning in §6.

---

## 1. What Anthropic's own docs say (primary sources)

The prompt-engineering docs consolidated in 2026: the overview page now says *"All prompting
techniques (from clarity and examples to XML structuring, role prompting, thinking, and prompt
chaining) are covered in Prompting best practices. That's the living reference; start there."*
— [platform.claude.com/docs/en/build-with-claude/prompt-engineering/overview](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/overview)
(`docs.claude.com/en/docs/build-with-claude/prompt-engineering/overview` 302-redirects there).

Everything in §1.1–§1.8 is from the single living reference:
[platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)

### 1.1 Be clear and direct
> "Claude responds well to clear, explicit instructions. Being specific about your desired output
> can help enhance results. If you want 'above and beyond' behavior, explicitly request it rather
> than relying on the model to infer this from vague prompts."

> "**Golden rule:** Show your prompt to a colleague with minimal context on the task and ask them to
> follow it. If they'd be confused, Claude will be too."

Direct consequence for us: "make it sound more natural" is exactly the kind of vague instruction the
golden rule rejects. The `Polish` prompt has to *name the levels* it is allowed to operate on
(collocation, article/preposition idiom, information order, sentence rhythm) and name the levels it
is not (facts, structure, register).

### 1.2 Add context / motivation — this is the highest-leverage technique for us
> "Providing context or motivation behind your instructions, such as explaining to Claude why such
> behavior is important, can help Claude better understand your goals and deliver more targeted
> responses."

The doc's own example is precisely our situation: `NEVER use ellipses` is less effective than
*"Your response will be read aloud by a text-to-speech engine, so never use ellipses since the
text-to-speech engine will not know how to pronounce them."*

So the prompts below **state the deployment situation**: "the text you receive is the user's current
selection in some application, and whatever you output is pasted directly over that selection." That
one sentence does more work against preamble leakage, fence-wrapping and helpful commentary than any
number of `Do NOT` clauses.

### 1.3 Role / system prompt
> "Setting a role in the system prompt focuses Claude's behavior and tone for your use case. Even a
> single sentence makes a difference."

The doc's examples show the role going in the `system` field of the API call. The CLI equivalent is
`--system-prompt` / `--append-system-prompt` (§2.1).

### 1.4 Examples (few-shot / multishot)
> "Examples are one of the most reliable ways to steer Claude's output format, tone, and structure.
> A few well-crafted examples (known as few-shot or multishot prompting) improve accuracy and
> consistency."

Requirements the doc gives: **Relevant**, **Diverse**, **Structured** — *"Wrap examples in
`<example>` tags (multiple examples in `<examples>` tags) so Claude can distinguish them from
instructions."* Tip: *"Include 3–5 examples for best results."*

See §6 for why I still recommend shipping zero examples.

### 1.5 XML tags
> "XML tags help Claude parse complex prompts unambiguously, especially when your prompt mixes
> instructions, context, examples, and variable inputs. Wrapping each type of content in its own tag
> (for example, `<instructions>`, `<context>`, `<input>`) reduces misinterpretation."

Relevance for us is narrower than it first looks. Our variable input arrives on **stdin**, not
interpolated into the prompt string, so there is no instruction/data boundary inside a single string
to disambiguate. Wrapping the user's text in `<input>` tags would mean building a string containing
the user's text — which the stdin invariant in `CLAUDE.md` exists to avoid, and which introduces a
new failure mode (a selection that itself contains `</input>`). **Keep stdin. Do not add XML
delimitation around the user's text.** XML tags are still worth using *inside* the system prompt to
name a block of formatting rules, which is exactly what the doc's own anti-markdown sample does
(`<avoid_excessive_markdown_and_bullet_points>`).

### 1.6 Prefilling — no longer available, and irrelevant here anyway
> "Starting with Claude 4.6 models and Claude Mythos Preview, prefilled responses (providing a
> partial assistant message for Claude to continue from) on the last assistant turn are no longer
> supported. Requests with prefilled assistant messages to these models return a 400 error."

The doc's migration advice for the exact scenario we care about — "Eliminating preambles":
> "Use direct instructions in the system prompt: 'Respond directly without preamble. Do not start
> with phrases like "Here is...", "Based on...", etc.' Alternatively, direct the model to output
> within XML tags, use structured outputs, or use tool calling. **If the occasional preamble slips
> through, strip it in post-processing.**"

That is a first-party endorsement of the belt-and-braces approach: prompt instruction **plus**
`sanitize()` **plus** `--output-format json`.

Note: the CLI has no prefill flag in any case, so this is not a lost option — it is a closed door
worth documenting so nobody goes looking for it.

### 1.7 Output format control
> "1. **Tell Claude what to do instead of what not to do** — Instead of: 'Do not use markdown in
> your response' / Try: 'Your response should be composed of smoothly flowing prose paragraphs.'"

> "3. **Match your prompt style to the desired output** — The formatting style used in your prompt
> may influence Claude's response style. If you are still experiencing steerability issues with
> output formatting, try matching your prompt style to your desired output style as closely as
> possible. For example, removing markdown from your prompt can reduce the volume of markdown in
> the output."

Two concrete rules for our prompts:
- Prefer positive framing: **"Begin your reply with the first character of the edited text"** beats
  "Do NOT add a preamble". Keep one short negative clause as a backstop, but lead with the positive.
- **Write the system prompt in plain prose with no Markdown, no bullets, no backticks.** The current
  prompt is already plain prose; keep it that way. This is a real, documented mechanism and it is
  free.

### 1.8 Verbosity, and a model-specific caveat
> "Claude Opus 5 is an exception on verbosity: its default user-facing responses run longer than
> prior models', and raising or lowering effort does not reliably change visible response length.
> Prompt explicitly for conciseness instead."

The default model on this machine is `claude-opus-5[1m]` (observed in the `modelUsage` field of a
live `--output-format json` run). Two implications: the "output only the text" instruction has to
carry real weight, and pinning `--model sonnet` is worth considering (§2.6).

### 1.9 Long context — not our regime, one useful crumb
> "When working with large documents or data-rich inputs (20k+ tokens) ... **Put longform data at
> the top:** Place your long documents and inputs near the top of your prompt, above your query,
> instructions, and examples."

A text selection is essentially never 20k tokens, and stdin is capped at 10 MB anyway
([code.claude.com/docs/en/headless](https://code.claude.com/docs/en/headless)). Practically: our
layout already matches the advice — instructions live in the system prompt, the data arrives after
it. Nothing to change.

### 1.10 Chain of thought — deliberately declined
The best-practices page treats thinking as a lever for hard reasoning tasks, and separately warns
about *"Overthinking and excessive thoroughness."* For a 1–2 s interactive text replacement, visible
reasoning is a liability: it costs latency against a 60 s watchdog and it is text that could leak
into the pasted output. **Do not ask for reasoning, scratchpads, or `<thinking>` blocks in any of
the three presets.** If a future "diff preview HUD" preset (roadmap item 1) wants a rationale, that
is a different invocation with a different output contract, not this one.

---

## 2. Claude Code CLI flags — what exists TODAY

Sources: [code.claude.com/docs/en/cli-reference](https://code.claude.com/docs/en/cli-reference),
[code.claude.com/docs/en/headless](https://code.claude.com/docs/en/headless), and the local
`claude --help` on v2.1.245. Where the two disagree I say so.

### 2.1 System prompt flags — YES, available in headless mode

| Flag | Documented description |
|---|---|
| `--system-prompt <prompt>` | "Replace the entire system prompt with custom text" (docs) / "System prompt to use for the session" (local `--help`) |
| `--system-prompt-file <path>` | "Load system prompt from a file, replacing the default prompt" (docs) |
| `--append-system-prompt <prompt>` | "Append custom text to the end of the default system prompt" (docs and local `--help`) |
| `--append-system-prompt-file <path>` | "Load additional system prompt text from a file and append to the default prompt" (docs) |

The headless page shows `--append-system-prompt` used together with `-p` and a piped stdin, which
settles the "can a system prompt be supplied in headless mode" question affirmatively:

```bash
gh pr diff "$1" | claude -p \
  --append-system-prompt "You are a security engineer. Review for vulnerabilities." \
  --output-format json
```
— [code.claude.com/docs/en/headless](https://code.claude.com/docs/en/headless)

Caveat on the local `--help`: v2.1.245's help lists `--system-prompt` and `--append-system-prompt`
but does **not** list `--system-prompt-file` or `--append-system-prompt-file` as top-level entries —
they appear only inside the `--bare` help text as `--system-prompt[-file]`. They are documented in
the CLI reference. I verified `--system-prompt` works live; the `-file` variants are **UNVERIFIED**
on this version. Use the inline string form.

**For McGrammar, use `--system-prompt` (replace), not `--append-system-prompt`.** Replacing the
default Claude Code agent prompt is the whole point: we are not doing agentic coding, we do not want
the tool-use scaffolding, and the token savings are enormous (§2.4).

### 2.2 `-p` / `--print`
> "`-p`, `--print` — Print response without interactive mode"
— [cli-reference](https://code.claude.com/docs/en/cli-reference)

Local help adds an important note: *"The workspace trust dialog is skipped when Claude is run in
non-interactive mode (via -p, or when stdout is not a TTY...). Only use this in directories you
trust."* McGrammar already runs the child in its own
`~/Library/Application Support/McGrammar/cli-workspace`, so this is satisfied by construction — but
it is one more reason never to relax `prepareWorkspace()`.

### 2.3 `--max-turns`
> "Limit the number of agentic turns (print mode only). Exits with an error when the limit is
> reached. No limit by default."
— [cli-reference](https://code.claude.com/docs/en/cli-reference)

**It is documented but absent from v2.1.245's `--help` output.** I verified it is still accepted and
functional: `printf 'hi' | claude -p "Reply with the single word OK." --max-turns 1` → `OK`, exit 0.
Keep it. With `--tools ""` there is nothing for a second turn to do anyway, so it is now a belt on
top of braces rather than the primary guard.

### 2.4 `--safe-mode` and `--tools` — the compliant replacement for `--bare`

`CLAUDE.md` forbids `--bare`, and the docs confirm why: *"Set `ANTHROPIC_API_KEY` before running it,
because bare mode doesn't use your subscription login"* and *"In bare mode, Claude Code never reads
OAuth credentials or the system keychain"*
— [code.claude.com/docs/en/headless](https://code.claude.com/docs/en/headless). The invariant is
correct and should stay.

`--safe-mode` gets most of the same benefit with none of the credential problem. Local `--help`:
> "Start with all customizations (CLAUDE.md, skills, plugins, hooks, MCP servers, custom commands
> and agents, output styles, workflows, custom themes, keybindings, and more) disabled — useful for
> troubleshooting a broken configuration. Admin-managed (policy) settings still apply. **Auth, model
> selection, built-in tools, and permissions work normally.** Sets `CLAUDE_CODE_SAFE_MODE=1`."

The docs' one-liner: *"`--safe-mode` — Start with all customizations disabled"*
— [cli-reference](https://code.claude.com/docs/en/cli-reference).

`--tools`:
> "Restrict which built-in tools Claude can use. Use `""` to disable all, `"default"` for all, or
> tool names like `"Bash,Edit,Read"`."
— [cli-reference](https://code.claude.com/docs/en/cli-reference)

**Measured on this machine (single samples, indicative not statistical):**

| Invocation | cost (client-side estimate) | `duration_ms` | cache-creation input tokens |
|---|---|---|---|
| `-p PROMPT --max-turns 1 --output-format json` (today's shape) | **$0.1497** | 2124 | 14 144 (+15 891 read) |
| `+ --safe-mode --tools ""` | $0.0338 | 1587 | 3 244 |
| `+ --system-prompt "<instructions>"` | **$0.0020** | 1777 | 0 |

Two orders of magnitude, on a fix the user triggers dozens of times a day. This matters directly for
the constraint in `HANDOFF.md` §2.3 that headless `claude -p` draws from a capped
programmatic-credit pool. Cost figures are the CLI's own `total_cost_usd`, which the docs describe
as a *"client-side estimate"* that *"can differ from your actual bill"*
— [code.claude.com/docs/en/headless](https://code.claude.com/docs/en/headless).

A caution: `--safe-mode` disabling CLAUDE.md is a *benefit* here (we do not want a random project's
coding standards steering a grammar fix), but it does mean the child ignores any customization the
user might have deliberately set. Since the child already runs in McGrammar's own private workspace,
there is nothing there to ignore. **UNVERIFIED:** whether `--safe-mode` also ignores the user's
`~/.claude/settings.json` model choice — the help text says "model selection ... work[s] normally",
which reads as *the mechanism works*, not *your settings are honoured*. Pin `--model` explicitly if
determinism matters.

### 2.5 `--output-format` and the `result` field
> "`--output-format` — Specify output format for print mode (options: `text`, `json`,
> `stream-json`)"
— [cli-reference](https://code.claude.com/docs/en/cli-reference)

> "`json`: structured JSON with result, session ID, and metadata ... This example returns a project
> summary as JSON with session metadata, **with the text result in the `result` field**."
— [code.claude.com/docs/en/headless](https://code.claude.com/docs/en/headless)

Verified live. A real response envelope from this machine contains, among others:
`is_error` (bool), `subtype` ("success"), `result` (string), `session_id`, `num_turns`,
`stop_reason`, `total_cost_usd`, `usage`, `modelUsage`, `duration_ms`, `permission_denials`,
`api_error_status`, `type` ("result").

Note that stdout carried exactly one JSON object with no trailing text, while **stderr carried an
unrelated diagnostic line** (`Client.listTools() called but server does not advertise tools
capability - returning empty list`). McGrammar already drains stderr separately and only reads it on
non-zero exit, so this is harmless — but it is a good reminder never to merge the streams.

`stream-json` (roadmap item 2, streaming) is documented as newline-delimited JSON, and requires
`--verbose`, with `--include-partial-messages` for token-level deltas:
> "Use `--output-format stream-json` with `--verbose` and `--include-partial-messages` to receive
> tokens as they're generated."
— [code.claude.com/docs/en/headless](https://code.claude.com/docs/en/headless)

Also documented and potentially useful later: `--json-schema` for structured output, whose value
lands in a `structured_output` field. Not needed for a plain text replacement, but it is the clean
way to build the diff-preview HUD (roadmap item 1) — ask for `{corrected, changes[]}` in one call.

### 2.6 `--model` and `--settings`
> "`--model` — Sets the model for the current session with an alias for the latest model (`sonnet`,
> `opus`, `haiku`, or `fable`) or a model's full name."
— [cli-reference](https://code.claude.com/docs/en/cli-reference)

> "`--settings` — Path to a settings JSON file or an inline JSON string. Values you set here
> override the same keys in your `settings.json` files for this session."
— [cli-reference](https://code.claude.com/docs/en/cli-reference)

Also present: `--fallback-model <model>` ("only works with `--print`", per local help),
`--effort <level>` (`low`, `medium`, `high`, `xhigh`, `max`), `--max-budget-usd <amount>`
("only works with `--print`").

Single-sample latency probe with the `Polish` system prompt on one short sentence:
`--model sonnet` 1439 ms; `--model haiku` 6549 ms (likely a cold start, and not repeated); default
(`claude-opus-5[1m]`) 1777–2124 ms. **Do not read a model ranking into this** — one sample each,
network-dependent. The defensible conclusion is only that all three finish an order of magnitude
inside the 60 s watchdog, so model choice is a quality/cost decision, not a timeout decision.

My recommendation: **do not hardcode a model in v1.** Copy-editing is exactly the kind of task where
the frontier model's judgement about idiom is the product. If the credit pool becomes the binding
constraint, expose the model as a preference (`--model sonnet`) rather than baking it in. Consider
`--max-budget-usd` as a cheap runaway guard.

### 2.7 Flags I checked and deliberately reject
- `--bare` — forbidden by `CLAUDE.md`, and the docs confirm it requires `ANTHROPIC_API_KEY`.
- `--append-system-prompt` — works, but keeps the whole Claude Code agent prompt in context. Strictly
  worse than `--system-prompt` for this use case.
- `--effort` — the best-practices page says effort *"does not reliably change visible response
  length"* on Opus 5, and our task has no reasoning to dial. Skip.
- `--continue` / `--resume` — would persist state across fixes. Directly against the "never persist
  user text" guarantee. Never use.
- `--no-session-persistence` — *"Disable session persistence - sessions will not be saved to disk and
  cannot be resumed (only works with --print)"* (local `--help`). **This is worth investigating as a
  complement to `Transcripts.purge()`**: if it prevents the `.jsonl` transcript being written at all,
  it is a stronger privacy guarantee than deleting it afterwards. I did **not** verify what it does
  to the `~/.claude/projects/<slug>/` transcript specifically — **UNVERIFIED**, and it must be tested
  before the purge machinery is relaxed in any way. Treat it as belt-and-braces, never a replacement:
  keep `Transcripts.purge()` exactly as it is.

---

## 3. The linguistics: what separates "correct" from "native-like"

This section exists so the `Polish` prompt names real, checkable phenomena instead of gesturing at
"more natural". Each item below is something a model can act on.

### 3.1 The core finding: idiomatic selection is a separate competence from grammar
Pawley & Syder's classic formulation of the problem is exactly McGrammar's problem statement. They
call it **nativelike selection**: *"the ability of the native speaker routinely to convey his meaning
by an expression that is not only grammatical but also nativelike; what is puzzling about this is
how he selects a sentence that is natural and idiomatic from among the range of grammatically
correct paraphrases, many of which are non-nativelike or highly marked usages."* Their answer is
that fluent control rests on a large stock of **lexicalized sentence stems** — units of clause length
or longer whose form and lexical content is largely fixed.

> Pawley, A. & Syder, F. H. (1983). "Two puzzles for linguistic theory: nativelike selection and
> nativelike fluency." In J. C. Richards & R. W. Schmidt (eds.), *Language and Communication*.
> London: Longman, 191–226. Chapter listing:
> [taylorfrancis.com/chapters/edit/10.4324/9781315836027-14](https://www.taylorfrancis.com/chapters/edit/10.4324/9781315836027-14/two-puzzles-linguistic-theory-andrew-pawley-frances-hodgetts-syder)
> · widely circulated scan: [lextutor.ca/rt/pawley_syder_83.pdf](https://lextutor.ca/rt/pawley_syder_83.pdf)

This is the single most important sentence in this document for prompt design: **the user's text is
failing at selection, not at grammar.** A grammar-only prompt is structurally incapable of fixing it,
which is why `Polish` has to be a separate preset rather than a looser `Fix`.

### 3.2 The idiom principle (why collocation is the lever)
Sinclair's *idiom principle* — that a language user has available a large number of semi-preconstructed
phrases that constitute single choices, and that this, not the *open-choice principle* of free
slot-filling, dominates normal text — is the corpus-linguistic statement of the same fact.

> Sinclair, J. (1991). *Corpus, Concordance, Collocation.* Oxford: Oxford University Press.
> [global.oup.com/academic/product/corpus-concordance-collocation-9780194371445](https://global.oup.com/academic/product/corpus-concordance-collocation-9780194371445)

> Wray, A. (2002). *Formulaic Language and the Lexicon.* Cambridge: Cambridge University Press.
> [cambridge.org/core/books/formulaic-language-and-the-lexicon/1E1C4C4D7B9D6C4A0F0C1B3C2D4E5F60](https://www.cambridge.org/core/books/formulaic-language-and-the-lexicon/0A0E9E7C0F6C4F1B9A3E1C7D2B5A8F31)
> — **UNVERIFIED URL** (the book exists and the citation is correct; I did not confirm this exact
> Cambridge Core permalink). Cite the book, not the link.

Actionable rule for the prompt: *"prefer the collocation a native writer would use"* — e.g. *make a
decision* not *do a decision*, *heavy rain* not *strong rain*, *raise a concern* not *rise a
concern*.

### 3.3 Information structure: given before new, and the stress position
The most reliable structural fix for stilted-but-correct prose is reordering so that known
information opens the sentence and new/emphatic information closes it. Gopen & Swan's *American
Scientist* article is the most usable statement of this for a non-linguist audience, and its two
named concepts — **topic position** and **stress position** — are directly promptable:

> "Readers naturally emphasize the material that arrives at the end of a sentence" — the **stress
> position**, at points of syntactic closure. "When new information is important enough to receive
> emphasis, it functions best in the stress position."

> Gopen, G. D. & Swan, J. A. (1990). "The Science of Scientific Writing." *American Scientist*
> 78(6), 550–558. Author's page:
> [georgegopen.com/scientific-writing-articles/](https://georgegopen.com/scientific-writing-articles/)
> · full text (institutional copy):
> [gatsby.ucl.ac.uk/~pel/misc/gopen_swan.pdf](https://www.gatsby.ucl.ac.uk/~pel/misc/gopen_swan.pdf)

The underlying functional-linguistics account is Halliday's Theme/Rheme and the given-before-new
principle, and Prince's taxonomy of given/new:

> Halliday, M. A. K. (1967). "Notes on transitivity and theme in English, Part 2." *Journal of
> Linguistics* 3(2), 199–244. [doi.org/10.1017/S0022226700016613](https://doi.org/10.1017/S0022226700016613)

> Prince, E. F. (1981). "Toward a taxonomy of given-new information." In P. Cole (ed.), *Radical
> Pragmatics*. New York: Academic Press, 223–255.
> [repository.upenn.edu](https://repository.upenn.edu/handle/20.500.14332/12801) — **UNVERIFIED URL**;
> the paper is standard and easy to locate, the handle is not confirmed.

### 3.4 Nominalization vs. verbal style
Non-native academic/business English over-nominalizes (*we performed an evaluation of* → *we
evaluated*). The classic prescriptive treatment is Williams' two principles: make the main
characters the subjects, and make their important actions the verbs.

> Williams, J. M. & Bizup, J. *Style: Lessons in Clarity and Grace.* Pearson. (11th ed. and later.)
> Publisher page: [pearson.com](https://www.pearson.com/en-us/subject-catalog/p/style-lessons-in-clarity-and-grace/P200000005673)
> — **UNVERIFIED URL** (edition-specific pages move; the book is standard).

The descriptive counterpart — that nominalization is a register feature, dense in academic prose and
sparse in conversation, and that "grammatical metaphor" is the mechanism — is Halliday's:

> Halliday, M. A. K. & Matthiessen, C. (2014). *Halliday's Introduction to Functional Grammar*, 4th
> ed. Routledge. [routledge.com/9781444146608](https://www.routledge.com/9781444146608)
> — **UNVERIFIED URL**.

The important nuance for the prompt: **de-nominalizing is register-dependent, not universally good.**
Hence it belongs in `Polish` as a preference ("prefer a verb to an abstract noun *where it does not
change the register*"), not as an absolute rule, and `Formal` should be told to leave it alone.

### 3.5 Register is measurable and must be preserved
Preserving register is not vibes; it is a documented dimension along which grammatical features
distribute differently. The two corpus grammars are the authorities:

> Biber, D., Johansson, S., Leech, G., Conrad, S. & Finegan, E. (1999). *Longman Grammar of Spoken
> and Written English.* Harlow: Longman.

> Carter, R. & McCarthy, M. (2006). *Cambridge Grammar of English: A Comprehensive Guide.*
> Cambridge: Cambridge University Press.
> [cambridge.org/gb/cambridgeenglish/catalog/grammar-vocabulary-and-pronunciation/cambridge-grammar-english](https://www.cambridge.org/gb/cambridgeenglish/catalog/grammar-vocabulary-and-pronunciation/cambridge-grammar-english)
> — **UNVERIFIED URL**.

> Biber, D. & Conrad, S. (2009). *Register, Genre, and Style.* Cambridge University Press.
> [doi.org/10.1017/CBO9780511814358](https://doi.org/10.1017/CBO9780511814358)

Prompt consequence: `Polish` must be told *"keep the register of the input"* explicitly, because the
default gravity of a "make this better" instruction is toward formal written prose — which would
wreck a Slack message.

### 3.6 Hedging and stance
Under- and over-hedging is one of the most visible non-native markers, and it is
discipline/culture-specific. Hyland's monograph is the reference:

> Hyland, K. (1998). *Hedging in Scientific Research Articles.* Amsterdam: John Benjamins.
> [doi.org/10.1075/pbns.54](https://doi.org/10.1075/pbns.54)

Prompt consequence: **do not** tell the model to adjust hedging. Adjusting a hedge changes the
author's commitment to a claim — that is a meaning change, and it is exactly the kind of "helpful"
edit that makes a user distrust the tool. `Polish` should be told to *preserve* the strength of
claims. Put deliberate hedge-tuning in a future preset if the user ever asks for it.

### 3.7 Articles, prepositions, and why they are the hard part
Article and preposition choice is the classic persistent L2 difficulty, especially for speakers of
article-less L1s (Vietnamese, in this user's case), and it is largely lexically conditioned rather
than rule-derivable — i.e. it is a *collocation* problem in Sinclair's sense, not a grammar-rule
problem. Nation's treatment of what "knowing a word" involves — including its collocates and its
constraints on use — is the standard applied-linguistics framing:

> Nation, I. S. P. (2013). *Learning Vocabulary in Another Language*, 2nd ed. Cambridge University
> Press. [doi.org/10.1017/CBO9781139858656](https://doi.org/10.1017/CBO9781139858656)

Prompt consequence: name articles and prepositions explicitly in `Polish`. They are cheap wins the
model will otherwise leave alone, because they are not *errors* in the `Fix` sense — *"discuss about
the plan"* and *"in the weekend"* are the kind of thing a strict correction-only prompt often lets
through.

### 3.8 Sentence-length rhythm
Uniform sentence length reads as mechanical; varied length reads as human. I could not find a
primary source that states this as an empirical finding rather than as style advice, so I am
flagging it: **UNVERIFIED as a research claim.** It is standard prescriptive advice (Williams,
above; also every newsroom style guide), and it is a safe, meaning-preserving instruction, so it
earns a place in `Polish` as a preference — but do not present it to the user as science.

### 3.9 What this means for the prompt, concretely
`Polish` should enumerate its permitted levels of intervention, in roughly this order:
collocation and set phrases (§3.1–3.2) · article and preposition idiom (§3.7) · word order so given
information comes first and the emphatic point lands last (§3.3) · verb-over-abstract-noun where
register allows (§3.4) · sentence-length variation (§3.8).

And it should enumerate what it must not touch: facts, names, numbers, links, code, structure,
register (§3.5), and the strength of claims (§3.6).

---

## 4. Ready-to-paste Swift prompts

Design notes that apply to all three:

- Written as flat prose with **no Markdown, no bullets, no backticks** — per §1.7 rule 3, prompt
  style bleeds into output style, and our output must not acquire Markdown the input did not have.
- Each opens with a **role** (§1.3) and a **situation** (§1.2) before any instruction.
- Each ends with a positively-framed output contract (§1.7 rule 1) plus one short negative backstop.
- Each is meant to go in `--system-prompt`. The `-p` argument becomes a short task line.

```swift
/// Shared tail. Every preset ends with the same output contract so the parsing side has exactly
/// one shape to defend against. Positively framed first — per Anthropic's "tell Claude what to do
/// instead of what not to do" guidance — with a single negative backstop.
private static let outputContract = """
    Output the edited text and nothing else. Begin your reply with the first character of the \
    edited text and end it with the last. Do not add a preamble, a sign-off, an explanation, \
    quotation marks, or a Markdown code fence that the input did not already have.
    """

/// Shared preamble. States the deployment situation rather than just the rule, because Claude \
/// generalizes better from a stated reason than from a bare prohibition.
private static let situation = """
    You are an expert English copy editor working inside a macOS text-replacement utility. The \
    text arriving on standard input is the user's current selection in some application, and \
    whatever you output is pasted directly over that selection. There is no human reviewing your \
    reply before it lands in the user's document, so anything you add that is not the edited text \
    becomes a defect in their document.
    """

/// Shared fidelity clause. This is the clause that protects formatting, code and facts; all three \
/// presets need it verbatim.
private static let fidelity = """
    Reproduce the input's structure exactly apart from the wording you deliberately change: the \
    same paragraphs, the same line breaks, the same leading whitespace and indentation, the same \
    list markers and numbering, the same Markdown, HTML, or code, and the same presence or absence \
    of a trailing newline. Leave code, commands, file paths, URLs, identifiers, names, numbers, \
    dates, and quoted material exactly as written, including inside code spans and fenced blocks. \
    Keep every fact the input asserts and add none it does not. Never translate: reply in the \
    language the input is written in.
    """
```

### 4.1 `Fix` — conservative correction (today's behaviour, restated)

```swift
/// Correction only. Deliberately strict: this is the preset a user reaches for when they want to
/// be certain nothing but an error was touched.
static let fixPrompt = """
    \(situation)

    Correct the grammar, spelling, punctuation, and capitalization of the text. Fix only what is \
    actually wrong. Where more than one correction is possible, choose the one that changes the \
    fewest words. Preserve the author's voice, tone, register, vocabulary, and sentence structure. \
    A sentence that is already correct must come back byte-for-byte unchanged, even if you would \
    have phrased it differently. Do not rephrase, reorder, shorten, expand, or improve anything \
    that is not an error.

    \(fidelity)

    \(outputContract)
    """
```

Task line for `-p`: `"Correct the text that follows on standard input."`

### 4.2 `Polish` — fluency and naturalness, meaning-preserving

This is the preset this research is about. Note that the permitted interventions are *named* (§1.1,
§3.9) rather than left to "make it natural".

```swift
/// Fluency pass. Goes beyond correctness to idiomatic, native-sounding English while holding the
/// meaning, the register and the author's voice fixed. The permitted levels of intervention are
/// enumerated on purpose: an open-ended "make this sound natural" is the instruction that produces
/// over-rewriting.
static let polishPrompt = """
    \(situation)

    The author is a fluent non-native speaker of English. Their text is usually grammatically \
    correct but reads as stilted, because idiomatic selection is a separate skill from grammar: a \
    native writer picks one particular expression from among many grammatical paraphrases. Your \
    job is to make that selection on the author's behalf.

    Edit at these levels, and only these:

    Word choice and collocation. Replace a word that is correct but not what a native writer would \
    pair with its neighbours. Prefer the conventional set phrase over a literal construction.

    Articles and prepositions. Fix a, an, the, and preposition choice to the idiomatic form, even \
    where the original is defensible. These are the most visible non-native markers and they are \
    lexically conditioned rather than rule-derived.

    Information order. Within a sentence, open with what the reader already knows and let the new \
    or emphatic point land at the end, where readers naturally place stress. Reorder clauses to \
    achieve this when the original buries its point in the middle.

    Verbal over nominal style. Where it does not change the register, prefer a verb to an abstract \
    noun built from a verb, and let the real actor be the grammatical subject.

    Rhythm. Vary sentence length. Split a sentence that has accumulated too many clauses, and join \
    two short sentences that state one thought, when doing so does not change what is claimed.

    Hold all of the following fixed. The meaning, including the strength of every claim: do not add \
    or remove a hedge, and do not make a tentative statement confident or a confident statement \
    tentative. The register: a casual message stays casual, a formal one stays formal, and a \
    technical one keeps its terminology. The author's voice and their characteristic phrasing \
    wherever it is already idiomatic. The length, to within about ten percent. Every proper noun \
    and technical term exactly as the author spelled it, unless it is a plain misspelling of a word \
    you are certain of.

    Leave a sentence alone when it is already idiomatic. Changing a sentence that did not need \
    changing costs the user trust, so the bar for touching a sentence is that a native writer would \
    have noticed the original.

    \(fidelity)

    \(outputContract)
    """
```

Task line for `-p`: `"Polish the text that follows on standard input."`

**Verified behaviour** (live, `--safe-mode --tools "" --system-prompt <this> --output-format json`,
on an earlier draft of the above):

Input:
```
Hi Team,

I want to inform that the deploy is done at yesterday night. There is some issue about the cache, but we already fix it.

- item one is done
- item two we will do in next week

Thanks,
Son
```
Output (1.9–2.1 s, ~$0.010):
```
Hi Team,

I'd like to let you know that the deployment was completed last night. There was an issue with the cache, but we've already fixed it.

- item one is done
- item two we will do next week

Thanks,
Son
```
Blank lines, list markers, salutation and sign-off all survived; register stayed casual-professional;
nothing was added.

Second probe, mixed prose and code:
```
The function `parseUser()` are return a error when the input is null.

```js
if (x == null) { return err; }
```

We should to handle it more better.
```
→
```
The `parseUser()` function returns an error when the input is null.

```js
if (x == null) { return err; }
```

We should handle it better.
```
The fenced block came back byte-identical and the fence was not stripped or re-wrapped.

### 4.3 `Formal` — register shift (optional third preset)

Unlike the first two, this one is **licensed to change register**, which is why it must be a separate
explicit user choice and must never be the default.

```swift
/// Register shift. The only preset permitted to change the tone of the text, which is why it must
/// be an explicit user choice. Everything else is still held fixed.
static let formalPrompt = """
    \(situation)

    Rewrite the text in professional written English suitable for an email to a colleague you do \
    not know well, or for a document that will be read outside your team. Raise the register: \
    replace contractions, slang, and conversational filler with their neutral written equivalents, \
    and make requests and commitments explicit and courteous rather than blunt.

    Everything below stays fixed. Every fact, name, number, date, link, and technical term. The \
    strength of every claim and every commitment: a maybe stays a maybe, and a promise stays a \
    promise. The content: add no greeting, sign-off, pleasantry, justification, or sentence that \
    the input did not already contain or clearly imply. Do not pad. The result should be about as \
    long as the original and may be shorter.

    Formal does not mean ornate. Prefer the plain word to the elaborate one, keep sentences \
    readable, and do not reach for abstract nouns where a verb will do.

    \(fidelity)

    \(outputContract)
    """
```

Task line for `-p`: `"Rewrite the text that follows on standard input in a more formal register."`

### 4.4 Suggested invocation

```swift
process.arguments = [
    "-p", taskLine,                 // e.g. "Polish the text that follows on standard input."
    "--system-prompt", preset.prompt,
    "--output-format", "json",
    "--max-turns", "1",
    "--safe-mode",                  // no CLAUDE.md, skills, plugins, hooks, MCP; auth unaffected
    "--tools", "",                  // no tool use at all
]
```

Every flag here is documented in
[code.claude.com/docs/en/cli-reference](https://code.claude.com/docs/en/cli-reference) and I have run
this exact combination successfully on v2.1.245 against the subscription login. Nothing here touches
credentials, and `--bare` is not used.

---

## 5. Failure modes, and which technique mitigates each

### 5.1 Over-rewriting (the #1 risk when loosening `Fix`)
*Symptom:* the user asked for polish and got a paraphrase with their voice sanded off.

Mitigations, in order of effectiveness:
1. **Enumerate the permitted levels of intervention** instead of stating a goal. This is "be clear
   and direct" applied literally
   ([best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)),
   and it is the structural difference between §4.2 and a one-line "make this sound more natural".
2. **Give a threshold for acting**: "the bar for touching a sentence is that a native writer would
   have noticed the original." A bar is checkable; "don't overdo it" is not.
3. **Constrain length** ("to within about ten percent"). A numeric budget is the cheapest available
   proxy for "don't rewrite".
4. **Keep `Fix` as a separate preset.** The real mitigation is that the user who wants minimal
   change has a preset that promises minimal change, rather than a `Polish` prompt hedged into
   uselessness.

### 5.2 Hallucinated additions
*Symptom:* a sign-off, a pleasantry, a clarifying clause, or an invented detail appears.

Mitigations:
1. **State the consequence, not the rule** (§1.2): "There is no human reviewing your reply before it
   lands in the user's document, so anything you add that is not the edited text becomes a defect in
   their document." The docs' own text-to-speech example is the template for this.
2. **An explicit inventory of what is fixed** — facts, names, numbers, dates, links, claim strength —
   rather than a generic "don't add anything".
3. **`--tools ""`.** With no tools the model cannot go read a file and import a "fact" from it. This
   is a real risk today: without it, a `-p` session has Read/Bash/Edit available and is running in a
   directory.
4. **`--max-turns 1`.** A second turn is where a model decides to check its work and elaborates.

### 5.3 Preamble leakage, and the `--output-format json` question
*Symptom:* `Here is the corrected text:` gets pasted into the user's document.

`CLAUDE.md` already names JSON as the escape hatch. **I recommend taking it now, unconditionally,
rather than waiting for leakage to be observed.** Reasons:

- Anthropic's own migration guidance for eliminating preambles, now that prefill is gone, lists
  system-prompt instruction *and* post-processing as complementary, not alternative: *"If the
  occasional preamble slips through, strip it in post-processing."*
  ([best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices))
- JSON does not actually strip preamble — a preamble the model emits lands *inside* `result`. What
  JSON buys is different and arguably more valuable: **an unambiguous message boundary**. Today's
  `text` mode leaves you unable to distinguish the model's answer from a CLI warning or a partial
  flush. JSON gives you `is_error`, `subtype`, `stop_reason` and `num_turns` to check before you
  paste anything over someone's selection. Given the watchdog invariant in `CLAUDE.md` — that a
  truncated answer must never be treated as success — this is a direct strengthening of an existing
  safety property.
- **It fixes a live bug.** `ClaudeRunner.sanitize()` strips a leading ` ``` ` and its matching
  trailing fence. If the user's selection *is* a fenced code block — plausible in an editor or a
  Slack message — and the model correctly returns it unchanged (as it did in my §4.2 probe), then
  `sanitize()` will eat the fences and paste malformed content over the selection. With `result`
  parsed out of JSON, fence-stripping should be narrowed to "strip a fence only if the input did not
  start with one", or dropped entirely.

Cost: one JSON parse, no measurable latency (`duration_ms` was in the same range with and without),
and a new dependency on the envelope's field names — which are documented (`result`) and were stable
in my live run.

So: **JSON is not a substitute for prompt tightening; it is a substitute for guessing.** Do both.

### 5.4 Losing line breaks, indentation, Markdown, or code
*Symptom:* a bulleted list comes back as prose; a code block loses its fence; a trailing newline
appears or disappears; a plain-text email acquires `**bold**`.

Mitigations:
1. **The `fidelity` clause enumerates each artefact by name** — line breaks, leading whitespace, list
   markers, fences, trailing newline. Enumeration beats "preserve formatting" for the same reason
   §5.1 point 1 works.
2. **Write the prompt itself in plain prose with no Markdown.** Documented mechanism: *"The
   formatting style used in your prompt may influence Claude's response style... removing markdown
   from your prompt can reduce the volume of markdown in the output."*
   ([best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices))
   Today's prompt already satisfies this; the presets above keep it. **Do not** be tempted to format
   the new, longer prompts as Markdown bullet lists — that would actively regress this.
3. **Keep stdin.** Interpolating the selection into the argument string would put it through shell
   and argv handling; stdin delivers the bytes verbatim. This is already an invariant; the fluency
   work gives no reason to relax it.
4. **Consider asserting it in the self-test.** `SelfTest` currently checks one flat sentence. A
   second sample with a blank line, a list, and a fenced block — asserting the line-break count and
   the fence count are unchanged — would catch a prompt regression that the current sample cannot.

### 5.5 Losing the author's voice
*Symptom:* every message starts sounding like the same generic corporate writer.

Mitigations: the explicit "hold fixed" inventory in §4.2 (register, voice, characteristic phrasing,
claim strength); the instruction to leave already-idiomatic sentences alone; and the hedging
constraint from §3.6, which is the specific mechanism by which a polish pass most often changes what
the author actually committed to.

### 5.6 One more, specific to going beyond `Fix`
*Symptom:* the model "polishes" text that was never meant to be polished — a config snippet, a URL
list, a chunk of source code selected by accident.

Mitigation: the `fidelity` clause tells it to leave code, commands, paths, URLs and identifiers
alone, and the §4.2 probe confirms it does. But consider a cheap client-side guard too: if the
selection contains no sentence-final punctuation and more than some fraction of non-word characters,
it is probably not prose.

---

## 6. Are few-shot examples worth it here?

Anthropic is unambiguous that examples work: *"Examples are one of the most reliable ways to steer
Claude's output format, tone, and structure"*, with a tip to *"Include 3–5 examples for best
results"*
([best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)).

**I still recommend shipping zero examples in v1.** The reasoning:

- **The cost argument is weaker than it looks, and cuts the other way.** With `--system-prompt` the
  entire prompt is now ~400 tokens against a measured $0.002 per fix. Three or four before/after
  pairs might add a few hundred tokens — negligible against the $0.15 we are *already* saving by
  dropping the default agent prompt. Latency likewise: input tokens are cheap in wall-clock terms
  compared to the CLI's own startup. So cost is **not** the reason to skip them.
- **The real risk is the doc's own "Diverse" requirement.** *"Diverse: Cover edge cases and vary
  enough that Claude doesn't pick up unintended patterns."* For a general-purpose polish tool the
  input distribution is unbounded — Slack messages, commit messages, emails, docs, code comments, in
  any domain. Three or four examples cannot be diverse across that space, and non-diverse examples
  actively hurt: the model will start pulling every input toward the register and sentence shape of
  the examples. That is failure mode §5.5, introduced by the mitigation.
- **The instructions in §4.2 already specify the behaviour at the level examples would demonstrate.**
  Examples earn their keep when a behaviour is easier to show than to state. "Prefer the idiomatic
  collocation" is stateable.

**Where examples *would* earn their keep, and the right way to add them later:** a *user-specific*
example set. If the app ever grows a "corrections I accepted" memory, 3–5 of the user's own
before/after pairs would be exactly the Relevant + Diverse-for-this-user set the doc describes, and
would teach the model this user's voice rather than a generic one. That is a genuinely good v2
feature — but note it collides head-on with the "never log, cache, or persist user text" guarantee in
`CLAUDE.md`. It would need to be opt-in, explicit, and prominently documented, or it must not ship.

If you do add examples, follow the documented structure: wrap each in `<example>` tags inside an
`<examples>` block, in the system prompt, *not* around the stdin payload.

---

## 7. Risks and caveats for implementation

- **The 60 s watchdog is not the binding constraint.** Every measured invocation completed in
  1.4–6.5 s. Adding several hundred tokens of prompt does not threaten it. Do not let watchdog
  anxiety talk you out of a well-specified prompt.
- **Never add an API key path.** `--safe-mode` is specifically recommended here *because* it gets
  most of `--bare`'s benefit while, per the local `--help`, leaving auth working normally. `--bare`
  stays forbidden; the docs confirm it never reads OAuth credentials or the keychain
  ([headless](https://code.claude.com/docs/en/headless)).
- **`--max-turns` is documented but missing from v2.1.245's `--help`.** It still works (I verified).
  This is exactly the kind of drift `CLAUDE.md`'s "Watch items" section anticipates. Keep it, but if
  a future version rejects it, `--tools ""` already covers the same ground.
- **Cost figures are the CLI's own client-side estimates** and *"can differ from your actual bill"*
  ([headless](https://code.claude.com/docs/en/headless)). The 75× ratio is large enough that the
  direction is not in doubt; the absolute numbers are not billing-grade.
- **All timing and cost numbers here are single samples** taken on one machine on 2026-08-25. Treat
  them as indicative. In particular do not conclude from the one `--model haiku` probe (6.5 s) that
  Haiku is slow.
- **Formatting fidelity is byte-level and the current pipeline does not fully honour it.** Two
  existing behaviours quietly modify the text: `sanitize()` trims leading/trailing whitespace
  (so a selection's trailing newline is already lost today), and its fence-stripping can corrupt a
  selection that legitimately starts with a fence (§5.3). Decide deliberately what "byte-identical
  apart from the intended changes" means before shipping `Polish`, because `Polish` will be used on
  richer, more structured selections than `Fix` is.
- **`--no-session-persistence` is unverified** and must not be treated as a replacement for
  `Transcripts.purge()` (§2.7).
- **Adding presets multiplies the surface that `--selftest` must cover.** Each preset needs its own
  round-trip assertion, and the formatting-fidelity sample from §5.4 point 4 should run against all
  of them.
- **Re-verify before distribution.** `HANDOFF.md` §2.2 and `CLAUDE.md`'s watch items both require
  re-reading code.claude.com/docs/en/legal-and-compliance before shipping or charging. Nothing in
  this note changes that; `--system-prompt` and `--safe-mode` are ordinary documented CLI usage of
  the user's own authenticated binary.

---

## 8. Sources

Anthropic / Claude Code primary documentation:
- [Prompt engineering overview](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/overview)
- [Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices) (the living reference for all techniques)
- [CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Run Claude Code programmatically (headless)](https://code.claude.com/docs/en/headless)
- Local `claude --help` and live invocations, v2.1.245, 2026-08-25

Linguistics and style:
- Pawley & Syder (1983), "Two puzzles for linguistic theory: nativelike selection and nativelike fluency" — [chapter](https://www.taylorfrancis.com/chapters/edit/10.4324/9781315836027-14/two-puzzles-linguistic-theory-andrew-pawley-frances-hodgetts-syder), [scan](https://lextutor.ca/rt/pawley_syder_83.pdf)
- Sinclair (1991), *Corpus, Concordance, Collocation* — [OUP](https://global.oup.com/academic/product/corpus-concordance-collocation-9780194371445)
- Wray (2002), *Formulaic Language and the Lexicon*, CUP
- Gopen & Swan (1990), "The Science of Scientific Writing", *American Scientist* 78(6) — [author page](https://georgegopen.com/scientific-writing-articles/), [PDF](https://www.gatsby.ucl.ac.uk/~pel/misc/gopen_swan.pdf)
- Halliday (1967), "Notes on transitivity and theme in English, Part 2" — [doi:10.1017/S0022226700016613](https://doi.org/10.1017/S0022226700016613)
- Prince (1981), "Toward a taxonomy of given-new information"
- Biber et al. (1999), *Longman Grammar of Spoken and Written English*
- Carter & McCarthy (2006), *Cambridge Grammar of English*
- Biber & Conrad (2009), *Register, Genre, and Style* — [doi:10.1017/CBO9780511814358](https://doi.org/10.1017/CBO9780511814358)
- Hyland (1998), *Hedging in Scientific Research Articles* — [doi:10.1075/pbns.54](https://doi.org/10.1075/pbns.54)
- Nation (2013), *Learning Vocabulary in Another Language*, 2nd ed. — [doi:10.1017/CBO9781139858656](https://doi.org/10.1017/CBO9781139858656)
- Williams & Bizup, *Style: Lessons in Clarity and Grace*
