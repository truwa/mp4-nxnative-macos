#!/bin/sh
# The app's private Python: Astral's standalone CPython 3.13 with the nxnative build's modules (capstone, lz4, fonttools,
# backports.zstd), installed into $W/python-private/python only. Nothing on the system is touched. Downloads are pinned
# by SHA-256. Licences: CPython PSF; capstone BSD; lz4 BSD; fonttools MIT; backports.zstd BSD.
set -eu
W="${W:-$( [ -d /Volumes/MACDATA ] && echo /Volumes/MACDATA/mp4-app.noindex || echo "$HOME/Claude/mp4-app.noindex" )}"
DL="$W/python-dl"; OUT="$W/python-private"
PY_URL='https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.13.18%2B20261026-aarch64-apple-darwin-install_only.tar.gz'
PY_SHA=e5af2fde6a937a0e0c795a0c595c4efb70578d57463a2657c819992b9b9acbac
WHEELS='
backports_zstd-1.8.0-cp313-cp313-macosx_11_0_arm64.whl 4fa862d24b7fb392279a95bc9acc1f0ede8a25de9efbed03fb305ceac2f6abb0
capstone-5.0.9-py3-none-macosx_11_0_arm64.whl fc269c5082e17d7f9f265cd6980e2fdc6ab572df913951d76db0357e06b8001d
fonttools-4.68.0-cp313-cp313-macosx_10_13_universal2.whl f15de48b82a816c72f358e772792801bd3788a156caa76e1806cb0aa8148cd61
lz4-4.4.5-cp313-cp313-macosx_11_0_arm64.whl b424df1076e40d4e884cfcc4c77d815368b7fb9ebcd7e634f937725cd9a8a72a
'
check() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ] || { echo "checksum mismatch: $1" >&2; exit 1; }; }

mkdir -p "$DL/wheels"
[ -f "$DL/cpython.tar.gz" ] || curl -fsSL -o "$DL/cpython.tar.gz" "$PY_URL"
check "$DL/cpython.tar.gz" "$PY_SHA"
rm -rf "$OUT" && mkdir -p "$OUT"
tar -xzf "$DL/cpython.tar.gz" -C "$OUT"
P="$OUT/python"
need=0
for n in $(echo "$WHEELS" | awk 'NF {print $1}'); do [ -f "$DL/wheels/$n" ] || need=1; done
if [ "$need" = 1 ]; then
  PIP_CONFIG_FILE=/dev/null "$P/bin/python3" -I -m pip download --quiet --disable-pip-version-check --no-cache-dir \
    --only-binary=:all: --platform macosx_14_0_arm64 --python-version 3.13 -d "$DL/wheels" \
    backports.zstd==1.8.0 capstone==5.0.9 fonttools==4.68.0 lz4==4.4.5
fi
echo "$WHEELS" | while read -r name sha; do if [ -n "$name" ]; then check "$DL/wheels/$name" "$sha"; fi; done
PIP_CONFIG_FILE=/dev/null "$P/bin/python3" -I -m pip install --quiet --disable-pip-version-check --no-cache-dir --no-index \
  --find-links "$DL/wheels" backports.zstd==1.8.0 capstone==5.0.9 fonttools==4.68.0 lz4==4.4.5
L="$P/lib/python3.13"
rm -rf "$P/include" "$P/share" "$P/lib/pkgconfig" "$P/lib/tcl9" "$P/lib/tcl9.0" "$P/lib/tk9.0" "$P/lib/itcl"* "$P/lib/thread"* \
  "$P/lib/libtcl9.0.dylib" "$P/lib/libtcl9tk9.0.dylib" "$L/lib-dynload/_tkinter"*.so "$L/tkinter" "$L/idlelib" "$L/turtledemo" \
  "$L/turtle.py" "$L/ensurepip" "$L/site-packages/pip" "$L/site-packages/pip-"* "$P/bin/pip"* "$P/bin/idle"* "$P/bin/pydoc"*
find "$P" -name __pycache__ -prune -exec rm -rf {} +
"$P/bin/python3" -I -m compileall -q -j 0 "$L" >/dev/null || true
"$P/bin/python3" -I -c "import lz4.block, capstone, fontTools, backports.zstd"
echo "private Python: $P ($(du -sh "$P" | cut -f1))"
