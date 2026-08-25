import Foundation

/// What McGrammar can be asked to do to a selection.
///
/// The names are the copy desk's own, and the distinction is theirs too: proofreading is the final
/// surface pass — spelling, grammar, punctuation, nothing else — while the style pass changes how
/// the writing reads. "Fix" deliberately is not one of these names. It is the operation the whole
/// app performs (`fixSync`, `FixError`, `--fix`, the pinned `fixGrammar` service selector), and
/// reusing it for one preset would overload a word this codebase already spends.
///
/// Both presets carry their rules in `prompt`, which goes in `-p`, and a one-line `role`, which
/// goes in `--system-prompt`. That split is an INVARIANT, not a style choice — see the comment on
/// `Preset.prompt` and docs/adr/0001-isolate-the-claude-code-invocation.md.
enum Preset: String, CaseIterable {
    /// Surface errors only. The preset to reach for when you need to be certain nothing but a
    /// mistake was touched — and the fallback when Polish does something you did not want.
    case proofread
    /// Idiomatic, native-sounding English, holding the meaning fixed. The reason this app exists
    /// beyond spellcheck: text that is already grammatical can still read as stilted, and no
    /// amount of correction fixes that.
    case polish

    /// Picks a preset off the command line for `--fix`. Unknown or absent means the default.
    ///
    /// The default is deliberately named at each call site rather than defaulted here, so that
    /// changing which preset is default is one visible edit rather than a silent change of
    /// meaning in a helper.
    static func fromArguments(_ arguments: [String], default fallback: Preset) -> Preset {
        for preset in Preset.allCases where arguments.contains("--\(preset.rawValue)") {
            return preset
        }
        return fallback
    }

    /// Name for the menu, the toast and `--selftest` output.
    var displayName: String {
        switch self {
        case .proofread: return "Proofread"
        case .polish: return "Polish"
        }
    }

    /// The rules, which go in `-p`.
    ///
    /// **These live in `-p`, NOT in `--system-prompt`, and that placement is load-bearing.** Moving
    /// them into the system prompt and reducing `-p` to a bare pointer reads tidier and measures
    /// identically on a short input — but on a long, multi-error paragraph it fails roughly half
    /// the time, usually by returning the user's text completely unchanged and occasionally by
    /// emitting a list of corrections ("their → they're") that then gets pasted over the
    /// selection. Measured on the hard fixture: 7/15 correct with the rules in `--system-prompt`,
    /// 14/14 correct with them here. Do not "tidy" this back. Any change to a prompt below must be
    /// verified with `McGrammar --fixtures` before merging; `--selftest`'s one easy sample would
    /// not have caught that regression.
    ///
    /// Written as flat prose with no Markdown, no bullets and no backticks, deliberately: prompt
    /// formatting bleeds into output formatting, and this output is pasted straight into whatever
    /// the user was writing in.
    var prompt: String {
        switch self {
        case .proofread:
            return Self.proofreadPrompt
        case .polish:
            return Self.polishPrompt
        }
    }

    /// Replaces Claude Code's ~3,300-token agent preamble, which is all about git status, tool
    /// discipline and output styles — none of it applicable here. Deliberately just a role line:
    /// the rules belong in `prompt`, for the reason documented above.
    var role: String {
        switch self {
        case .proofread:
            return "You are a grammar corrector. Output only corrected text."
        case .polish:
            return "You are a copy editor. Output only the edited text."
        }
    }

    /// Unchanged from the prompt this app shipped with, byte for byte. Tuned and deliberately
    /// strict — loosening it makes Claude rewrite instead of correct, which is what Polish is for.
    private static let proofreadPrompt = """
        Fix the grammar, spelling, and punctuation of the text provided via stdin. \
        Preserve the author's voice, tone, formatting, and line breaks. \
        Do NOT rewrite or rephrase beyond what is needed for correctness. \
        Output ONLY the corrected text. No preamble, no quotes, no explanations, no markdown fences.
        """

    /// The fluency pass.
    ///
    /// Two things about its shape are deliberate. First, it **enumerates the levels it may operate
    /// on** rather than stating a goal: "make this sound natural" is the instruction that produces
    /// over-rewriting, because it gives the model no way to tell an improvement it was asked for
    /// from one it was not. Second, **factual integrity comes first, with its reason attached**.
    /// It is first because it is the one guarantee the user cannot verify for themselves: a
    /// grammar correction is checkable at a glance, and a fluency rewrite is not — that is the
    /// whole point of it — so a fact quietly altered here is a fact that survives.
    private static let polishPrompt = """
        Edit the text provided via stdin. It was written by a fluent non-native speaker of \
        English: it is usually already grammatically correct and still reads as stilted, because \
        choosing the expression a native writer would actually use is a separate skill from \
        grammar. Make that choice on the author's behalf.

        Before anything else, and above every other instruction here: do not introduce, remove, or \
        alter any factual claim, name, number, date, quotation, link, or piece of code. Whoever \
        reads your output cannot check it against the original, because the entire point is that \
        it reads better than the original did, so a fact you change quietly becomes a fact they go \
        on to repeat. Keep every claim exactly as strong as you found it: do not add or remove a \
        hedge, and do not make a tentative statement confident or a confident statement tentative.

        Edit at these levels and at no others. Word choice and collocation: replace a word that is \
        correct but is not what a native writer would pair with its neighbours, preferring the \
        conventional set phrase over a literal construction. Articles and prepositions: correct a, \
        an, the, and preposition choice to the idiomatic form even where the original is \
        defensible, since these are the most visible non-native markers and they are learned \
        word by word rather than derived from a rule. Information order: open a sentence with what \
        the reader already knows and let the new or emphatic point land at the end, reordering \
        clauses when the original buries its point in the middle. Verbal over nominal style: \
        prefer a verb to an abstract noun built from a verb, where doing so does not change the \
        register. Rhythm: vary sentence length, splitting a sentence that has accumulated too many \
        clauses and joining two short ones that state a single thought.

        Hold these fixed. The register: a casual message stays casual, a formal one stays formal, \
        and a technical one keeps its terminology. The author's voice, and any phrasing that is \
        already idiomatic. The length, to within about a tenth. Every proper noun and technical \
        term exactly as the author spelled it, unless it is a plain misspelling of a word you are \
        certain of.

        Leave a sentence alone when it is already idiomatic. Changing a sentence that did not need \
        changing costs the reader's trust in everything else you changed, so the bar for touching \
        one is that a native writer would have noticed the original.

        Reproduce the input's structure exactly, apart from the wording you deliberately change: \
        the same paragraphs, the same line breaks, the same indentation, and the same list markers \
        and numbering. Leave code, commands, file paths, URLs and identifiers exactly as written. \
        Never translate: reply in the language the input is written in.

        Output only the edited text. Begin your reply with its first character and end with its \
        last. Do not add a preamble, a sign-off, an explanation, quotation marks, or a code fence \
        that the input did not already have.
        """
}
