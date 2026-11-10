#!/usr/bin/env python3
"""The launcher's build speed test: compiles a sample of the game's shaders and projects the full build's time on this Mac.

Usage: nx_speedtest.py --game <game folder> [--player] [--share S] [--procs 0,N] [--priority normal|utility|background] [--abba] [--warm]
       nx_speedtest.py --game <game folder> --in-build    the build's own estimate (nx_build.py, every fresh build): a player run whose sample goes into the
                                                          build's compile cache (build.noindex/shader/cache/cas.db), so the build restores it instead of compiling it again
       nx_speedtest.py --game <game folder> --check      prints VALID <json> (an estimate or a finished build's real times for this Mac and builder) or NONE

--player (the app's default): one cold run with a worker process per core, a sample sized for under three minutes on this Mac. The developer options (several
process counts, threads only as 0, A-B-B-A order, --warm for the measured cold + warm pair) are for testing the builder.
Needs the split shader packages (<game folder>/build.noindex/shader/pkg); when they are missing, nx_build.py --until-split makes them first (under a minute: the game
data, the rewrite and the split, all reused by the build later). The builder measured is this app's (the nxnative tree beside this script, copied into the scratch folder).
stdout: STEP <text>, PROGRESS <run> <runs> <label> <done> <total> <seconds>, RESULT <json>, then DONE or ERROR <message>. Everything else goes to stderr.

Method (2026-11-08): a stratified sample, the same share of each shader stage as the full map has (dmsh_build.py adds the pixel shaders a sampled vertex shader pairs with).
A cold run compiles every library of the sample; a warm run (the same shaders again with only the Metal compile results kept) measures the rest: translation, rewrites, packing.
A small sample compiles about 1.1 Metal libraries per shader, a full build far fewer (0.25 on the M4: 64,404 for 259,989 shaders, the rest reused within the build), so:
    full = CALIB x [ (shaders in the map / shaders in the sample) x warm  +  (REF_COMPILES / compiles in the sample) x (cold - warm) ]
The player test does not run warm: warm = WARM_RATIO x cold (0.215 on the M4 in both measured pairs, 1% and 0.5%). CALIB brings the formula to the M4's real full build
(the shader step 6,832 s against 5,161 s and 5,272 s projected: the shader step's finishing and the full build's slower late compiles, which a sample does not see).
Pipelines from the M4's measured rate scaled by cores; the game program ~30 s. Each result carries a fingerprint (fingerprint()): an estimate counts only for the same Mac,
builder speed version, shader chain, Metal compiler and process setting; a finished build's real times (logs/build-real.json, nx_build.py) win over any estimate.
"""
import argparse, glob, json, os, random, re, resource, shutil, sqlite3, subprocess, sys, threading, time
from pathlib import Path

TITLE = '010019A01E2F2000'
SPEED_VERSION = 2            # raised only by builder changes that change its speed (2: worker processes, upstream's storage, 2026-11-08)
REF_COMPILES = 64_404        # Metal libraries a full build of chain 37549ec5bddd compiles (M4, 2026-11-08)
WARM_RATIO = 0.215           # warm / cold on the M4 (2026-11-08: 43.3 / 195.9 at 1%, 22.5 / 104.6 at 0.5%)
CALIB = 1.31                 # the M4's real shader step / the formula's projection (2026-11-08)
REF_PAIRS, REF_PAIR_S, REF_PAIR_CORES = 129_972, 2_637, 10   # the pipeline prebuild on the M4 (2026-11-08): 129,972 pairs in 2,637 s on 10 cores
HOST_S = 30


def out(line): print(line, flush=True)
def log(line): print(line, file=sys.stderr, flush=True)


def sysctl(name):
    try: return subprocess.run(['/usr/sbin/sysctl', '-n', name], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError): return ''


def fingerprint(repo, procs):
    """What an estimate holds for: this Mac, this builder's speed, its shader chain, the Metal compiler, the process setting"""
    try: chain = re.search(r'#define DMSH_CHAIN "([0-9a-f]+)"', (repo / 'dm/gfx/nvn/dmsh_chain.h').read_text()).group(1)
    except (OSError, AttributeError): chain = '?'
    try: metal = subprocess.run(['/usr/bin/xcrun', 'metal', '--version'], capture_output=True, text=True, timeout=30).stdout.splitlines()[0].strip()
    except (OSError, subprocess.SubprocessError, IndexError): metal = '?'
    return {'mac': sysctl('hw.model'), 'p_cores': sysctl('hw.perflevel0.logicalcpu'), 'e_cores': sysctl('hw.perflevel1.logicalcpu'), 'memory': sysctl('hw.memsize'),
            'speed_version': SPEED_VERSION, 'chain': chain, 'metal': metal, 'procs': 'threads' if procs == 0 else 'processes'}


