# MP4 nxnative launcher: the app with its own Python, .NET runtime, nx_extract and the nxnative tree inside.
# make app -> launcher/dist/MP4 nxnative.app (copy it to another Mac as it is; it needs Xcode with its Metal Toolchain there).
# W: the M5 Pro's MACDATA, else beside the project (the M4)
W ?= $(if $(wildcard /Volumes/MACDATA),/Volumes/MACDATA/mp4-app.noindex,$(HOME)/Claude/mp4-app.noindex)
.PHONY: python runtime app app-run release
python:
	W=$(W) scripts/make_private_python.sh
runtime:
	W=$(W) scripts/make_runtime.sh
app: runtime
	[ -x "$(W)/python-private/python/bin/python3" ] || W=$(W) scripts/make_private_python.sh
	DEVELOPER=1 RUNTIME="$(W)/Runtime" PYTHON="$(W)/python-private/python" launcher/scripts/make-app.sh release
app-run: app
	open "launcher/dist/MP4 nxnative.app"
# make release: the signed, notarized release (no developer options) in release.noindex/<version>/: the app, the DMG and the update ZIP (scripts/release.sh).
# PUBLISH=1 make release also creates the GitHub release. ALLOW_DIRTY=1 builds from uncommitted launcher / runtime changes (a rehearsal).
release:
	W=$(W) scripts/release.sh
