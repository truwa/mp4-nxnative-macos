#!/bin/sh
# Builds the Swift package and assembles dist/MP4 Launcher.app.
# Usage: scripts/make-app.sh [debug|release]
set -eu
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
# TOOLS_UPDATE_BUTTON=1 builds the manual "Update tools" button back in (off: a new app installs its own tools).
FLAGS=""
[ "${TOOLS_UPDATE_BUTTON:-0}" = 1 ] && FLAGS="-Xswiftc -DTOOLS_UPDATE_BUTTON"
# DEVELOPER=1 (make app, our builds) keeps the developer options (Settings > Advanced > Threads only, Game > Test Build); make release leaves them out
[ "${DEVELOPER:-0}" = 1 ] && FLAGS="$FLAGS -Xswiftc -DDEVELOPER"
swift build -c "$CONFIG" --arch arm64 $FLAGS
BIN="$(swift build -c "$CONFIG" --arch arm64 $FLAGS --show-bin-path)"
APP="dist/MP4 nxnative.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MP4Launcher" "$APP/Contents/MacOS/MP4Launcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Credits.html "$APP/Contents/Resources/Credits.html"   # the About panel shows it: nxnative's MIT notice and the bundled tools' licences
# Every build its own number (About and Settings show it), so testers can tell builds apart
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M)" "$APP/Contents/Info.plist"
echo "APPL????" > "$APP/Contents/PkgInfo"
# The icon, drawn in Resources/AppIcon.svg, rendered to an .icns (scripts/make-icon.swift, iconutil).
ICONWORK="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/icon"
mkdir -p "$ICONWORK"
if [ ! -x "$ICONWORK/make-icon" ] || [ scripts/make-icon.swift -nt "$ICONWORK/make-icon" ]; then
  xcrun swiftc -O scripts/make-icon.swift -o "$ICONWORK/make-icon"
fi
rm -rf "$ICONWORK/AppIcon.iconset"
"$ICONWORK/make-icon" Resources/AppIcon.svg "$ICONWORK/AppIcon.iconset"
iconutil -c icns "$ICONWORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${PYTHON:-}" ]; then    # embed the private Python (top-level make app; scripts/make_private_python.sh)
  ditto "$PYTHON" "$APP/Contents/Resources/Python"
fi
if [ -n "${RUNTIME:-}" ]; then   # embed the runtime bundle (top-level make app)
  ditto "$RUNTIME" "$APP/Contents/Resources/Runtime"
  find "$APP/Contents/Resources/Runtime" -name __pycache__ -prune -exec rm -rf {} +
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
[ -n "${RUNTIME:-}" ] || echo "Put the runtime bundle at dist/Runtime (next to the app) for development."
