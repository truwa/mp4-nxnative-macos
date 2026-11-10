#!/bin/bash
# Release build: the app without developer options, signed with Developer ID (hardened runtime), notarized and stapled; a drag-to-Applications disk image
# (the app, Applications, README.txt), also notarized; and a ZIP of the app for updates (Check for Updates takes the release's .zip).
# Modelled on the user's Nathan Drake Collection launcher (release.sh, macos/make_dmg.sh).
# Usage: scripts/release.sh [notes.md]          PUBLISH=1 also creates the GitHub release (the repo below, private until the user decides otherwise).
# The version is launcher/Resources/Info.plist's MP4Version (semantic: 0.3.0-beta); the tag is v<version>. Outputs go to release.noindex/<version>/.
# The notarization password stays in the Keychain profile (xcrun notarytool store-credentials); nothing secret is read from this repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
NOTES_FILE="${1:-}"
REPO="${RELEASE_REPO:-truwa/mp4-nxnative-macos}"
PROFILE="${NOTARY_KEYCHAIN_PROFILE:-mp4-notary}"
TEAM="${TEAM_ID:-2DG34W64L7}"
W="${W:-$( [ -d /Volumes/MACDATA ] && echo /Volumes/MACDATA/mp4-app.noindex || echo "$HOME/Claude/mp4-app.noindex" )}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :MP4Version' launcher/Resources/Info.plist)"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' launcher/Resources/Info.plist)"
case "$VERSION" in "$SHORT"|"$SHORT"-*) ;; *) echo "Info.plist: MP4Version $VERSION does not start with CFBundleShortVersionString $SHORT" >&2; exit 1;; esac
LABEL="$(python3 -c 'import sys; v=sys.argv[1]; c,_,p=v.partition("-"); c=c[:-2] if c.count(".")==2 and c.endswith(".0") else c; print(c+(" "+p if p else ""))' "$VERSION")"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' -v t="($TEAM)" 'index($2, "Developer ID Application:") == 1 && index($2, t) { print $2; exit }')}"
[ -n "$SIGN_ID" ] || { echo "No Developer ID Application certificate of team $TEAM in the keychain" >&2; exit 1; }
if ! err="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1 >/dev/null)"; then
    echo "The notarization profile \"$PROFILE\" does not work: $err" >&2
    echo "Store it once: xcrun notarytool store-credentials \"$PROFILE\" --apple-id <Apple ID> --team-id $TEAM (an app-specific password)" >&2
    exit 1
fi
# Built from committed code: the runtime from the fork's committed branch, not its working tree
NX_REF="${NX_REF:-main}"
if [ -n "$(git status --porcelain -- launcher runtime scripts Makefile)" ] || [ -n "$(git -C nxnative status --porcelain -- dm scripts)" ]; then
    [ "${ALLOW_DIRTY:-0}" = 1 ] || { echo "Uncommitted changes (launcher, runtime, scripts or the fork): commit first, or ALLOW_DIRTY=1 for a rehearsal" >&2; exit 1; }
fi

OUT="$ROOT/release.noindex/$VERSION"; rm -rf "$OUT"; mkdir -p "$OUT"
APP_NAME="MP4 nxnative.app"
DMG="$OUT/MP4 nxnative $LABEL.dmg"
ZIP="$OUT/MP4-nxnative-${VERSION}.zip"
echo "== Release $VERSION ($LABEL): runtime from nxnative $NX_REF, signed by team $TEAM, notarized with profile $PROFILE"

# 1. The app: runtime bundle, private Python, the launcher without developer options (no DEVELOPER flag)
W="$W" NX_REF="$NX_REF" scripts/make_runtime.sh
[ -x "$W/python-private/python/bin/python3" ] || W="$W" scripts/make_private_python.sh
(cd launcher && RUNTIME="$W/Runtime" PYTHON="$W/python-private/python" DEVELOPER=0 scripts/make-app.sh release)
ditto "launcher/dist/$APP_NAME" "$OUT/$APP_NAME"
APP="$OUT/$APP_NAME"
# Python's bytecode written now, inside the signature: the app runs Python with -B, so nothing is written into the bundle later
"$APP/Contents/Resources/Python/bin/python3" -m compileall -q -j 0 "$APP/Contents/Resources/Python/lib" "$APP/Contents/Resources/Runtime" >/dev/null 2>&1 || true
xattr -cr "$APP"