def player_share(cores):
    """The player test's and the build's own sample: 0.5% (user decision 2026-11-08: 0.5% and 0.8% gave the same projection on the M4, within a minute;
    ~100 s of cold run on the M4's 10 cores)"""
    return 0.5


in_build_share = player_share


def sample(repo, share, seed=8):
    """A stratified sample of the shader map's keys: the same share of each stage"""
    by_stage = {}
    for ln in (repo / f'dm/games/{TITLE}/shader_map.tsv').read_text(errors='replace').splitlines():
        c = ln.split('\t')
        if ln.startswith('#') or len(c) < 4 or not re.fullmatch(r'[0-9a-f]{16}', c[3]): continue
        by_stage.setdefault(c[2], []).append(c[3])
    rng, keys = random.Random(seed), []
    for stage, ks in sorted(by_stage.items()):
        n = max(1, round(len(ks) * share / 100))
        keys += rng.sample(sorted(set(ks)), min(n, len(set(ks))))
    return keys, sum(len(set(v)) for v in by_stage.values())


def run_build(repo, py, pkg, scratch, keys_file, procs, priority, env0, tick, cas=None):
    """One dmsh_build.py run of the sample into scratch/out with the cache scratch/cas.db (or cas: the build's own, --in-build) → (wall s, CPU s of its processes, shaders, Metal compiled, Metal reused).
    The per-shader cache key holds no paths (dmsh_build.py shader_key), so what the sample compiled into the build's cache is restored by the build
    tick(done, total, seconds) every second from dmsh_build.py's progress file"""
    prog = scratch / 'progress.json'
    env = dict(env0, DM_GAME=TITLE, DM_ROOT=str(scratch), WORK=str(scratch / 'work'), DMSH_CAS=str(cas or scratch / 'cas.db'), DMSH_TARGETS='mac',
               DMSH_KEYS_FILE=str(keys_file), DMSH_PROCS=str(procs), J=str(os.cpu_count() or 8), PYTHONDONTWRITEBYTECODE='1', DMSH_PROGRESS=str(prog),
               XLATE=str(repo / 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate'))
    (scratch / 'work').mkdir(parents=True, exist_ok=True); shutil.rmtree(scratch / 'out', ignore_errors=True)
    try: prog.unlink()
    except FileNotFoundError: pass
    wrap = [] if priority == 'normal' else ['/usr/sbin/taskpolicy', '-c', priority]
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN); t0 = time.time()
    with open(scratch / 'last.log', 'w') as lf:
        p = subprocess.Popen([*wrap, py, str(repo / 'dm/gfx/tools/own_compilers.py'), str(pkg), str(scratch / 'out')], env=env, cwd=str(repo), stdout=subprocess.PIPE, stderr=lf, text=True)
        lines = []
        def reader():
            for ln in p.stdout: lines.append(ln)
        th = threading.Thread(target=reader, daemon=True); th.start()
        while p.poll() is None:
            try: pr = json.loads(prog.read_text()); tick(int(pr.get('done') or 0), int(pr.get('total') or 0), time.time() - t0)
            except (OSError, ValueError): tick(0, 0, time.time() - t0)
            time.sleep(1)
        th.join(5)
    wall = time.time() - t0; r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)
    stdout = ''.join(lines)
    with open(scratch / 'last.log', 'a') as lf: lf.write(stdout)
    if p.returncode: raise RuntimeError(f'the shader build stopped ({p.returncode}): ' + ((stdout + (scratch / 'last.log').read_text(errors='replace')).strip().splitlines() or ['?'])[-1][:200])
    m = re.search(r'^shaders (\d+): ok', stdout, re.M); c = re.search(r'Metal cache: mac (\d+) reused, (\d+) compiled', stdout)
    return wall, cpu, int(m.group(1)) if m else 0, int(c.group(2)) if c else 0, int(c.group(1)) if c else 0


