#!/usr/bin/env python3
"""The launcher's iPad / iPhone build (Game menu > Build for iPad / iPhone…): an unsigned IPA and the game file, in a folder. Experimental.

Usage: nx_build_ios.py --game <game folder> --runtime <Runtime dir> --dest <output folder> [--keys <prod.keys>]

It builds from a finished Mac build in <game folder> (its extracted game files, rewritten code and the two shader tables its full shader build wrote,
c1_full.tsv and cb_extent.tsv) and never touches it: the iOS build runs in <game folder>/ios.noindex/build, which reaches the Mac build's extracted files
and rewritten code by symbolic links and has a shader cache of its own. The iOS shaders are the recorded list (Runtime/recorded_shaders.txt, the Quick
start's, plus the player's own recording when Record shaders is on), about 6,400 shaders: a few minutes. Areas past the list may draw incomplete.
The game file (RomFS.img, ~28 GB) is not in the IPA (--romfs separate): it is put beside it as a hard link (no copy, no space) when the output folder is
on the build's volume, else copied. Signing, installing (AltStore, Sideloadly, SideStore, LiveContainer, Xcode) and copying the game file to the device
are the player's (user, 2026-11-12).

stdout: PROGRESS ios <percent> <text>, RESULT <output folder>, then DONE or ERROR <message>. Everything else goes to stderr (the log).
Needs Xcode with the iOS platform (Xcode > Settings > Components) and its Metal toolchain.
"""
import argparse, json, os, shutil, subprocess, sys, time
from pathlib import Path

TITLE = '010019A01E2F2000'
IPA_NAME = 'Metroid Prime 4 Beyond.ipa'
BUNDLE_ID = 'local.mp4nxnative.ipad'   # the one the 2026-11-12 trial used; sideloading tools usually sign it under an ID of their own


def out(line): print(line, flush=True)
def log(line): print(line, file=sys.stderr, flush=True)


def ios_tools_ok():
    """The iOS SDK and its Metal compiler: None when both answer, else what to install"""
    def ok(cmd):
        try: return subprocess.run(cmd, capture_output=True, text=True, timeout=120).returncode == 0
        except (OSError, subprocess.TimeoutExpired): return False
    if not ok(['/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-path']):
        return 'Xcode\'s iOS platform is not installed. Open Xcode > Settings > Components and install iOS, then build again.'
    if not ok(['/usr/bin/xcrun', '--sdk', 'iphoneos', 'metal', '--version']):
        return 'Xcode\'s Metal toolchain for iOS is missing. Open Xcode > Settings > Components and install the Metal Toolchain, then build again.'
    return None


def link_mac_build(work, iwork):
    """The iOS work folder reaches the Mac build's extracted game files and rewritten code by symbolic links (nothing copied, nothing of the Mac build changed):
    build_ipa_from_nsp.py reuses them by their keys, as it would in the Mac build's own folder"""
    iwork.mkdir(parents=True, exist_ok=True)
    for name in ['extract'] + sorted(p.name for p in work.glob('patched_v*') if p.is_dir()):
        src, dst = work / name, iwork / name
        if dst.is_symlink() and dst.resolve() == src.resolve(): continue
        if dst.is_symlink() or dst.is_file(): dst.unlink()
        elif dst.exists(): shutil.rmtree(dst)
        dst.symlink_to(src)
    for k in work.glob('patched_v*.key'): shutil.copy2(k, iwork / k.name)


def place_romfs(src, dest):
    """The game file beside the IPA: a hard link on the same volume (instant, no space), else a copy (~28 GB)"""
    dst = dest / 'RomFS.img'
    if dst.exists():
        if os.path.samefile(src, dst): return 'linked'
        dst.unlink()
    try: os.link(src, dst); return 'linked'
    except OSError as e: log(f'game file: no hard link ({e}); copying it')
    out('PROGRESS ios 96 Copying the game file (about 28 GB) into the output folder')
    tmp = dst.with_suffix('.img.part'); shutil.copyfile(src, tmp); tmp.rename(dst)
    return 'copied'


