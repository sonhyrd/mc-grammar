#!/bin/bash
# Local verification for McGrammar. Run this on your Mac before trusting the app.
#   ./scripts/local-test.sh          build + all checks
#   ./scripts/local-test.sh --quick  skip the release build, use the debug binary
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# Scratch space for captured stderr, removed on every exit path including Ctrl-C.
TMP_DIR="$(mktemp -d -t mcgrammar-test)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

PASS=0
FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

step "1. Platform"
if [ "$(uname -s)" = "Darwin" ]; then
  pass "macOS $(sw_vers -productVersion)"
else
  fail "Not macOS — McGrammar is an AppKit menu bar app and cannot run here."
  echo; echo "Aborting."; exit 1
fi

step "2. Toolchain"
if command -v swift >/dev/null 2>&1; then
  pass "swift $(swift --version 2>/dev/null | head -1)"
else
  fail "swift not found — install the Xcode command line tools: xcode-select --install"
fi

step "3. Claude Code CLI"
CLAUDE_BIN="$(/bin/zsh -l -c 'command -v claude' 2>/dev/null | head -1)"
if [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; then
  pass "claude resolved through a login shell: $CLAUDE_BIN"
else
  fail "claude not on the login-shell PATH — install Claude Code and run 'claude login'"
fi

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  note "ANTHROPIC_API_KEY is exported in this shell. It takes precedence over your"
  note "subscription login in the CLI. McGrammar strips it from the child process,"
  note "but unset it in your shell profile so terminal checks match the app."
else
  pass "No ANTHROPIC_API_KEY exported (subscription login will be used)"
fi

step "4. Terminal round trip through claude -p"
# Run from McGrammar's own marked workspace, exactly as the app does. Run from the repo instead
# and the CLI writes a transcript of this text into ~/.claude/projects/<repo-slug>/ — an unmarked
# folder that both Transcripts.purge and the step 8 check below ignore by design, so the test
# script would silently break the project's own "leaves the machine as it found it" invariant.
CLI_WORKSPACE="$HOME/Library/Application Support/McGrammar/cli-workspace"
mkdir -p "$CLI_WORKSPACE"
if [ -n "$CLAUDE_BIN" ]; then
  OUT="$(cd "$CLI_WORKSPACE" && echo "helo wrold, this are a test" | "$CLAUDE_BIN" -p "Fix grammar. Output only the corrected text." --max-turns 1 2>"$TMP_DIR/claude-err")"
  if [ -n "$OUT" ]; then
    pass "claude answered: $OUT"
  else
    fail "claude produced no output. stderr: $(head -c 300 "$TMP_DIR/claude-err")"
  fi
else
  fail "skipped — no claude binary"
fi

step "5. Build"
if [ "${1:-}" = "--quick" ]; then
  swift build >/dev/null 2>&1 && pass "debug build succeeded" || { swift build; fail "debug build failed"; }
  BIN="$(swift build --show-bin-path)/McGrammar"
else
  swift build -c release >/dev/null 2>&1 && pass "release build succeeded" || { swift build -c release; fail "release build failed"; }
  BIN="$(swift build -c release --show-bin-path)/McGrammar"
fi

step "6. Info.plist"
if plutil -lint Info.plist >/dev/null 2>&1; then
  pass "Info.plist is well-formed"
else
  fail "Info.plist failed plutil -lint"
fi
# Entry 0 is the default preset (Polish since ADR 0002); the last entry is the send-only
# Translate hand-off, which must NOT declare NSReturnTypes or macOS would paste the selection
# over itself. --selftest re-checks both against the Swift source of truth.
[ "$(plutil -extract NSServices.0.NSMessage raw Info.plist 2>/dev/null)" = "polishText" ] \
  && pass "NSServices.0 is polishText (the default preset)" \
  || fail "NSServices.0.NSMessage is not polishText"
plutil -extract NSServices.0.NSReturnTypes.0 raw Info.plist >/dev/null 2>&1 \
  && pass "NSReturnTypes declared on the preset entry (selection replacement will work)" \
  || fail "NSReturnTypes missing — the Service would be send-only"
LAST=$(( $(plutil -extract NSServices raw Info.plist 2>/dev/null || echo 0) - 1 ))
[ "$(plutil -extract "NSServices.$LAST.NSMessage" raw Info.plist 2>/dev/null)" = "translateText" ] \
  && pass "Last NSServices entry is translateText (the Translate hand-off)" \
  || fail "Last NSServices entry is not translateText"
plutil -extract "NSServices.$LAST.NSReturnTypes" raw Info.plist >/dev/null 2>&1 \
  && fail "translateText declares NSReturnTypes — it must be send-only" \
  || pass "translateText is send-only (no NSReturnTypes)"
[ "$(plutil -extract LSUIElement raw Info.plist 2>/dev/null)" = "true" ] \
  && pass "LSUIElement=true (menu bar only, no Dock icon)" \
  || fail "LSUIElement is not true"
# The default Services timeout is far too short for Claude Code spin-up; 120000ms is a hard
# requirement, not a preference. Unchecked, a regression here reads as "the Service does nothing".
[ "$(plutil -extract NSServices.0.NSTimeout raw Info.plist 2>/dev/null)" = "120000" ] \
  && pass "NSTimeout=120000 (long enough for Claude Code spin-up)" \
  || fail "NSServices.0.NSTimeout is not 120000"
[ "$(plutil -extract NSServices.0.NSSendTypes.0 raw Info.plist 2>/dev/null)" = "NSStringPboardType" ] \
  && pass "NSSendTypes declares NSStringPboardType" \
  || fail "NSSendTypes.0 is not NSStringPboardType"

step "7. App self-test (real Claude round trip)"
if [ -x "$BIN" ]; then
  "$BIN" --selftest
  [ $? -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
else
  fail "no binary to run at $BIN"
fi

step "8. Leftovers"
WORKSPACE="$HOME/Library/Application Support/McGrammar/cli-workspace"
LEFTOVER=$(find "$HOME/.claude/projects" -maxdepth 2 -type d -name '*McGrammar-cli-workspace*' -exec find {} -name '*.jsonl' \; 2>/dev/null | wc -l | tr -d ' ')
if [ "${LEFTOVER:-0}" = "0" ]; then
  pass "No Claude CLI transcripts left in McGrammar's workspace"
else
  fail "$LEFTOVER transcript(s) left under ~/.claude/projects for McGrammar's workspace"
  note "Expected 0 — the app purges them after each fix. README documents this as a guarantee,"
  note "so it fails the run rather than merely warning."
fi
[ -d "$WORKSPACE" ] && pass "CLI workspace is a directory McGrammar owns: $WORKSPACE" \
  || note "CLI workspace not created yet (no fix has run from the app)"

step "Summary"
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "Next: ./make-app.sh  then test in Notes with:"
  echo "  this are a sentense with mistake"
  exit 0
fi
exit 1