def keep_metal_only(db):   # the warm run's cache: the Metal compile results only (the per-shader entries would restore whole shaders and skip the work measured)
    c = sqlite3.connect(str(db), timeout=600, isolation_level=None)
    try: c.execute("DELETE FROM entry WHERE name NOT LIKE 'metallib/%'")
    finally: c.close()


def project(total, n, comp, cold, warm):
    return CALIB * ((total / max(1, n)) * warm + (REF_COMPILES / max(1, comp)) * max(0.0, cold - warm))


def pipelines_s(cores): return REF_PAIRS / (REF_PAIRS / REF_PAIR_S * cores / REF_PAIR_CORES)


def check(game, repo):
    """The newest valid estimate or real build for this Mac and builder: real times (logs/build-real.json) first, then the newest speed test not marked stale"""
    want = {k: v for k, v in fingerprint(repo, os.cpu_count()).items() if k != 'procs'}
    def same(fp): return fp and all(fp.get(k) == v for k, v in want.items())
    real = game / 'logs/build-real.json'
    try:
        r = json.loads(real.read_text())
        if same(r.get('fingerprint')): return {'kind': 'real', **r}
    except (OSError, ValueError): pass
    for f in sorted(glob.glob(str(game / 'logs/speedtest-*.json')), reverse=True):
        try: r = json.loads(Path(f).read_text())
        except (OSError, ValueError): continue
        if r.get('priority', 'normal') != 'normal': continue   # a comparison at another priority (the background class ran 7x slower, 2026-11-09) is not the build's estimate
        if same(r.get('fingerprint')) and not r.get('stale'): return {'kind': 'test', 'file': f, **r}
    return None


