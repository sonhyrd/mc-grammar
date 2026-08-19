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
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "==> Assembling $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp "$REPO_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
# Ad-hoc signing with a stable identifier keeps the Accessibility (TCC) grant across rebuilds.
codesign --force --sign - --identifier "com.zernonia.mcgrammar" "$APP_PATH"
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

  Hotkey path      ⌃⌥G — needs Accessibility permission for McGrammar.app
                   System Settings → Privacy & Security → Accessibility
  Services path    select text → right-click → Services → "Fix Grammar with McGrammar"
                   no permission needed; enable it under
                   System Settings → Keyboard → Keyboard Shortcuts → Services → Text

  Headless check   "$APP_PATH/Contents/MacOS/$APP_NAME" --selftest
NOTE
