# CONTEXT.md — McGrammar glossary

The vocabulary this project uses, and the distinctions worth keeping. Terms only: no implementation
detail, no decisions. Decisions live in `docs/adr/`, invariants in `CLAUDE.md`.

## Fix

**The operation**, not a preset. One run of the whole pipeline: take a selection, send it to the
CLI, put the result back. It is spelled into the code in places that cannot move — `fixSync`,
`fixAsync`, `FixError`, `--fix`, and the `fixGrammar` service selector pinned by `Info.plist` — so
it is reserved for the operation and is never the name of one kind of fix.

Avoid "correct" as a synonym. It reads as a different word while meaning the same thing, which
re-creates the overload one synonym over.

## Preset

**What the user is asking to have done to their selection.** Two exist: `Proofread` and `Polish`.
A preset is the unit that carries a prompt and a role; every trigger path can reach every preset.

## Proofread

**The surface pass**: spelling, grammar, punctuation, and nothing else. Minimum change. A sentence
that is already correct comes back untouched.

## Polish

**The style pass**: makes text read as a native writer would have written it, holding the meaning
fixed. The name is the copy desk's, and so is the distinction from Proofread — proofreading is the
final surface pass, copy-editing is the style pass.

Polish exists because grammatical correctness and idiomatic fluency are different properties. Text
can be entirely correct and still read as stilted, and a preset told to fix errors is right to leave
it alone, because there is no error in it.

## factualIntegrity

**The guarantee that Polish does not change what the text asserts.** No factual claim, name, number,
date, quotation, link or piece of code introduced, removed or altered, and no claim made stronger or
weaker.

It is named because a name can be traced: the clause in the prompt, the fixture that proves it, and
this entry all use the same word. Distinct from *fidelity*, which is about reproducing the input's
**structure** — line breaks, indentation, list markers. Preserving a code snippet and preserving a
claim are not the same promise.

## Trigger path

**A way for a user to start a fix.** There are exactly **two**: the **hotkey path** (a global
Carbon hotkey, drives ⌘C and ⌘V with synthetic events, needs Accessibility permission) and the
**Services path** (macOS hands over the selection and replaces it natively, needs no permission).

The menu bar dropdown is **not** a third path. Its items call into the hotkey path and need the same
Accessibility grant. Read the code before assuming otherwise; this entry exists because that
mistake was made in this project.

The two paths do not know the same things. The hotkey path posts the keystroke itself and can report
whether it was delivered. The Services path hands the text back and macOS replaces the selection
afterwards with no callback, so it can only report the handover. Anything user-facing must respect
that difference rather than flattening it.

## Selection

**The text the user had highlighted when they triggered a fix**, and the exact span that gets
replaced. Its boundaries are part of the contract: its own leading and trailing whitespace is
preserved, because on the Services path that boundary is precisely what macOS overwrites.

## Workspace

**The private directory McGrammar runs the CLI in**, under Application Support. It exists so the
transcripts the CLI writes land in a project folder that only McGrammar causes to exist, and can
therefore be deleted wholesale.

## Transcript

**A session file the CLI writes**, containing the user's text. McGrammar persists nothing itself;
the transcript is the one thing on disk that the app is responsible for removing after every fix.