def make_split(game, rt):
    """The split shader packages through the build's own first steps (nx_build.py --until-split), reused by the build later"""
    cmd = [sys.executable, '-E', '-s', str(rt / 'nx_build.py'), '--out', str(game), '--runtime', str(rt), '--until-split']
    if (game / 'keys/prod.keys').is_file(): cmd += ['--keys', str(game / 'keys/prod.keys')]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
    err = None
    for ln in p.stdout:
        if ln.startswith('PROGRESS '): out('STEP Preparing: ' + ln.split(' ', 3)[3].strip())
        elif ln.startswith('ERROR '): err = ln[6:].strip()
    p.wait()
    return err


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--game', required=True); ap.add_argument('--share', type=float)
    ap.add_argument('--procs'); ap.add_argument('--priority', choices=('normal', 'utility', 'background'), default='normal')
    ap.add_argument('--abba', action='store_true'); ap.add_argument('--warm', action='store_true', help='measure the warm run instead of the calibrated ratio')
    ap.add_argument('--player', action='store_true'); ap.add_argument('--check', action='store_true')
    ap.add_argument('--in-build', action='store_true', help="the build's own estimate: a player run into the build's compile cache")
    ap.add_argument('--runtime', default=str(Path(__file__).resolve().parent / 'nxnative'), help="the nxnative tree to measure (default: this app's)")
    a = ap.parse_args()
    game, rt_tree = Path(a.game), Path(a.runtime)
    cores = os.cpu_count() or 8
    if a.check:
        r = check(game, rt_tree)
        out('VALID ' + json.dumps(r) if r else 'NONE'); return 0
    pkg = game / 'build.noindex/shader/pkg'
    if not (pkg.is_dir() and any(pkg.iterdir())):
        out('STEP Preparing the split shaders (under a minute; the build reuses them)')
        err = make_split(game, Path(__file__).resolve().parent)
        if err or not (pkg.is_dir() and any(pkg.iterdir())): out(f'ERROR {err or "The split shaders could not be made"}'); return 1
    cas = None
    if a.in_build:
        a.player = True; a.share = a.share or in_build_share(cores)
        cas = game / 'build.noindex/shader/cache/cas.db'; cas.parent.mkdir(parents=True, exist_ok=True)
    if a.player:
        share, procs, warm_runs, order = a.share or player_share(cores), [cores], False, [cores]
    else:
        share = a.share or 1.0
        procs = [int(x) for x in (a.procs or f'0,{cores}').split(',') if x.strip()]
        warm_runs = a.warm
        order = procs + procs[::-1] if a.abba and len(procs) > 1 else procs
    scratch = game / 'speedtest.noindex'; shutil.rmtree(scratch, ignore_errors=True); scratch.mkdir(parents=True)
    repo = scratch / 'nxnative'
    shutil.copytree(rt_tree, repo, symlinks=True)   # the builder writes beside its scripts; the app bundle stays untouched
    ver = rt_tree.parent / 'VERSION'
    out(f'STEP Builder: {ver.read_text().strip() if ver.is_file() else rt_tree}')
    keys, total = sample(repo, share)
    keys_file = scratch / 'keys.txt'; keys_file.write_text('\n'.join(keys) + '\n')
    out(f'STEP Sample: {len(keys):,} of {total:,} shaders ({share:g}%), ' + ', '.join('threads only' if p == 0 else f'{p} processes' for p in procs) + f', priority {a.priority}'
        + ('' if warm_runs else ', cold runs only (calibrated)'))
    env0 = dict(os.environ, PATH=os.pathsep.join([os.environ.get('PATH', '/usr/bin:/bin'), '/usr/bin', '/bin', '/usr/sbin']))
    runs, nruns = {p: [] for p in procs}, len(order) * (2 if warm_runs else 1)
    k = 0
    try:
        for p in order:
            name = 'threads only' if p == 0 else f'{p} processes'
            for f in scratch.glob('cas.db*'): f.unlink()
            k += 1; kk = k
            cold = run_build(repo, sys.executable, pkg, scratch, keys_file, p, a.priority, env0, lambda d, t, s: out(f'PROGRESS {kk} {nruns} {name}, cold {d} {t} {s:.0f}'), cas)
            warm = None
            if warm_runs:
                keep_metal_only(scratch / 'cas.db')
                k += 1; kk2 = k
                warm = run_build(repo, sys.executable, pkg, scratch, keys_file, p, a.priority, env0, lambda d, t, s: out(f'PROGRESS {kk2} {nruns} {name}, warm {d} {t} {s:.0f}'))
            runs[p].append((cold, warm))
            out(f'STEP {name}: cold {cold[0]:.0f} s ({cold[1]:.0f} CPU s)' + (f', warm {warm[0]:.0f} s' if warm else '') + f', {cold[2]:,} shaders, {cold[3]:,} Metal compiles')
    except RuntimeError as e:
        out(f'ERROR {e}'); return 1
    results = []
    for p, rs in runs.items():
        cold_w = sum(r[0][0] for r in rs) / len(rs)
        warm_w = sum(r[1][0] for r in rs) / len(rs) if rs[0][1] else WARM_RATIO * cold_w
        cold_cpu = sum(r[0][1] for r in rs) / len(rs); n = rs[0][0][2]; comp = max(1, rs[0][0][3])
        results.append({'procs': p, 'label': 'threads only' if p == 0 else f'{p} processes', 'shaders': n, 'metal_compiles': comp, 'cold_s': round(cold_w, 1),
                        'warm_s': round(warm_w, 1), 'warm_measured': bool(rs[0][1]), 'cold_cpu_s': round(cold_cpu, 1), 'shaders_per_min': round(n / cold_w * 60),
                        'projected_shader_s': round(project(total, n, comp, cold_w, warm_w))})
    best = min(results, key=lambda r: r['projected_shader_s'])
    pp = pipelines_s(cores)
    summary = {'mac_cores': cores, 'share': share, 'priority': a.priority, 'total_shaders': total, 'results': results, 'pipelines_estimate_s': round(pp),
               'best': best['label'], 'projected_shader_s': best['projected_shader_s'], 'projected_total_s': best['projected_shader_s'] + round(pp) + HOST_S,
               'fingerprint': fingerprint(rt_tree, best['procs']), 'player': a.player, 'in_build': a.in_build,
               'note': f'calibrated to the M4 build of 2026-11-08 (x{CALIB}); pipelines from its measured rate scaled by cores; the game data steps (~1 min) not included'}
    (game / 'logs').mkdir(exist_ok=True)
    (game / 'logs' / f'speedtest-{time.strftime("%Y%m%d-%H%M%S")}.json').write_text(json.dumps(summary, indent=1))
    out('RESULT ' + json.dumps(summary))
    shutil.rmtree(scratch, ignore_errors=True)
    out('DONE')
    return 0


if __name__ == '__main__':
    sys.exit(main())
