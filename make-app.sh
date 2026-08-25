#!/bin/bash
# Build McGrammar, assemble the .app bundle, ad-hoc sign it, refresh the Services cache, launch.
set -euo pipefail

APP_NAME="McGrammar"
BUNDLE_ROOT="${MCGRAMMAR_INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$BUNDLE_ROOT/$APP_NAME.app"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$REPO_DIR"

echo "==> Building (release)"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -x "$BINARY" ] || { echo "Build produced no binary at $BINARY" >&2; exit 1; }

echo "==> Stopping any running instance"
# The bundle cannot be replaced underneath a live process, and a stale one would keep the
# old Services registration alive.
# Target the installed bundle, not every process that happens to share the name, and poll for
# the exit rather than sleeping a fixed beat — on a slow machine the rm below would otherwise
# delete the bundle out from under a still-live process, the exact state this step avoids.
pkill -f "$APP_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
for _ in $(seq 1 40); do
  pgrep -f "$APP_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || break
  sleep 0.1
done
if pgrep -f "$APP_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  echo "A running $APP_NAME did not exit after 4s. Quit it from the menu bar and re-run." >&2
  exit 1
fi

echo "==> Assembling $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp "$REPO_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
# TCC stores the Accessibility grant against the bundle's *designated requirement*. Left to
# itself, codesign gives an ad-hoc signature a DR that pins the exact cdhash — so every rebuild
# produces a new hash, silently invalidating the grant while System Settings still shows a ticked
# (now stale) McGrammar entry. Pinning the DR to the identifier instead keeps the grant across
# rebuilds. --identifier alone does NOT do this: it sets the bundle ID, not the requirement.
codesign --force --sign - --identifier "com.zernonia.mcgrammar" \
  -r='designated => identifier "com.zernonia.mcgrammar"' "$APP_PATH"
codesign --verify --verbose=1 "$APP_PATH" 2>&1 | sed 's/^/    /'

echo "==> Refreshing the Services cache"
# macOS caches the Services menu hard. This usually suffices; if the menu item is still missing,
# see the Services troubleshooting section in README.md.
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
/System/Library/CoreServices/pbs -update 2>/dev/null || true

echo "==> Launching"
open "$APP_PATH"

cat <<NOTE

$APP_NAME is running in the menu bar (look for the ✒︎ glyph).

  Hotkey path      ⌃⌥D — needs Accessibility permission for McGrammar.app
                   System Settings → Privacy & Security → Accessibility
  Services path    select text → right-click → Services → "Fix Grammar with McGrammar"
                   no permission needed; enable it under
                   System Settings → Keyboard → Keyboard Shortcuts → Services → Text

  Headless check   "$APP_PATH/Contents/MacOS/$APP_NAME" --selftest
NOTE