# 2. Sign every Mach-O inside (deepest first), executables with the entitlements, then the app
python3 - "$APP" "$SIGN_ID" "$ROOT/launcher/Resources/entitlements.plist" <<'PY'
import os, struct, subprocess, sys
root, identity, ent = sys.argv[1:]
main = os.path.realpath(os.path.join(root, 'Contents/MacOS/MP4Launcher'))
MAGIC = {b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
found = []
for d, _, names in os.walk(root):
    for n in names:
        p = os.path.join(d, n)
        if os.path.islink(p) or os.path.realpath(p) == main: continue
        with open(p, 'rb') as f: head = f.read(16)
        if head[:4] not in MAGIC: continue
        # MH_EXECUTE (filetype 2) gets the entitlements; a fat file is checked through file(1)
        exe = struct.unpack('<I', head[12:16])[0] == 2 if head[:4] == b'\xcf\xfa\xed\xfe' else 'executable' in subprocess.run(['file', '-b', p], capture_output=True, text=True).stdout
        found.append((p.count(os.sep), p, exe))
found.sort(reverse=True)
for _, p, exe in found:
    cmd = ['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp'] + (['--entitlements', ent] if exe else []) + [p]
    subprocess.check_call(cmd, stdout=subprocess.DEVNULL)
subprocess.check_call(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', '--entitlements', ent, root])
print(f'signed {len(found)} binaries inside, then the app')
PY
codesign --verify --deep --strict --verbose=2 "$APP"

submit_notary() {
    local file="$1" json; json="$(mktemp)"
    echo "Notarizing $(basename "$file")…"
    set +e; xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json >"$json"; set -e
    python3 - "$json" "$PROFILE" <<'PY'
import json, subprocess, sys
raw = open(sys.argv[1]).read().strip()
try: r = json.loads(raw)
except Exception: print(raw); sys.exit(1)
print(f"notarization: {r.get('status')} ({r.get('id')})")
if r.get('status') != 'Accepted':
    if r.get('id'): subprocess.run(['xcrun', 'notarytool', 'log', r['id'], '--keychain-profile', sys.argv[2]])
    sys.exit(1)
PY
    rm -f "$json"
}

# 3. Notarize and staple the app; the update ZIP from the stapled app
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
submit_notary "$OUT/notarize.zip"; rm -f "$OUT/notarize.zip"
xcrun stapler staple "$APP"; xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 4. The disk image: the app, a link to Applications, README.txt; signed, notarized, stapled
VOL="MP4 nxnative $LABEL"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mp4-dmg.XXXXXX")"
RW="$OUT/rw.dmg"; DEVICE=""
cleanup() { [ -n "$DEVICE" ] && hdiutil detach "$DEVICE" -quiet || true; rm -rf "$STAGE" "$RW"; }
trap cleanup EXIT
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/launcher/Resources/README.txt" "$STAGE/README.txt"
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/^\/dev\// { dev=$1 } END { print dev }')"
for _ in $(seq 1 25); do [ -d "/Volumes/$VOL/$APP_NAME" ] && break; sleep 0.2; done
osascript <<EOF || true
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {280, 140, 920, 560}
        set theView to icon view options of container window
        set arrangement of theView to not arranged
        set icon size of theView to 128
        set position of item "$APP_NAME" of container window to {160, 180}
        set position of item "Applications" of container window to {480, 180}
        set position of item "README.txt" of container window to {320, 360}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
sync; hdiutil detach "$DEVICE" -quiet; DEVICE=""
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"; rm -f "$RW"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
submit_notary "$DMG"
xcrun stapler staple "$DMG"; xcrun stapler validate "$DMG"
echo "== Built:"; ls -la "$OUT" | sed 1d

# 5. The GitHub release (PUBLISH=1): a normal release, not a pre-release, so the update check's releases/latest finds it
if [ "${PUBLISH:-0}" = 1 ]; then
    notes=(--notes "MP4 nxnative $LABEL. Install: open the .dmg and drag MP4 nxnative onto Applications (README.txt inside). Update: the .zip (Check for Updates uses it). Signed and notarized.")
    [ -n "$NOTES_FILE" ] && notes=(--notes-file "$NOTES_FILE")
    gh release create "v$VERSION" "$DMG" "$ZIP" --repo "$REPO" --title "MP4 nxnative $LABEL" "${notes[@]}"
    echo "Published v$VERSION on $REPO"
fi
