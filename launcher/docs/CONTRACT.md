# Launcher ↔ runtime contract

The launcher (this repository) and the runtime bundle (built by `mp4-native` with `make dist`) agree on the following.

## Runtime bundle layout

```
Runtime/
  VERSION                  one line, the runtime version
  bin/mp4-native           the game binary (Apple silicon)
  bin/...                  other tools
  scripts/build_game.py    the one-command build
  requirements.txt         Python modules the build needs (cryptography, lz4, capstone)
  shader-seed/             shaders gathered from play; the build copies it to <cache>/build/shader-seed
                           and the game imports it into its cache at the next start
```

Default location: `Runtime/` next to the app bundle during development, inside the app's `Contents/Resources/` later. Overridable in Locations.

## Build

```
<python> Runtime/scripts/build_game.py --base <xci|nsp> --update <nsp> --keys <prod.keys> --out <cache dir> --runtime <Runtime dir>
```

- `<python>` is the interpreter chosen in Locations (default: the first of `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, `/usr/bin/python3` that exists). It must have the modules in the bundle's `requirements.txt`; bundling Python is a later step.
- Working directory: the runtime bundle folder. `PYTHONUNBUFFERED=1` is set.
- stdout, one line each: `PROGRESS <step-id> <percent 0-100> <free text>`; finally `DONE` or `ERROR <message>`.
- stderr is shown in the build log unparsed.
- Exit code 0 on success. On `ERROR` the launcher shows `<message>` verbatim.
- Writes `<cache dir>/ready.json` (`title_id`, `version`, `timestamp`) when complete. The launcher treats its presence as "built".
- Copies the game binary to `<cache dir>/build/mp4-native`: the runtime finds its tools relative to its own location, so Play runs this copy, not the one in the bundle.
- Resumable: running it again skips finished steps. Cancel sends SIGTERM, then SIGKILL after 3 s.

## Launch

- Working directory: `<cache dir>`.
- Command: `<cache dir>/build/mp4-native rewritten/v110 boot`.
- stderr (and stdout) are captured to `<cache dir>/logs/<yyyy-MM-dd_HH-mm-ss>.log` and shown in the Play screen.
- Saves: `<cache dir>/user-data/` (created before launch).

### Environment

| Variable | Value |
| --- | --- |
| `TOTK_GPU_ALLOW_SUBMIT` | always `1` |
| `TOTK_EXP_SKIP_FS` | bloom off: `874337db`; fog off: `c5d25ba7,767b6c39`; both off: `874337db,c5d25ba7,767b6c39`; both on: unset |
| `TOTK_OVERLAY` | overlays off: `0`; on: unset (the runtime may not honour this yet) |
| `TOTK_MFX_UPSCALE`, `TOTK_MFX_OUTPUT` | Picture = MetalFX: both `1` (the runtime upscales the final picture to the window); Plain: unset |

There is no render-size setting: the game renders at its own 1600x900 (`MP4_RENDER_SIZE` was removed from the runtime).

## Cache folder

Default `~/Library/Application Support/MP4 Launcher/<title id>/` (Metroid Prime 4: `010019A01E2F2000`). Overridable root in Locations.

## Testing without the runtime

`Testing/FakeRuntime/` is a runtime bundle whose `build_game.py` prints the contract (set `FAKE_BUILD_FAIL=1` to test the error path) and whose `bin/mp4-native` logs to stderr and exits after a few seconds. Point Locations → Runtime bundle at it.

## Planned for 0.2: background shader preparation

After a successful build the launcher should run

```
<python> Runtime/scripts/prepare_shaders.py --game-root <cache dir> --background
```

(in the bundle from VERSION 4844514). It uses `<cache dir>/build/mp4-native`, opens no window and runs no game code, resumes if stopped, needs about 18 GB free on the cache's disk, and takes roughly 20 min of translation plus about 2 hours of compiling at low priority. Results: `<cache dir>/shader-prep/run-<settings>/report.json`. The game stays playable while it runs. The launcher should show it as a progress line, let the user pause it, and warn about disk space. Not implemented in 0.1.

### Implemented in 0.2 (launcher side)

- Runs `<python> -c "<setpgrp + exec>" Runtime/scripts/prepare_shaders.py --game-root <cache dir> --background` with cwd = runtime bundle, `PYTHONUNBUFFERED=1`, in its own process group so Pause (SIGSTOP), Resume (SIGCONT) and Stop (SIGTERM, SIGKILL after 5 s) reach the translator and compiler children. The launcher sends SIGTERM when it quits; the script resumes on the next run.
- Progress parsed from stdout: `[translate] <i>/<n>` maps to 0–15 %, `[compile] <i>/<n>` to 15–100 %, `[report]` means finished. A stderr line containing `GiB needed` is shown as the failure. Other lines are only logged.
- Before starting, the launcher requires 18 GB free on the cache's volume. It starts automatically after a successful build unless a game is running from the launcher; the Play screen has Prepare shaders / Pause / Resume / Stop and shows "Shaders: preparing 42 %", "paused", "prepared".
- "Prepared" is true when `<cache dir>/build/shader-cache/rt-<chain>/prepared.json` exists (its `translated` and `compiled` counts are shown) or when the newest `<cache dir>/shader-prep/run-*/report.json` has no `not done` entries. A prepared cache offers the job as "Refresh" only and never auto-starts it.
- The launcher never deletes or replaces anything in the cache: `build/shader-cache`, `build/shader-libs` and the tools in `build/` are owned by the build and the game. Rebuild only reruns `build_game.py`, whose tools step overwrites tools with byte-identical copies.
