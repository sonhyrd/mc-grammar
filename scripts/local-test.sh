#!/bin/bash
# Local verification for McGrammar. Run this on your Mac before trusting the app.
#   ./scripts/local-test.sh          build + all checks
#   ./scripts/local-test.sh --quick  skip the release build, use the debug binary
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

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
if [ -n "$CLAUDE_BIN" ]; then
  OUT="$(echo "helo wrold, this are a test" | "$CLAUDE_BIN" -p "Fix grammar. Output only the corrected text." --max-turns 1 2>/tmp/mcgrammar-claude-err)"
  if [ -n "$OUT" ]; then
    pass "claude answered: $OUT"
  else
    fail "claude produced no output. stderr: $(head -c 300 /tmp/mcgrammar-claude-err)"
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
[ "$(plutil -extract NSServices.0.NSMessage raw Info.plist 2>/dev/null)" = "fixGrammar" ] \
  && pass "NSMessage=fixGrammar matches the @objc selector" \
  || fail "NSMessage does not match the ServiceProvider selector"
plutil -extract NSServices.0.NSReturnTypes.0 raw Info.plist >/dev/null 2>&1 \
  && pass "NSReturnTypes declared (selection replacement will work)" \
  || fail "NSReturnTypes missing — the Service would be send-only"
[ "$(plutil -extract LSUIElement raw Info.plist 2>/dev/null)" = "true" ] \
  && pass "LSUIElement=true (menu bar only, no Dock icon)" \
  || fail "LSUIElement is not true"

step "7. App self-test (real Claude round trip)"
if [ -x "$BIN" ]; then
  "$BIN" --selftest
  [ $? -eq 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
else
  fail "no binary to run at $BIN"
fi

step "Summary"
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "Next: ./make-app.sh  then test in Notes with:"
  echo "  this are a sentense with mistake"
  exit 0
fi
exit 1