README = """MP4 nxnative – iPad / iPhone build (experimental)

What is here
- {ipa}: the game as an unsigned app (no game files inside).
- RomFS.img: the game files (about 28 GB). They go onto the device separately.

What you need
- An iPad or iPhone with an Apple M1 / A17 Pro or later chip and 8 GB of memory, iPadOS / iOS 26 or later. Tested: iPad Air M2 (8 GB),
  60 fps in the first areas. Other devices are untested.
- A sideloading tool that signs the app for your device (AltStore, SideStore, Sideloadly, LiveContainer) or your own Xcode signing.
- Free space on the device for the game file (about 30 GB).

Steps
1. Sign and install the IPA with your tool. Keep the increased-memory-limit entitlement if your tool asks.
2. Open the app once (it says the game files are missing), then close it.
3. Put RomFS.img into the app's folder: Files app > On My iPad (or iPhone) > the game's folder. What worked: copy RomFS.img to an
   external SSD (APFS or exFAT), plug it into the iPad and MOVE the file in the Files app (copy/paste needs twice the space).
4. Open the app again.

Limits
- Only the shaders of the recorded playthroughs are in this build (about {n:,}). Areas past them may draw incomplete or stutter.
- Experimental: no support for signing, installing or copying the file. Saves stay on the device.
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--game', required=True); ap.add_argument('--runtime', required=True); ap.add_argument('--dest', required=True)
    ap.add_argument('--keys')
    a = ap.parse_args()
    game, rt, dest = Path(a.game), Path(a.runtime), Path(a.dest)
    work, repo, iroot = game / 'build.noindex', game / 'nxnative-runtime', game / 'ios.noindex'
    iwork = iroot / 'build'

    out('PROGRESS ios 0 Checking the Mac build and Xcode')
    try: ready = json.loads((game / 'ready.json').read_text())
    except (OSError, ValueError): out('ERROR Build the game for the Mac first: the iPad build uses its game files and shader tables.'); return 1
    if ready.get('partial') or ready.get('test'):
        out('ERROR The Mac build is not finished yet. The iPad build needs the finished Mac build (its full shader step writes two tables the iPad build uses).'); return 1
    ver = (rt / 'VERSION').read_text().strip() if (rt / 'VERSION').exists() else '?'
    if ready.get('runtime') != ver:
        out('ERROR The Mac build was made with another app version. Open the Play window once (it updates the game program), then build for iPad again.'); return 1
    prof = repo / 'dm/games' / TITLE
    if not (prof / 'c1_full.tsv').is_file() or not (prof / 'cb_extent.tsv').is_file():
        out('ERROR The Mac build has no shader tables (c1_full.tsv, cb_extent.tsv). Build the Mac game again with Rebuild, then build for iPad.'); return 1
    if not (game / 'inputs').is_dir(): out('ERROR The Mac build\'s game files (inputs) are missing. Build the Mac game again.'); return 1
    if (msg := ios_tools_ok()): out('ERROR ' + msg); return 1
    recorded = rt / 'recorded_shaders.txt'
    if not recorded.is_file(): out('ERROR This app has no list of recorded shaders (recorded_shaders.txt).'); return 1

    sys.path.insert(0, str(rt)); import nx_build
    keys_file = nx_build.merged_recording(recorded, game, repo)   # the app's list plus the player's own recording (Record shaders), as the Mac quick start takes
    n = sum(1 for l in Path(keys_file).read_text().splitlines() if l and not l.startswith('#'))
    link_mac_build(work, iwork)
    dest.mkdir(parents=True, exist_ok=True)
    (iroot / 'logs').mkdir(parents=True, exist_ok=True)

    py = sys.executable
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([str(rt / 'bin'), str(rt / 'dotnet'), '/usr/bin', '/bin', '/usr/sbin', '/sbin'])
    env.update(DM_TOOLS_FIRST='1', DOTNET_ROOT=str(rt / 'dotnet'), DOTNET_NOLOGO='1', DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
               DM_NX_EXTRACT_PREBUILT=str(rt / 'nx_extract'), PYTHONDONTWRITEBYTECODE='1',
               DMSH_KEYS_FILE=str(keys_file), DM_PARTIAL_SHADERS='1', DMSH_PROCS=str(os.cpu_count() or 8))
    ipa = dest / IPA_NAME
    cmd = [py, '-u', str(repo / 'scripts/build_ipa_from_nsp.py'), str(game / 'inputs'), '--platform', 'ios', '--romfs', 'separate',
           '--work-dir', str(iwork), '--title-id', TITLE, '--bundle-id', BUNDLE_ID, '--progress', 'json', '--allow-other-metal', '-o', str(ipa)]
    if a.keys: cmd += ['-k', a.keys]
    log('$ ' + ' '.join(cmd))
    log(f'iOS shaders: the recorded list, {n:,} shaders ({keys_file})')
    t0 = time.time()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, cwd=str(repo), bufsize=1)
    last_red = None; k_n = (0, 1)
    for line in p.stdout:
        line = line.rstrip('\n')
        try: ev = json.loads(line) if line.startswith('{') else None
        except ValueError: ev = None
        if not ev: log(line); continue
        k = ev.get('ev')
        if k == 'stage':
            k_n = (int(ev.get('k') or 0), int(ev.get('n') or 1))
            log(f"[{ev.get('k')}/{ev.get('n')}] {ev.get('name')}" + (f" · {ev['step']}" if ev.get('step') else ''))
            out(f"PROGRESS ios {min(95, 95 * max(0, k_n[0] - 1) // max(1, k_n[1]))} {ev.get('name')}")
        elif k == 'progress':
            frac = ev.get('frac') or 0
            pct = min(95, int(95 * (max(0, k_n[0] - 1) + frac) / max(1, k_n[1])))
            det = ev.get('name') or ev.get('step') or ''
            if ev.get('done') is not None and ev.get('total') and ev.get('unit') != 'B': det += f": {ev['done']:,} of {ev['total']:,}"
            out(f'PROGRESS ios {pct} {det}'.rstrip())
        elif k == 'stage_end':
            log(f"{'✓' if ev.get('ok', True) else '✗'} {ev.get('name')} ({ev.get('elapsed', 0):.0f} s)" + (f": {ev['summary']}" if ev.get('summary') else ''))
        elif k == 'say':
            msg = ev.get('msg', ''); log(msg)
            if '[RED]' in msg: last_red = msg.replace('[RED]', '').strip()
        else: log(line)
    code = p.wait()
    if code != 0 or not ipa.is_file():
        out('ERROR ' + (last_red or f'The iPad build stopped (code {code}). The details have the reason.')); return code or 1
    try: ipa.with_name(ipa.name + '.idx').unlink()   # build_ipa_from_nsp.py's re-pack index: a faster next pack only (5 s without it), clutter in the player's folder
    except OSError: pass
    romfs = sorted((work / 'extract').glob('v*/RomFS.img'))
    if not romfs: out('ERROR The game file (RomFS.img) of the Mac build is missing.'); return 1
    how = place_romfs(romfs[-1], dest)
    (dest / 'READ ME – iPad.txt').write_text(README.format(ipa=IPA_NAME, n=n))
    log(f'iPad build: {ipa} ({ipa.stat().st_size / 1e6:.0f} MB), game file {how}, {time.time() - t0:.0f} s')
    out(f'RESULT {dest}')
    out('PROGRESS ios 100 Done'); out('DONE')
    return 0


if __name__ == '__main__':
    sys.exit(main())
