#!/usr/bin/env python3
"""The launcher's Play: refreshes the resolution patch table from the player's packs, then becomes the game (exec).

Usage: nx_play.py --game <game folder> [--res native|1080|1440|2160|2880|4320|3440x1440|6880x2880|<w>x<h>] [--dynres off] [--record <file>] [--env KEY=VALUE ...] [--exe <game program>]

--env: a game-program switch from the launcher's Settings window (DM_* only), applied after the defaults below, so it overrides them.

The packs live in <game folder>/mods (copied there by the launcher). runtime_patches.py turns their .pchtxt files into
patched_vN/main.runtime.tsv in a few seconds; the host applies the rows of the chosen size at start (DM_MP4_RES), so a
new pack or another size never needs a rebuild. The chosen pack's scan-fix cheat goes to <game folder>/cheats.
"""
import argparse, os, re, shutil, subprocess, sys
from pathlib import Path

TITLE, BUILD = '010019A01E2F2000', '8275FBE1EC5191C2'


def newest(folder, pattern):
    found = sorted((p for p in folder.glob(pattern) if p.is_dir()), key=lambda p: p.name)   # folders only (patched_v1.key is a file beside patched_v1)
    return found[-1] if found else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--game', required=True); ap.add_argument('--res', default='native')
    ap.add_argument('--dynres', default=''); ap.add_argument('--record', default='')
    ap.add_argument('--env', action='append', default=[])
    ap.add_argument('--exe', default='')   # the game program inside the launcher's "MP4 Game.app" (Game Mode); build.noindex/tools/dmhost without it
    a = ap.parse_args()
    game = Path(a.game); work = game / 'build.noindex'; repo = game / 'nxnative-runtime'
    host, patched, extract = work / 'tools/dmhost', newest(work, 'patched_v*'), newest(work / 'extract', 'v*')
    for what, p in (('game program', host), ('patched code', patched), ('game data', extract)):
        if not p or not p.exists(): print(f'[RED] the {what} is missing ({p}): build the game first', file=sys.stderr); return 2
    mods = game / 'mods'

    # The patch table, from whatever packs are installed now (an empty table without packs: the game's own size).
    rtp = repo / f'dm/games/{TITLE}/runtime_patches.py'
    env = dict(os.environ, MP4_MODS_DIR=str(mods), PYTHONDONTWRITEBYTECODE='1')
    if re.fullmatch(r'\d{3,5}x\d{3,5}', a.res): env['MP4_RES_EXTRA'] = a.res   # a size outside the table's list: its rows are made now (res_sites.py)
    r = subprocess.run([sys.executable, str(rtp), str(extract / 'ExeFS/main'), str(patched / 'main.patched.bin'), str(patched / 'main.runtime.tsv')],
                       env=env, capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines(): print('[launcher] ' + line, file=sys.stderr)
    if r.returncode: print('[RED] [launcher] the resolution table could not be made; playing at the game\'s own size', file=sys.stderr)

    run = work / 'run'; (run / 'temp').mkdir(parents=True, exist_ok=True)
    save = game / 'user-data/save'; save.mkdir(parents=True, exist_ok=True)
    genv = dict(os.environ)
    for k in ('PYTHONDONTWRITEBYTECODE', 'PYTHONUNBUFFERED', 'PYTHONNOUSERSITE'): genv.pop(k, None)
    genv.update(DM_PAD_MERGE='1', DM_ROOT=str(work), DM_ROMFS=str(extract / 'RomFS.img'), DM_SAVE=str(save), DM_TEMP=str(run / 'temp'),
                DM_PSO_USER=str(run / 'pso_user.tsv'), DM_MSL_DIR=str(work / 'shader/cache'), DM_FONT_DIR=str(work / 'font'),
                DM_NVN_SHMAP=str(repo / f'dm/games/{TITLE}/shader_map.tsv'), DM_LANG='en-US', DM_WINDOW='1', DM_AUDIO='1')
    if a.record: genv['DM_PSO_RECORD'] = a.record
    if a.res != 'native':
        # The size's rows come from the game's own code (runtime_patches.py, res_sites.py) for any size, the scan visor's readback included (2026-11-09): no pack, no cheat
        genv['DM_MP4_RES'] = a.res
    old_cheat = game / 'cheats' / f'{BUILD}.txt'   # a pack's scan-fix cheat an earlier version copied here: inert with our rows, and it made every start report cheats on
    if old_cheat.exists() and 'Fix scan at high res' in old_cheat.read_text(errors='replace'): old_cheat.unlink()
    if a.dynres == 'off': genv['DM_MP4_DYNRES'] = 'off'
    for kv in a.env:   # the Settings window's switches
        k, eq, v = kv.partition('=')
        if eq and re.fullmatch(r'DM_[A-Z0-9_]+', k): genv[k] = v
        else: print(f'[RED] [launcher] ignored setting {kv!r} (KEY=VALUE with a DM_ key)', file=sys.stderr)
    for k in sorted(k for k in genv if k.startswith(('DM_', 'MTL_HUD'))): print(f'[launcher] {k}={genv[k]}', file=sys.stderr)
    os.chdir(run)
    exe = Path(a.exe) if a.exe and os.access(a.exe, os.X_OK) else host
    print(f'[launcher] game program: {exe}', file=sys.stderr)
    os.execve(str(exe), [str(exe), str(patched)], genv)


if __name__ == '__main__':
    sys.exit(main())
