#!/bin/sh
# Assembles the app's runtime bundle in $W/Runtime: the launcher's build and play scripts, the nxnative tree (branch
# mp4-record, without docs, tests and other games' profiles), the .NET runtime (no SDK) and a prebuilt nx_extract.
# Nothing from the game is in it.
set -eu
cd "$(dirname "$0")/.."
W="${W:-$( [ -d /Volumes/MACDATA ] && echo /Volumes/MACDATA/mp4-app.noindex || echo "$HOME/Claude/mp4-app.noindex" )}"
R="$W/Runtime"; NX="${NX_DIR:-nxnative}"; REF="${NX_REF:-mp4-record}"
DOTNET="${DOTNET_HOME:-$( [ -d /opt/homebrew/opt/dotnet/libexec ] && echo /opt/homebrew/opt/dotnet/libexec || echo /usr/local/share/dotnet )}"   # Homebrew's, else the official installer's (the M4)
rm -rf "$R" && mkdir -p "$R/bin" "$R/nxnative"
cp runtime/nx_build.py runtime/nx_play.py runtime/nx_speedtest.py runtime/recorded_shaders.txt runtime/build-format.json runtime/shader-profile.tsv "$R/"
cp runtime/bin/zstd "$R/bin/" && chmod +x "$R/bin/zstd"
# The nxnative tree at $REF (NX_REF=WORKTREE: the working tree as it is, tracked and new files, for testing uncommitted work): other games' profiles, docs and tests left out.
set -f   # the patterns below are for tar, not the shell
EXCL="--exclude docs/*.md --exclude docs/agents --exclude docs/reference --exclude */tests/* --exclude dm/games/0* --exclude dm/games/1*"
if [ "$REF" = WORKTREE ]; then
  (cd "$NX" && git ls-files -co --exclude-standard -z | tar -c --null -T - -f -) | tar -x -C "$R/nxnative" $EXCL
  (cd "$NX" && git ls-files -co --exclude-standard -z dm/games/010019A01E2F2000 | tar -c --null -T - -f -) | tar -x -C "$R/nxnative"
else
  git -C "$NX" archive "$REF" | tar -x -C "$R/nxnative" $EXCL
  git -C "$NX" archive "$REF" dm/games/010019A01E2F2000 | tar -x -C "$R/nxnative"
fi
set +f
# .NET: the runtime only (the translator and nx_extract are framework-dependent apphosts).
mkdir -p "$R/dotnet"
ditto "$DOTNET/dotnet" "$R/dotnet/dotnet"
ditto "$DOTNET/host" "$R/dotnet/host"
ditto "$DOTNET/shared/Microsoft.NETCore.App" "$R/dotnet/shared/Microsoft.NETCore.App"
# nx_extract, built once here (NuGet restore needs the network; the player's Mac does not).
T="$(mktemp -d)"
DOTNET_ROOT="$DOTNET" DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 "$DOTNET/dotnet" build "$R/nxnative/dm/tools/nx_extract" -c Release -o "$T/out" -v quiet -nologo >/dev/null
[ -x "$T/out/nx_extract" ] || { echo "nx_extract did not build" >&2; exit 1; }
ditto "$T/out" "$R/nx_extract"; rm -rf "$T" "$R/nxnative/dm/tools/nx_extract/bin" "$R/nxnative/dm/tools/nx_extract/obj"
echo "$(git -C "$NX" rev-parse --short=8 "$([ "$REF" = WORKTREE ] && echo HEAD || echo "$REF")")$([ "$REF" = WORKTREE ] && echo +wt)-$(git rev-parse --short=7 HEAD)$(git diff --quiet -- runtime scripts launcher || echo -dirty)-$(date +%Y%m%d.%H%M)" > "$R/VERSION"   # the date: a new app always installs its tools into the game folder (nx_build.py copy_tree)
find "$R" -name __pycache__ -prune -exec rm -rf {} +
echo "runtime bundle: $R ($(du -sh "$R" | cut -f1)), version $(cat "$R/VERSION")"
