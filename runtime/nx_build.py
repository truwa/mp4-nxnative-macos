#!/usr/bin/env python3
"""The launcher's build: runs nxnative's build_ipa_from_nsp.py (--platform mac) and speaks the launcher's contract.

Usage: nx_build.py --out <game folder> --runtime <Runtime dir> [--base <xci|nsp>] [--update <nsp>] [--keys <prod.keys>]
                   [--storage minimal|normal|full] [--quick-start | --test]

stdout: PROGRESS <step-id> <percent> <text>, then DONE or ERROR <message>; with --quick-start also PLAYABLE once the game can start
(the rest of the shaders then compile at low priority); ETA <seconds> (time left), ELAPSED_BEFORE <seconds> (earlier sessions); on a fresh build
COUNT shaders <done of all> <all> and COUNT pipelines <built> <all> (the whole build's counts, which only grow; every pass), COUNT part <done> <total> (quick start's set);
PHASE estimating, ESTIMATE <seconds> (the whole build, from a sample compiled into the build's own cache), then PHASE building; WAITING 1/0 (the pipelines wait for the game
to close). Everything else goes to stderr (the log).
--storage: what the finished build keeps of the shader work: minimal (only the library image the game reads), normal (also the Metal compile
cache, so a later shader fix recompiles only what changed; the default), full (the whole compile cache, the per-shader entries too).
The shaders are one image, b-<chain>.img, and the compile cache one file, cas.db (nxnative's storage): never hundreds of thousands of small files.
--quick-start: the shaders of the recorded playthrough (Runtime/recorded_shaders.txt, from the start to the Carvex fight) first, then the game
program and its pipelines: playable after that; then every other shader, at utility priority (the game comes first), resuming the first part.
--test: only the recorded shaders (minutes): a test build, normally in a build folder of its own.
The nxnative tree is copied from the app into <game folder>/nxnative-runtime (the build writes into it: the host build),
the build folder is <game folder>/build.noindex. Each stage's time is appended to <game folder>/logs/build-times.tsv.
Stopping is safe: the build continues where it stopped (finished stages and shaders are kept).
"""
import argparse, datetime, json, os, platform, re, shutil, signal, subprocess, sys, threading, time
from pathlib import Path

TITLE = '010019A01E2F2000'
# The launcher's steps: (id, weight in percent of a full build, measured on an M5 Pro), and which nxnative stages belong to each.
STEPS = [('read', 3), ('rewrite', 4), ('split', 3), ('shaders', 72), ('host', 3), ('pipelines', 15)]
STAGE_STEP = {'rewrite': 'rewrite', 'NRO capture': 'rewrite', 'GLSLC capture': 'rewrite', 'JIT capture': 'rewrite', 'heap check': 'rewrite',
              'address regions': 'rewrite', 'UE shader decode': 'rewrite', 'shader split': 'split', 'Mac shaders': 'shaders',
              'Mac host': 'host', 'Pipeline prebuild': 'pipelines', 'Pipeline archive': 'pipelines'}
TEXT = {'read': 'Reading the game files', 'rewrite': 'Rewriting the code for Apple silicon', 'split': 'Splitting the shaders',
        'shaders': 'Compiling the shaders', 'host': 'Building the game program', 'pipelines': 'Preparing the pipelines'}
# The shader step runs three phases, each counting from 0 to its own total (ShaderWatch in build_ipa_from_nsp.py): (part, start and
# share of the step's bar, text). Compiling is by far the longest; the other two used to fill the bar and start it over.
# The shader step translates batch by batch while it compiles: two parts, the cache check and the compile.
SHADER_PHASES = {'cache check': (1, 0.00, 0.02, 'checking the cache'), 'translating': (1, 0.02, 0.03, 'translating'),
                 'compiling': (2, 0.05, 0.95, 'compiling (the long part)'), 'finishing': (2, 0.05, 0.95, 'compiling (the long part)')}


def out(line):
    print(line, flush=True)


def log(line):
    print(line, file=sys.stderr, flush=True)


def copy_tree(src, dst):
    """The app's nxnative tree into the game folder, again only when the app's version changed (the host build's outputs stay)."""
    ver = (src.parent / 'VERSION').read_text().strip() if (src.parent / 'VERSION').exists() else '?'
    stamp = dst / '.launcher-version'
    if stamp.exists() and stamp.read_text().strip() == ver: return
    log(f'installing the build tools {ver} into {dst}')
    # The build's own tables in the game's profile folder (c1_full.tsv, cb_extent.tsv and the like: git ignores them, the app does not carry them) stay: they follow
    # from this build's shaders, and making them again needs the shader sources, which a finished build no longer keeps (slim_library)
    prof, keep = Path('dm/games') / TITLE, {}
    if (dst / prof).is_dir():
        for f in (dst / prof).iterdir():
            if f.is_file() and not (src / prof / f.name).exists(): keep[f.name] = f.read_bytes()
    if dst.exists(): shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)
    for name, data in keep.items(): (dst / prof / name).write_bytes(data)
    if keep: log(f'kept the build\'s own tables: {", ".join(sorted(keep))}')
    stamp.write_text(ver + '\n')


def link_inputs(folder, files):
    """The build takes one folder holding the game's files: links to the player's files (only read, never moved)."""
    if folder.exists(): shutil.rmtree(folder)
    folder.mkdir(parents=True)
    for f in files:
        os.symlink(f, folder / Path(f).name)


def load_profile(rt):
    """runtime/shader-profile.tsv: (progress, share of the shader step's compile time) from a reference build, for TimeLeft"""
    rows = []
    try:
        for ln in (rt / 'shader-profile.tsv').read_text().splitlines():
            if ln and not ln.startswith('#'): a_, b_ = ln.split('\t')[:2]; rows.append((float(a_), float(b_)))
    except (OSError, ValueError): pass
    return rows or [(0.0, 0.0), (1.0, 1.0)]


def share_at(prof, p):
    for (p0, s0), (p1, s1) in zip(prof, prof[1:]):
        if p <= p1: return s0 + (s1 - s0) * ((p - p0) / (p1 - p0) if p1 > p0 else 0)
    return 1.0


class TimeLeft:
    """The whole build's numbers, one set for every pass of a build (the sample, quick start's part, the background part, a continued session), for the
    Build window's whole-build line: the time left (ETA line), shaders done of all (COUNT shaders), pipelines built of all (COUNT pipelines). Rules (todo.md,
    2026-11-09): the counts only grow (the sample's shaders, the quick-start set, cache hits and restored shaders are done the moment they are known); a phase
    with no information (the cache check, the restores at the start of a continued session) holds the last estimate instead of guessing; a partial pass
    (the quick-start set) never uses the full build's reference profile, only the estimate.
    Shaders: the compile time so far (this build's earlier sessions too) over the reference profile's time share at the current progress, so the estimate follows this Mac's
    speed and the profile's shape (slow early, fast reuse late); early on blended with the speed test's projection; plus the step's finishing (~12% of its compile time).
    Pipelines: their live count and rate from the prebuild's log, before that the M4's rate scaled by cores. The game program: ~30 s.
    Every ~30 s the progress goes to logs/shader-progress.tsv (time, shaders done of all, all, restored, compile seconds, time left, pass): the next reference profile"""
    WINDDOWN, HOST_S = 0.125, 30
    PAIRS, PAIR_RATE_PER_CORE = 129_972, 129_972 / 2_637 / 10   # the M4's prebuild, 2026-11-08
    def __init__(self, work, logs, rt, repo, speed_s=None, speed_file=None):
        self.prog, self.pso, self.rec = work / 'shader/progress.json', work / 'logs/pso_prebuild.log', logs / 'shader-progress.tsv'
        self.prof, self.speed_s, self.speed_file = load_profile(rt), speed_s, speed_file
        self.full = 0        # every shader of the game (the split's count)
        self.whole = 0       # shaders done of the whole build: only grows
        self.base = 0        # shaders finished by this session's earlier partial passes (the sample, the quick-start set)
        self.partial = False # the current pass builds a part: the estimate only, no profile
        self.pipes = 0       # pipeline bases built or archived: only grows
        self.pairs_total = 0
        try:
            for f in ('shader_pairs.tsv', 'pso_pairs.tsv'):
                t = repo / f'dm/games/{TITLE}/{f}'
                if t.is_file(): self.pairs_total += sum(1 for ln in t.read_text(errors='replace').splitlines() if ln and not ln.startswith('#'))
        except OSError: pass
        if not self.pairs_total: self.pairs_total = self.PAIRS
        self.prior, self.floor, self.held = 0.0, None, None
        try:   # this build's earlier sessions: compile seconds, shaders done of all, the last time left
            last = [ln for ln in self.rec.read_text().splitlines() if ln and not ln.startswith('#')][-1].split('\t')
            self.prior = float(last[4]); self.floor = (int(last[1]), int(last[2]))
            if len(last) > 5 and last[5]: self.held = (float(last[5]), time.time())
        except (OSError, IndexError, ValueError): pass
        self.pipelines()   # an earlier session's prebuild (quick start's set): its bases count
        self.compile_s, self.last_t, self.last_rec, self.stale_checked = 0.0, None, 0.0, False
        self.done = self.total = self.cached = 0; self.step = None
        # The shader step counts hits and misses alike, in key order (progress.json: done, cached = hits in all, total). The hits passed so far (h) are estimated:
        # a fast stretch (hundreds a second: a continued session re-registering its finished shaders) is all hits, a slow one carries the remaining hits' density
        self.h, self.prev_done, self.rate_t, self.rate_done, self.fast = 0.0, 0, None, 0, False
        self.lock = threading.Lock()
    def set_full(self, n):
        with self.lock:
            self.full = n
            if self.floor and self.floor[1] == n: self.whole = max(self.whole, min(self.floor[0], n))   # a continued session starts where the last one stood
    def restoring(self):   # the start of a continued session: cache hits are re-registered at ~400/s, no Metal compile (a compile runs at ~25/s)
        return self.step == 'compiling' and self.fast
    def poll(self):
        now = time.time()
        try: pr = json.loads(self.prog.read_text())
        except (OSError, ValueError): pr = None
        with self.lock:
            step = pr.get('step') if pr else None
            if step != 'compiling' or self.step != 'compiling': self.h, self.prev_done, self.rate_t, self.rate_done, self.fast = 0.0, 0, None, 0, False   # a new count starts
            if pr: self.step, self.done, self.total, self.cached = step, int(pr.get('done') or 0), int(pr.get('total') or 0), int(pr.get('cached') or 0)
            else: self.step, self.done, self.total, self.cached = None, 0, 0, 0
            if self.step == 'compiling':
                if self.rate_t is None or now - self.rate_t >= 10:   # restores run at 400-500/s, a compile at 25-50/s (bursts of a batch included)
                    if self.rate_t is not None: self.fast = (self.done - self.rate_done) / (now - self.rate_t) > 150 and self.cached - self.h >= 1000
                    self.rate_t, self.rate_done = now, self.done
                d = self.done - self.prev_done
                if d > 0:
                    self.h += d if self.fast else d * max(0.0, self.cached - self.h) / max(1, self.total - self.prev_done)
                    self.prev_done = self.done
            if self.step == 'cache check': cand = self.base + self.cached if self.partial else self.cached   # the hits found so far are done shaders
            elif self.step in ('compiling', 'finishing'):
                cand = self.base + self.done if self.partial else max(self.cached, min(self.cached + self.done - int(self.h), self.cached + self.done, self.total))
            else: cand = 0
            if self.full: cand = min(cand, self.full)
            self.whole = max(self.whole, cand)
            if self.step in ('compiling', 'finishing') and not self.restoring():
                if self.last_t: self.compile_s += min(now - self.last_t, 30)   # a pause (SIGSTOP) or a stall is not compile time
                self.last_t = now
            else: self.last_t = None
            if self.full and now - self.last_rec >= 30 and self.step in ('compiling', 'finishing'): self.record(now)
    def record(self, now=None):
        """One row of logs/shader-progress.tsv: the whole build's state (also at a stop and at the end of a pass, so the next session starts where this one stood)"""
        now = now or time.time()
        if not self.full: return
        self.last_rec = now
        try:
            if not self.rec.exists(): self.rec.write_text('# time\tdone\ttotal\trestored\tcompile_s\teta\tpass\n')
            eta = f'{self.held[0]:.0f}' if self.held else ''
            with self.rec.open('a') as f: f.write(f'{now:.0f}\t{self.whole}\t{self.full}\t{self.cached}\t{self.prior + self.compile_s:.0f}\t{eta}\t{"part" if self.partial else "full"}\n')
        except OSError: pass
    def end_pass(self):
        """A partial pass is over: its shaders stay counted; its prebuild's final count is read"""
        with self.lock: self.base = self.whole
        self.pipelines(); self.record()
    def pipelines(self):
        """(seconds left, pairs walked, pairs) of the pipeline prebuild from its log, or None before it runs; keeps the count of bases built or archived (self.pipes)"""
        try:
            with open(self.pso, 'rb') as f:
                f.seek(0, 2); f.seek(max(0, f.tell() - 8192)); tail = f.read().decode(errors='replace')
        except OSError: return None
        m = re.findall(r'pipeline prebuild: (\d+) of (\d+) pairs, (\d+) built, (\d+) already archived.*?, ([\d.]+) s', tail)
        d = re.findall(r'pipeline prebuild done: (\d+) pairs, (\d+) bases built, (\d+) already archived', tail)
        built = max([int(x[2]) + int(x[3]) for x in m] + [int(x[1]) + int(x[2]) for x in d] + [0])
        self.pipes = max(self.pipes, min(built, self.pairs_total))
        if d: return 0.0, int(d[-1][0]), int(d[-1][0])
        if m:
            w, n, s = int(m[-1][0]), int(m[-1][1]), float(m[-1][4])
            return ((n - w) / (w / s) if w and s else None), w, n
        return None
    def shaders_left(self):
        """Seconds left of the shader step, or None when nothing new can be said (the caller holds the last estimate)"""
        with self.lock:
            T = self.prior + self.compile_s
            if self.partial or not self.full:   # a part (quick start's set): the estimate for the whole step, less what was compiled
                return max(0.0, self.speed_s - T) if self.speed_s else None
            p = self.whole / self.full
            if self.step not in ('compiling', 'finishing') or self.restoring() or p <= 0: return None
            sh = share_at(self.prof, p)
            # The profile's estimate needs a footing: 10 minutes of compile time and 5% of the shaders; its weight then grows over the next 20 minutes
            # (at 80 s of compiling it projected 875 s for the whole step, 2026-11-09 simulation: the shaders done so far cost next to no time)
            prof_total = T / sh if sh > 0.02 and T >= 600 and p >= 0.05 else None
            speed_total = self.speed_s / (1 + self.WINDDOWN) if self.speed_s else None   # the speed test projects the whole step, finishing included
            w = min(1.0, p / 0.15) * min(1.0, max(0.0, (T - 600) / 1200))
            if prof_total and speed_total: tot = (1 - w) * speed_total + w * prof_total
            else: tot = prof_total or speed_total
            if tot is None: return None
            if not self.stale_checked and T > 1800 and prof_total and speed_total:
                self.stale_checked = True
                if abs(prof_total - speed_total) / speed_total > 0.25 and self.speed_file:   # the estimate does not hold for this Mac any more: the next build offers a new test
                    try:
                        d = json.loads(Path(self.speed_file).read_text()); d['stale'] = True; Path(self.speed_file).write_text(json.dumps(d, indent=1))
                        log(f'time estimate: the live rate is {prof_total / speed_total:.0%} of the speed test\'s projection: the test is marked stale')
                    except (OSError, ValueError): pass
            return max(0.0, tot - T) + self.WINDDOWN * tot * (1 - min(1.0, p))
    def total_left(self, cur):
        """Seconds left of the whole build (one number for every pass), or None before anything is known"""
        now = time.time()
        cores = os.cpu_count() or 8
        est = self.pairs_total / (self.PAIR_RATE_PER_CORE * cores)
        pl = self.pipelines() if cur == 'pipelines' and not self.partial else None
        if self.partial or cur not in ('host', 'pipelines'):
            sh = self.shaders_left()
            val = None if sh is None else sh + self.HOST_S + est
        elif cur == 'host': val = self.HOST_S + est
        else: val = pl[0] if pl and pl[0] is not None else est
        if val is None:   # nothing new: the last estimate, less the time since; with none yet (a build from before the record had one), the speed test's, less the compile time spent
            if self.held: return max(0.0, self.held[0] - (now - self.held[1]))
            if self.speed_s and self.full: self.held = (max(0.0, self.speed_s - self.prior - self.compile_s) + self.HOST_S + est, now); return self.held[0]
            return None
        self.held = (val, now)
        return val

STALL_S = 300   # no shader finished for this long: is the Metal compiler still there?
TOOLCHAIN_GONE = 'The Metal Toolchain went missing during the build (removed, or Xcode updated). Install it again (Build window: Xcode and Metal), then Continue building: everything done is kept.'


def metal_ok():
    """Whether Xcode's Metal compiler still runs. A toolchain removed during a build left its running compilers spinning forever (2026-11-09: 5 for 9 min, no error)"""
    try: return subprocess.run(['/usr/bin/xcrun', '-sdk', 'macosx', 'metal', '--version'], capture_output=True, timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError): return True   # unsure: let the build go on


def prune_cache(work, storage):
    """What a finished build keeps of its compile cache, <work>/shader/cache/cas.db (nxnative's shader_cache.py: tables entry and blob): minimal removes it, normal keeps only the
    Metal compile results (metallib/...), full keeps everything. Pages given back by SQLite's incremental vacuum, no copy of the file. Returns the bytes freed"""
    db = work / 'shader/cache/cas.db'
    if storage == 'full' or not db.exists(): return 0
    before = sum((db.parent / (db.name + x)).stat().st_size for x in ('', '-wal', '-shm') if (db.parent / (db.name + x)).exists())
    if storage == 'minimal':
        for x in ('', '-wal', '-shm', '-journal'):
            try: (db.parent / (db.name + x)).unlink()
            except FileNotFoundError: pass
        return before
    import sqlite3
    c = sqlite3.connect(str(db), timeout=600, isolation_level=None)
    try:
        c.execute("DELETE FROM entry WHERE name NOT LIKE 'metallib/%'")
        c.execute('DELETE FROM blob WHERE id NOT IN (SELECT blob FROM entry)')
        c.execute('PRAGMA incremental_vacuum').fetchall()   # it frees pages only as its rows are read: without fetchall it gave back nothing (2026-11-08: 8.75 GB kept)
        c.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall()
    finally: c.close()
    after = sum((db.parent / (db.name + x)).stat().st_size for x in ('', '-wal', '-shm') if (db.parent / (db.name + x)).exists())
    return max(0, before - after)


def chain_of(repo):
    m = re.search(r'#define DMSH_CHAIN "([0-9a-f]+)"', (repo / 'dm/gfx/nvn/dmsh_chain.h').read_text()) if (repo / 'dm/gfx/nvn/dmsh_chain.h').is_file() else None
    return m.group(1) if m else None


def slim_library(work, chain, storage, say=log):
    """A finished build's library image without the shader sources (.metal, ~20 GB for this game), which the game never reads, written again with identical files stored
    once (shader_lib.write); full keeps the sources. Only for a finished build: a running or stopped build checks each shader's source to know it is done. Returns bytes freed"""
    if storage == 'full' or not chain: return 0
    img = work / f'shader/cache/b-{chain}.img'
    if not img.is_file(): return 0
    sys.path.insert(0, str(Path(__file__).resolve().parent / 'nxnative/dm/tools'))
    import romfs, shader_lib
    lib = str(img)[:-4]
    with romfs.scandir(str(img)) as it: names = {e.name: e.path for e in it}
    files = {n: p for n, p in names.items() if not n.endswith('.metal')}
    before = img.stat().st_size
    if len(files) == len(names): return 0   # done before
    say(f'library: writing it without the shader sources ({len(names) - len(files):,} of {len(names):,} files), identical files once')
    t0 = time.time()
    shader_lib.write(files, str(img))
    freed = before - img.stat().st_size
    say(f'library: {before / 1e9:.1f} GB → {img.stat().st_size / 1e9:.1f} GB in {time.time() - t0:.0f} s')
    return max(0, freed)


def drop_split(work):
    """The split shader packages (~2 GB): only the shader step reads them; the split makes them again in ~15 s when a build or the speed test needs them"""
    pkg = work / 'shader/pkg'
    if not pkg.is_dir(): return 0
    n = sum(f.stat().st_size for f in pkg.rglob('*') if f.is_file())
    shutil.rmtree(pkg, ignore_errors=True)
    return n


STORAGE_OPT = 1   # ready.json storage_opt: what a finished build's storage went through (1: cache vacuumed, sources left out, identical files once, split packages dropped)


def optimise_storage(game, work, chain, storage, say=log, part=None):
    """Everything a finished build gives back, also for a build an earlier app finished (--optimise). → bytes freed.
    part(text): called as each part starts, so the Build window's caption shows which one runs (user, 2026-11-09: the step looked stuck for 3-4 minutes)"""
    part = part or (lambda t: None)
    # Smallest first, so the library's rewrite (a second image beside the first for a minute) comes when the most is already free: the peak
    part('removing the split shader packages')
    freed = n2 = drop_split(work)
    if n2: say(f'split shader packages removed: {n2 / 2**30:.1f} GB (made again in seconds when needed)')
    if storage != 'full': part('compacting the compile cache (about 2 minutes)')
    n = prune_cache(work, storage); freed += n
    if n: say(f'storage {storage}: {n / 2**30:.1f} GB of the compile cache given back')
    if storage != 'full': part('writing the library without the shader sources (about a minute)')
    freed += slim_library(work, chain, storage, say)
    return freed


def elapsed_before(times):
    """Seconds of this build's earlier sessions: the '# end ... total N s' lines after the last '# finished' (a finished build starts the count again)"""
    s = 0.0
    try:
        for ln in times.read_text().splitlines():
            if ln.startswith('# finished'): s = 0.0
            elif ln.startswith('# end') and (m := re.search(r'total (\d+) s', ln)): s += float(m.group(1))
    except OSError: pass
    return s


LOW_SPACE, RESUME_SPACE = 6 << 30, 10 << 30   # pause below 6 GB free on the build folder's drive, continue from 10 GB


def build_pids():
    """The build's processes: this runner's process group, without this process"""
    me, group = os.getpid(), os.getpgrp()
    r = subprocess.run(['ps', '-A', '-o', 'pid=,pgid='], capture_output=True, text=True).stdout.split()
    return [int(a) for a, g in zip(r[::2], r[1::2]) if int(g) == group and int(a) != me]


def signal_build(sig):
    for pid in build_pids():
        try: os.kill(pid, sig)
        except OSError: pass


def space_guard(p, folder, say):
    """While the build runs: below LOW_SPACE free on its drive, every process of the build but this one is stopped (SIGSTOP) and the launcher shows why; from RESUME_SPACE
    they continue (SIGCONT). A full disk mid-build can leave a Mac barely usable; a paused build costs nothing and goes on where it was"""
    me, group, paused = os.getpid(), os.getpgrp(), False
    def others():
        r = subprocess.run(['ps', '-A', '-o', 'pid=,pgid='], capture_output=True, text=True).stdout.split()
        return [int(a) for a, g in zip(r[::2], r[1::2]) if int(g) == group and int(a) != me]
    while p.poll() is None:
        try: free = shutil.disk_usage(folder).free
        except OSError: free = RESUME_SPACE
        if not paused and free < LOW_SPACE:
            for pid in others():
                try: os.kill(pid, signal.SIGSTOP)
                except OSError: pass
            paused = True
            log(f'paused: only {free / 2**30:.1f} GB free on the build folder\'s drive')
            say(f'Paused: only {free / 2**30:.1f} GB free on the build drive. Free some space and the build continues by itself.')
        elif paused and free >= RESUME_SPACE:
            for pid in others():
                try: os.kill(pid, signal.SIGCONT)
                except OSError: pass
            paused = False
            log(f'continuing: {free / 2**30:.1f} GB free'); say('Continuing: enough free space again')
        time.sleep(15)


SPACE = {'peak': 0, 'at': '', 'step': '', 'parts': {}}   # the build folder's largest size this session (space_log)
SPACE_PARTS = ('extract', 'library', 'cache db', 'shaders in flight', 'split packages', 'pipelines', 'other')


def space_parts(game):
    """The build folder's disk use by part, in bytes (blocks, as the drive counts them): game data (extract), the shader library image(s), the compile
    cache (cas.db and its WAL), shaders in flight (the library folder b-<chain>/ and the translator's work), the split packages, the pipelines (run/)"""
    work = game / 'build.noindex'; parts = dict.fromkeys(SPACE_PARTS, 0)
    for d, _, files in os.walk(work):
        rel = Path(d).relative_to(work).parts
        top = rel[0] if rel else ''
        for f in files:
            try: n = os.lstat(os.path.join(d, f)).st_blocks * 512
            except OSError: continue
            if top == 'extract': k = 'extract'
            elif top == 'run': k = 'pipelines'
            elif top == 'shader' and len(rel) > 1 and rel[1] == 'pkg': k = 'split packages'
            elif top == 'shader' and len(rel) == 2 and rel[1] == 'cache': k = 'cache db' if f.startswith('cas.db') else 'library' if f.endswith('.img') else 'shaders in flight'
            elif top in ('shader', 'tmp'): k = 'shaders in flight'
            else: k = 'other'
            parts[k] += n
    return parts


def space_sample(game, logs, step):
    """One line of logs/space.tsv (time, step, total GB, then each part in GB); keeps the peak"""
    parts = space_parts(game); total = sum(parts.values())
    f = logs / 'space.tsv'; new = not f.exists()
    with f.open('a') as t:
        if new: t.write('# the build folder\'s disk use, GB (1 GB = 10^9 bytes), once a minute while a build runs (nx_build.py space_log)\ntime\tstep\ttotal\t' + '\t'.join(SPACE_PARTS) + '\n')
        t.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}\t{step}\t{total / 1e9:.1f}\t" + '\t'.join(f'{parts[k] / 1e9:.1f}' for k in SPACE_PARTS) + '\n')
    if total > SPACE['peak']: SPACE.update(peak=total, at=f'{datetime.datetime.now():%H:%M}', step=step, parts=parts)
    return total


def space_log(p, game, logs, step):
    """While the build script runs: a space sample every minute (step(): the step it is in)"""
    while p.poll() is None:
        try: space_sample(game, logs, step())
        except Exception as e: log(f'space log: {e}'); return
        for _ in range(60):
            if p.poll() is not None: break
            time.sleep(1)


def space_summary():
    if not SPACE['peak']: return 'space: no sample'
    return (f"space: peak {SPACE['peak'] / 1e9:.1f} GB at {SPACE['at']} ({SPACE['step']}): "
            + ', '.join(f'{k} {v / 1e9:.1f}' for k, v in SPACE['parts'].items() if v >= 0.05e9))


def quick_part_done(game, work, rt):
    """Whether quick start's first part is complete for this app's shader chain: the game program is there and the library image b-<chain>.img holds every shader of the
    quick-start list. Not ready.json: the app's "Build again" and "Rebuild" delete it before this runs, and the image is what the game reads"""
    try: chain = re.search(r'#define DMSH_CHAIN "([0-9a-f]+)"', (rt / 'nxnative/dm/gfx/nvn/dmsh_chain.h').read_text()).group(1)
    except (OSError, AttributeError): return False
    img = work / f'shader/cache/b-{chain}.img'
    if not (work / 'tools/dmhost').is_file() or not img.is_file(): return False
    sys.path.insert(0, str(rt / 'nxnative/dm/tools'))
    try:
        import romfs
        have = {p.name[:16] for p in romfs.Path(str(img)).iterdir() if p.name.endswith('_b.json')}
    except Exception: return False
    keys = [ln.strip() for ln in (game / 'recorded_shaders.txt').read_text().splitlines() if ln.strip() and not ln.startswith('#')] if (game / 'recorded_shaders.txt').is_file() else []
    return bool(keys) and all(k in have for k in keys)


def check_ready(game, work, rt, write=False):
    """Read only (unless write): whether this folder holds a playable build, whatever ready.json says (missing: deleted, or a build that stopped before writing it;
    a player who ran nx_play.py by hand found the game playable with Play greyed, Reddit 2026-11-11). Needs the game program, the patched code, the game data and
    this app's shader library image b-<chain>.img: all shaders of the shader map = finished (partial while the build's log has no "# finished" line: Continue does
    the rest), the quick-start set = partial, fewer = not playable. Prints READY finished|partial|none <reason>; with write, a playable build gets its ready.json"""
    def newest(folder, pattern, need=None):
        found = sorted((p for p in folder.glob(pattern) if p.is_dir() and (need is None or (p / need).exists())), key=lambda p: p.name) if folder.is_dir() else []
        return found[-1] if found else None
    def no(reason): out(f'READY none {reason}'); return 1
    chain = chain_of(rt / 'nxnative')
    if not chain: return no('this app has no shader chain header')
    if not os.access(work / 'tools/dmhost', os.X_OK): return no('no game program (build.noindex/tools/dmhost)')
    if not newest(work, 'patched_v*', 'main.patched.bin'): return no('no patched game code (build.noindex/patched_v*)')
    if not newest(work / 'extract', 'v*', 'RomFS.img'): return no('no game data (build.noindex/extract/v*/RomFS.img)')
    img = work / f'shader/cache/b-{chain}.img'
    if not img.is_file():
        other = sorted(p.name for p in (work / 'shader/cache').glob('b-*.img')) if (work / 'shader/cache').is_dir() else []
        return no(f'shaders of another app version ({", ".join(other)}): this app needs a rebuild' if other else 'no shaders compiled yet')
    sys.path.insert(0, str(rt / 'nxnative/dm/tools'))
    try:
        import romfs
        have = {p.name[:16] for p in romfs.Path(str(img)).iterdir() if p.name.endswith('_b.json')}
    except Exception as e: return no(f'the shader library could not be read: {e}')
    smap = rt / f'nxnative/dm/games/{TITLE}/shader_map.tsv'
    want = {f[3] for f in (ln.split('\t') for ln in smap.read_text().splitlines() if ln and not ln.startswith('#')) if len(f) > 3 and re.fullmatch(r'[0-9a-f]{16}', f[3])}
    rec = game / 'recorded_shaders.txt'
    if not rec.is_file(): rec = rt / 'recorded_shaders.txt'
    quick = [ln.strip() for ln in rec.read_text().splitlines() if ln.strip() and not ln.startswith('#')] if rec.is_file() else []
    times = game / 'logs/build-times.tsv'
    finished = times.is_file() and any(ln.startswith('# finished') for ln in times.read_text(errors='replace').splitlines())
    n = len(want & have)
    if want and n == len(want): state = 'finished' if finished else 'partial'
    elif quick and all(k in have for k in quick): state = 'partial'
    else: return no(f'{n:,} of {len(want):,} shaders compiled, the quick-start set not complete: continue the build')
    out(f'READY {state} {n:,} of {len(want):,} shaders, chain {chain}')
    if write:
        try: fmt = json.loads((rt / 'build-format.json').read_text()).get('format', 1)
        except (OSError, ValueError): fmt = 1
        info = {'title_id': TITLE, 'version': '1.1.0', 'built': datetime.datetime.fromtimestamp(img.stat().st_mtime).strftime('%Y-%m-%dT%H:%M:%S'),
                'runtime': '?', 'build_format': fmt, 'chain': chain, 'pack_format': 3,
                'storage': 'normal' if (work / 'shader/cache/cas.db').is_file() else 'minimal', 'restored': True}   # runtime '?': the app updates the game program next
        if state == 'partial': info['partial'] = True
        (game / 'ready.json').write_text(json.dumps(info) + '\n')
        log(f'ready.json written for a {state} build found in the folder')
    return 0


def update_program(game, work, repo, rt, py, env):
    """A finished build made with an earlier app of the same shader chain gets this app's game program: build_mac_host only (the build's own reuse key decides
    whether it compiles), then ready.json's runtime is this app's. Game data, shaders, pipelines and saves are not touched"""
    try: ready = json.loads((game / 'ready.json').read_text())
    except (OSError, ValueError): out('ERROR There is no build here to update'); return 1
    chain = chain_of(repo)
    if ready.get('chain') and chain and ready['chain'] != chain:
        out('ERROR This build\'s shaders are from another app version: it needs a rebuild'); return 1
    ver = (rt / 'VERSION').read_text().strip() if (rt / 'VERSION').exists() else '?'
    out('PROGRESS host 10 Building the game program')
    t0 = time.time()
    code = ('import os, sys, types; from pathlib import Path; sys.path.insert(0, sys.argv[1]); import build_ipa_from_nsp as b; '
            'b.build_mac_host(Path(sys.argv[2]), Path(sys.argv[3]), dict(os.environ), Path(sys.argv[4]), types.SimpleNamespace(id=sys.argv[5]))')
    r = subprocess.run([py, '-c', code, str(repo / 'scripts'), str(repo), str(work / 'tools/dmhost'), str(work / 'logs'), TITLE], env=env, capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines(): log(line)
    if r.returncode: out('ERROR The game program could not be built. The details have the reason.'); return 1
    ready['runtime'] = ver
    (game / 'ready.json').write_text(json.dumps(ready) + '\n')
    log(f'game program updated to {ver} in {time.time() - t0:.0f} s')
    out('PROGRESS host 100 The game program is up to date'); out('DONE')
    return 0


def merged_recording(recorded, game, repo):
    """The quick start's list: the app's recording (Runtime/recorded_shaders.txt, its first line names the game version it was made on), then the shaders this player met
    in play that it lacks (logs/shaders-played.tsv, which every Play appends to: DM_PSO_RECORD), each in first-use order, into <game folder>/recorded_shaders.txt.
    Logs how many of them this version's shader map has: a list made on another game version shows it here"""
    seen, keys = set(), []
    def add(k):
        if re.fullmatch(r'[0-9a-f]{16}', k) and k not in seen: seen.add(k); keys.append(k)
    head = ''
    for ln in recorded.read_text().splitlines():
        if ln.startswith('#'): head = head or ln
        else: add(ln.strip())
    base = len(keys)
    played = game / 'logs/shaders-played.tsv'
    if played.is_file():
        for ln in played.read_text(errors='replace').splitlines():
            p = ln.split('\t')
            if len(p) > 1 and p[0] == 'S': add(p[1][:16])
    smap = repo / f'dm/games/{TITLE}/shader_map.tsv'
    in_map = set()
    if smap.is_file():
        for ln in smap.read_text(errors='replace').splitlines():
            c = ln.split('\t')
            if len(c) > 3: in_map.add(c[3])
    n = sum(1 for k in keys if k in in_map)
    log(f'quick start: {len(keys):,} recorded shaders ({base:,} from the app\'s recording, {len(keys) - base:,} more from your play), {n:,} of them in this version\'s shader map'
        + (f'; {head[2:].split(":")[0]}' if head else ''))
    out_file = game / 'recorded_shaders.txt'
    out_file.write_text(f'{head or "# recorded shaders"} + this player\'s play\n' + ''.join(k + '\n' for k in keys))
    return out_file


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True); ap.add_argument('--runtime', required=True)
    ap.add_argument('--base'); ap.add_argument('--update'); ap.add_argument('--keys')
    ap.add_argument('--storage', choices=('minimal', 'normal', 'full'), default='normal')
    ap.add_argument('--quick-start', action='store_true'); ap.add_argument('--test', action='store_true')
    ap.add_argument('--until-split', action='store_true', help='only the quick steps (game data, rewrite, split), then exit: the speed test\'s shader packages')
    ap.add_argument('--estimate-first', action='store_true', help='kept for older apps: every fresh build now estimates itself (see the in-build estimate)')
    ap.add_argument('--optimise', action='store_true', help='give back what a finished build no longer needs (an earlier app\'s build), then exit')
    ap.add_argument('--update-program', action='store_true', help='a build made with an earlier app of the same shader chain: build only the game program with this app\'s tools, then exit')
    ap.add_argument('--check-ready', action='store_true', help='read only: whether this folder holds a playable build (ready.json missing or not); prints READY finished|partial|none <reason>')
    ap.add_argument('--write', action='store_true', help='with --check-ready: write ready.json for a playable build')
    ap.add_argument('--threads-only', action='store_true', help='the shader step in one process with threads (DMSH_PROCS=0) instead of a worker process per core: for comparison')
    ap.add_argument('--priority', choices=('normal', 'low', 'background'), default='normal', help="the build's priority: low = the utility QoS clamp (the game first; about a third slower on the M4). "
                    "Changed while the build runs through <game folder>/logs/priority (the app writes it: low while the game runs): the shader pass restarts under the new clamp, "
                    "finished shaders are kept. 'background' (macOS's background class) measured 7x slower on an idle M4 (2026-11-09) and is taken as low")
    a = ap.parse_args()
    game, rt = Path(a.out), Path(a.runtime)
    if a.check_ready: return check_ready(game, game / 'build.noindex', rt, a.write)   # before anything is created in the folder
    logs = game / 'logs'; logs.mkdir(parents=True, exist_ok=True)
    stamps = game / '.stamps'; stamps.mkdir(exist_ok=True)
    work = game / 'build.noindex'; work.mkdir(exist_ok=True)

    if a.optimise:   # a finished build from an earlier app: give back what it no longer needs, once (ready.json storage_opt)
        try: ready = json.loads((game / 'ready.json').read_text())
        except (OSError, ValueError): out('ERROR There is no finished build here'); return 1
        if ready.get('partial') or ready.get('test'): out('ERROR The build is not finished: space is given back when it finishes'); return 1
        if ready.get('storage_opt', 0) >= STORAGE_OPT: out('DONE'); return 0
        out('PROGRESS pipelines 0 Giving back space (one time, a few minutes)')
        t0 = time.time()
        freed = optimise_storage(game, work, ready.get('chain'), ready.get('storage', a.storage), part=lambda t: out(f'PROGRESS pipelines 0 Giving back space · {t}'))
        ready['storage_opt'] = STORAGE_OPT
        (game / 'ready.json').write_text(json.dumps(ready) + '\n')
        log(f'storage: {freed / 1e9:.1f} GB given back in {time.time() - t0:.0f} s')
        out(f'PROGRESS pipelines 100 {freed / 1e9:.0f} GB given back'); out('DONE'); return 0

    os.setpgrp()   # one process group: Pause / Stop from the launcher reach every worker
    sess = {}
    def on_term(sig, _):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if sess.get('tl'):
            try: sess['tl'].record()
            except Exception: pass
        if sess.get('times'):   # a stopped session's length, for the build's total across sessions (elapsed_before)
            try:
                with sess['times'].open('a') as f: f.write(f"# end {datetime.datetime.now():%Y-%m-%d %H:%M:%S}\tstopped\ttotal {time.time() - sess['t0']:.0f} s\n")
            except OSError: pass
        os.killpg(os.getpgrp(), signal.SIGTERM)
        sys.exit(143)
    signal.signal(signal.SIGTERM, on_term)

    # Keep the Mac awake while this build runs (a long build left alone overnight; the display may still sleep).
    try: subprocess.Popen(['/usr/bin/caffeinate', '-i', '-w', str(os.getpid())], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError: log('caffeinate not available: the Mac may sleep during the build')

    out('PROGRESS read 0 Installing the build tools')
    repo = game / 'nxnative-runtime'
    copy_tree(rt / 'nxnative', repo)

    files = [p for p in (a.base, a.update) if p]
    inputs = game / 'inputs'
    if files: link_inputs(inputs, files)
    elif not inputs.exists() and not a.update_program:
        out('ERROR Choose the base game and the 1.1.0 update'); return 1

    py = sys.executable
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([str(rt / 'bin'), str(rt / 'dotnet'), '/usr/bin', '/bin', '/usr/sbin', '/sbin'])
    env.update(DM_TOOLS_FIRST='1', DOTNET_ROOT=str(rt / 'dotnet'), DOTNET_NOLOGO='1', DOTNET_CLI_TELEMETRY_OPTOUT='1',
               DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1', DM_NX_EXTRACT_PREBUILT=str(rt / 'nx_extract'), PYTHONDONTWRITEBYTECODE='1',
               )
    if a.update_program:   # a finished build made with an earlier app: only the game program again (build_mac_host: ~30 s on the M4), nothing else touched
        return update_program(game, work, repo, rt, py, env)
    # The shader step: a worker process per core by default (dmsh_build.py's DMSH_PROCS = cores; the speed test on the M4, 2026-11-08: ~1/3 faster than threads)
    env['DMSH_PROCS'] = '0' if a.threads_only else str(os.cpu_count() or 8)
    log(f"shader step: {'threads only' if a.threads_only else env['DMSH_PROCS'] + ' worker processes'}")
    recorded = rt / 'recorded_shaders.txt'
    if (a.quick_start or a.test) and not recorded.is_file():
        out('ERROR This app has no list of recorded shaders (recorded_shaders.txt): build without the quick start'); return 1
    cmd = [py, '-u', str(repo / 'scripts/build_ipa_from_nsp.py'), str(inputs), '--platform', 'mac', '--work-dir', str(work),
           '--title-id', TITLE, '--progress', 'json']
    if a.keys: cmd += ['-k', a.keys]
    # Another Xcode's Metal compiler builds too (each library records its compiler); nxnative would stop with installation instructions. The log names the compiler
    cmd += ['--allow-other-metal']
    log('$ ' + ' '.join(cmd))

    times = logs / 'build-times.tsv'
    if not times.exists(): times.write_text('# date\tmac\tstage\tseconds\tok\tsummary\n')
    mac = f'{platform.machine()} {os.cpu_count()} cores'
    try: mac = subprocess.run(['sysctl', '-n', 'machdep.cpu.brand_string'], capture_output=True, text=True).stdout.strip() + f', {os.cpu_count()} cores'
    except OSError: pass
    with times.open('a') as t: t.write(f'# start {datetime.datetime.now():%Y-%m-%d %H:%M:%S}\t{mac}\t' + ('threads only' if a.threads_only else f"{env['DMSH_PROCS']} processes") + '\n')

    t_start = time.time()
    sess['times'], sess['t0'] = times, t_start
    state = {'last_red': None}
    try: finished_before = not json.loads((game / 'ready.json').read_text()).get('partial')
    except (OSError, ValueError): finished_before = False
    if finished_before:   # a finished build run again (new tools, Build again): its sessions are over
        with times.open('a') as f: f.write(f'# finished (earlier build)\n')
    out(f'ELAPSED_BEFORE {int(elapsed_before(times))}')   # this build's earlier sessions (a stopped build continued): the Build window shows the total

    # The time left (ETA lines) for every build: the speed test's or a finished build's projection for this Mac first, then the build's own progress (TimeLeft)
    speed = None
    if not a.until_split:
        try:
            sys.path.insert(0, str(rt)); import nx_speedtest
            v = nx_speedtest.check(game, rt / 'nxnative')
            if v: speed = (v.get('shader_s') if v.get('kind') == 'real' else v.get('projected_shader_s')), (v.get('file') if v.get('kind') == 'test' else None)
        except Exception as e: log(f'time estimate: no speed test read ({e})')
    tl = TimeLeft(work, logs, rt, repo, *(speed or (None, None))); sess['tl'] = tl
    prio = {'cur': None, 'file': logs / 'priority'}
    def wanted_priority():
        try: v = prio['file'].read_text().strip()
        except OSError: v = ''
        v = v or a.priority
        return 'low' if v in ('low', 'background') else 'normal'

    def run_pass(penv, lo, hi, label='', by_shaders=False, until_split=False, partial=False):
        """One run of the build script; its percentages go into lo..hi of the launcher's bar. Returns its exit code (0 for until_split once the split is done).
        by_shaders (quick start's background part): the bar and the text follow the shaders done of all, not the script's steps, whose reused ones would jump the bar.
        partial (quick start's set): the whole-build numbers go on counting, the estimate stays the whole build's (TimeLeft).
        A ticker refreshes the line every 10 s, so a long step with few events of its own (the pipelines) still moves, and applies a changed priority"""
        base = {}; acc = 0
        for sid, w in STEPS: base[sid] = acc; acc += w
        weight = dict(STEPS)
        cur = 'read'
        last = {'sid': 'read', 'pct': 0, 'text': TEXT['read']}
        lock = threading.Lock()
        tl.partial = partial
        try: tl.prog.unlink()   # the last pass's (or session's) counts must not show before this pass's shader step writes its own
        except OSError: pass
        def emit(sid, pct, text, tick=False):
            with lock:
                if not tick: last.update(sid=sid, pct=pct, text=text)
                tl.poll()
                if sid == 'shaders' and tl.total:   # the shader step's own state (the step row); the whole-build counts go out as COUNT lines
                    if tl.step == 'cache check': text = f'Checking the cache: {tl.done:,} of {tl.total:,} checked' + (f' · {tl.cached:,} already done' if tl.cached else '')
                    elif tl.restoring(): text = f'Restoring {tl.cached:,} finished shaders from the cache: {tl.done:,} done'
                    elif by_shaders: text = f'Compiling the shaders: {tl.whole:,} of {tl.full:,}'
                if by_shaders and tl.full: pct = 100 * tl.whole // tl.full
                pl = tl.pipelines()   # also keeps the count of bases built (COUNT pipelines) current in every step
                if sid == 'pipelines' and pl:
                    text = f'{TEXT["pipelines"]}: {pl[1]:,} of {pl[2]:,} pairs checked · {tl.pipes:,} built'
                    if not partial: pct = base['pipelines'] + weight['pipelines'] * pl[1] // max(1, pl[2])
                if tl.full: out(f'COUNT shaders {tl.whole} {tl.full}')
                if tl.pairs_total: out(f'COUNT pipelines {tl.pipes} {tl.pairs_total}')
                if partial and sid == 'shaders' and tl.total: out(f'COUNT part {tl.done} {tl.total}')
                eta = tl.total_left(sid)
                if eta is not None: out(f'ETA {int(eta)}')
                out(f'PROGRESS {sid} {lo + (hi - lo) * min(pct, 99) // 100} {label}{text}')
        while True:   # one run of the script; run again under the other QoS clamp when the priority changes (the clamp cannot be changed on a running process)
            want = wanted_priority()
            wrap = ('/usr/sbin/taskpolicy', '-c', 'utility') if want == 'low' else ()
            if prio['cur'] != want: log(f'priority: {want}'); prio['cur'] = want
            restart = {'on': False}
            p = subprocess.Popen([*wrap, *cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=penv, cwd=str(repo), bufsize=1)
            threading.Thread(target=space_guard, args=(p, game, lambda text: emit(cur, base[cur], text)), daemon=True).start()
            threading.Thread(target=space_log, args=(p, game, logs, lambda: last['sid'] + (f' · {tl.step}' if last['sid'] == 'shaders' and tl.step else '') + (' (quick start set)' if partial else '')), daemon=True).start()
            def ticker():
                seen, since = -1, time.time()
                while p.poll() is None:
                    time.sleep(10)
                    if p.poll() is None: emit(last['sid'], last['pct'], last['text'], tick=True)
                    if (want := wanted_priority()) != prio['cur'] and last['sid'] == 'shaders' and p.poll() is None:
                        # the shader step restarts under the new clamp: finished shaders are kept (restored from the cache in the next run's first minutes)
                        log(f'priority: {want} wanted: the shader step restarts'); restart['on'] = True; tl.record()
                        subprocess.run(['/usr/bin/pkill', '-TERM', '-P', str(p.pid)], capture_output=True); p.terminate()
                        return
                    # The stall guard: in the shader step, no shader finished for STALL_S → check the Metal compiler; gone → stop with the install message
                    if last['sid'] != 'shaders' or tl.done != seen: seen, since = tl.done, time.time(); continue
                    if time.time() - since > STALL_S:
                        since = time.time()
                        if not metal_ok():
                            log('[RED] ' + TOOLCHAIN_GONE); state['last_red'] = TOOLCHAIN_GONE
                            subprocess.run(['/usr/bin/pkill', '-TERM', '-P', str(p.pid)], capture_output=True); p.terminate()
                            subprocess.run(['/usr/bin/pkill', '-KILL', '-f', 'Metal.xctoolchain/usr/metal'], capture_output=True)   # the spinning compilers
                            return
            threading.Thread(target=ticker, daemon=True).start()
            for line in p.stdout:
                cur = handle_line(line, cur, base, weight, emit)
                if until_split and state.get('split_done'):   # the speed test's packages are there: stop before the shader step (everything done is reused later)
                    subprocess.run(['/usr/bin/pkill', '-TERM', '-P', str(p.pid)], capture_output=True); p.terminate()
                    try: p.wait(30)
                    except subprocess.TimeoutExpired: p.kill()
                    return 0
            code = p.wait()
            if not restart['on']: return code
            time.sleep(2)   # the workers are gone; the next run finds their finished shaders in the cache

    def handle_line(line, cur, base, weight, emit):
        line = line.rstrip('\n')
        try: ev = json.loads(line) if line.startswith('{') else None
        except ValueError: ev = None
        if not ev: log(line); return cur
        k = ev.get('ev')
        if k == 'stage':
            cur = STAGE_STEP.get(ev.get('name', ''), cur)
            log(f"[{ev.get('k')}/{ev.get('n')}] {ev.get('name')}" + (f" · {ev['step']}" if ev.get('step') else ''))
            emit(cur, base[cur], TEXT[cur])
        elif k == 'progress':
            frac = ev.get('frac')
            phase = SHADER_PHASES.get(ev.get('step')) if cur == 'shaders' else None
            if phase:
                part, start, share, what = phase
                pct = base[cur] + int(weight[cur] * (start + share * (frac or 0)))
                detail = ('Checking the cache for the quick-start set' if part == 1 else 'Compiling the quick-start set') if tl.partial else f'{TEXT[cur]} · part {part} of 2: {what}'
            else:
                pct = base[cur] + (int(weight[cur] * frac) if frac is not None else 0)
                detail = TEXT[cur] + (f" · {ev['step']}" if ev.get('step') else '')
            if ev.get('done') is not None and ev.get('total') and ev.get('unit') != 'B':
                detail += f": {ev['done']:,} of {ev['total']:,}"
            if ev.get('eta'):
                m_ = int(ev['eta'] // 60)
                detail += f" ({'under a minute' if m_ < 1 else f'about {m_} min'} left in this {'part' if phase else 'step'})"
            emit(cur, min(pct, 99), detail)
        elif k == 'stage_end':
            ok = ev.get('ok', True)
            log(f"{'✓' if ok else '✗'} {ev.get('name')} ({ev.get('elapsed', 0):.0f} s)" + (f": {ev['summary']}" if ev.get('summary') else ''))
            with times.open('a') as t:
                t.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}\t{mac}\t{ev.get('name')}\t{ev.get('elapsed', 0):.1f}\t{int(ok)}\t{ev.get('summary', '')}\n")
            if ok and cur in ('rewrite', 'split'):
                for s in ('code', 'romfs'): (stamps / s).touch()
            if ok and ev.get('name') == 'Mac shaders' and not tl.partial and not a.test and not a.until_split:
                # Space back as soon as the shaders are done, not after the pipelines (~44 min later), so the pipelines' ~16 GB never sits beside the shader step's
                # leftovers (user, 2026-11-09: the build folder should stay near the finished size). The build script is paused meanwhile (as space_guard does):
                # the same work as at the end, earlier, so no time is lost; the end's optimise_storage then finds it done.
                signal_build(signal.SIGSTOP)
                try:
                    emit(cur, base[cur], 'Giving back space after the shaders')
                    optimise_storage(game, work, chain_of(repo), a.storage, part=lambda t: emit(cur, base[cur], f'Giving back space · {t}'))
                    log('space after the shader step: ' + f'{space_sample(game, logs, "after the shader step") / 1e9:.1f} GB')
                except Exception as e: log(f'[RED] giving back space after the shaders failed (the build goes on, only larger): {e}')
                finally: signal_build(signal.SIGCONT)
            if ok and ev.get('name') == 'shader split':
                state['split_done'] = True
                if m_ := re.search(r'([\d,]+) shaders', ev.get('summary', '')): tl.set_full(int(m_.group(1).replace(',', '')))
        elif k == 'step':
            log(f"[{ev.get('k')}] {ev.get('name')} · {ev.get('step')}")
        elif k == 'say':
            msg = ev.get('msg', ''); log(msg)
            if '[RED]' in msg: state['last_red'] = msg.replace('[RED]', '').strip()
            if '[WAIT] pipeline prebuild' in msg:   # the game runs: the prebuild waits for it to close (build_ipa_from_nsp.py, DM_PREBUILD_UNLESS_PLAYING=wait)
                out('WAITING 1'); emit(cur, base[cur], 'Waiting for the game to close to prepare the pipelines')
            elif '[WAIT] over' in msg: out('WAITING 0'); emit(cur, base[cur], TEXT[cur])
        else:
            log(line)
        return cur

    def finish(code, extra=None):
        total = time.time() - sess['t0']; sess['t0'] = time.time()   # each end line covers its own stretch (quick start writes two in one session)
        with times.open('a') as t: t.write(f"# end {datetime.datetime.now():%Y-%m-%d %H:%M:%S}\texit {code}\ttotal {total:.0f} s\n")
        log(space_summary())
        if code != 0:
            log(f"ready.json not written: the build stopped (exit {code})" + (f": {state['last_red']}" if state['last_red'] else ''))
            out('ERROR ' + (state['last_red'] or f'The build stopped (code {code}). The details have the reason.')); return code
        for s_ in ('code', 'romfs', 'build'): (stamps / s_).touch()
        if not (extra or {}).get('partial') and not (extra or {}).get('test'):
            out(f'PROGRESS pipelines 99 Giving back space')
            try: optimise_storage(game, work, chain_of(repo), a.storage, part=lambda t: out(f'PROGRESS pipelines 99 Giving back space · {t}'))
            except Exception as e: log(f'[RED] giving back space failed (the build is fine, only larger): {e}')
            try: log(f'space: finished build {space_sample(game, logs, "finished") / 1e9:.1f} GB; ' + space_summary())
            except Exception as e: log(f'space log: {e}')
            extra = dict(extra or {}, storage_opt=STORAGE_OPT)
            if tl.prior + tl.compile_s > 600:   # only a build that compiled its shaders (not a tools update of a finished one) gives this Mac's real times
              try:   # this Mac's real times: they win over any speed test for the next build (nx_speedtest.check)
                  sys.path.insert(0, str(rt)); import nx_speedtest
                  total_s = elapsed_before(times)   # every session of this build, this one's end line included
                  (logs / 'build-real.json').write_text(json.dumps({'fingerprint': nx_speedtest.fingerprint(rt / 'nxnative', 0 if a.threads_only else os.cpu_count()),
                      'shader_s': round((tl.prior + tl.compile_s) * (1 + TimeLeft.WINDDOWN)), 'total_s': round(total_s), 'projected_total_s': round(total_s), 'built': f'{datetime.datetime.now():%Y-%m-%d %H:%M:%S}'}, indent=1))
              except Exception as e: log(f'real build times not saved: {e}')
            with times.open('a') as f: f.write(f'# finished {datetime.datetime.now():%Y-%m-%d %H:%M:%S}\n')
            prof = logs / 'shader-progress.tsv'
            if prof.exists(): prof.rename(logs / f'shader-progress-{datetime.datetime.now():%Y%m%d-%H%M%S}.tsv')
        write_ready(extra)
        return 0

    def write_ready(extra=None):
        ver = (rt / 'VERSION').read_text().strip() if (rt / 'VERSION').exists() else '?'
        # What the build was made with, for the app's rebuild check (AppSettings.rebuildStatus): the release table's format, the shader chain version the game program
        # loads (dmsh_chain.h) and the pack format the shaders are stored in (dmpack.py VERSION)
        try: fmt = json.loads((rt / 'build-format.json').read_text()).get('format', 1)
        except (OSError, ValueError): fmt = 1
        m = re.search(r'#define DMSH_CHAIN "([0-9a-f]+)"', (repo / 'dm/gfx/nvn/dmsh_chain.h').read_text())
        (game / 'ready.json').write_text(json.dumps({'title_id': TITLE, 'version': '1.1.0', 'built': datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S'),
                                                     'runtime': ver, 'build_format': fmt, 'chain': m.group(1) if m else None, 'pack_format': 3,
                                                     'storage': a.storage, **(extra or {})}) + '\n')

    if a.until_split:   # the speed test's shader packages: the quick steps only
        code = run_pass(env, 0, 100, 'Preparing · ', until_split=True)
        with times.open('a') as f: f.write(f"# end {datetime.datetime.now():%Y-%m-%d %H:%M:%S}\tsplit only\ttotal {time.time() - sess['t0']:.0f} s\n")
        if code != 0 or not state.get('split_done'):
            out('ERROR ' + (state['last_red'] or 'The game data could not be prepared. The details have the reason.')); return code or 1
        out('DONE'); return 0
    cas = work / 'shader/cache/cas.db'
    if not a.test and not finished_before and (not cas.exists() or cas.stat().st_size < (1 << 20)):
        # The build's own estimate (every fresh build, 2026-11-08): the quick steps, then a random sample of the shaders compiled into this build's compile cache and
        # timed (nx_speedtest.py --in-build: ~100 s on the M4), its estimate as ESTIMATE <seconds>, then the build. Nothing is done twice: the build restores the sample's
        # shaders from the cache. Only on a cold cache (a fresh build): a warm one would time cache restores. A continued build keeps its saved estimate
        out('PHASE estimating')
        code = run_pass(env, 0, 4, 'Preparing the game files · ', until_split=True)
        if code != 0 or not state.get('split_done'):
            out('ERROR ' + (state['last_red'] or 'The game data could not be prepared. The details have the reason.')); return code or 1
        out('PROGRESS split 4 Compiling a sample of the shaders')
        t_est = time.time()
        sp = subprocess.Popen([sys.executable, '-E', '-s', str(rt / 'nx_speedtest.py'), '--game', str(game), '--in-build'], stdout=subprocess.PIPE, text=True, env=env, cwd=str(rt))
        prog_t = {'t': time.time(), 'd': -1, 'gone': False}
        def sample_guard():   # the stall guard for the sample (see run_pass)
            while sp.poll() is None:
                time.sleep(10)
                if time.time() - prog_t['t'] > STALL_S:
                    prog_t['t'] = time.time()
                    if not metal_ok():
                        prog_t['gone'] = True; log('[RED] ' + TOOLCHAIN_GONE)
                        subprocess.run(['/usr/bin/pkill', '-TERM', '-P', str(sp.pid)], capture_output=True); sp.terminate()
                        subprocess.run(['/usr/bin/pkill', '-KILL', '-f', 'Metal.xctoolchain/usr/metal'], capture_output=True)
                        return
        threading.Thread(target=sample_guard, daemon=True).start()
        for ln in sp.stdout:
            f_ = ln.split()
            if ln.startswith('PROGRESS ') and len(f_) >= 7:
                try: d_, n_ = int(f_[-3]), int(f_[-2])
                except ValueError: continue
                if d_ != prog_t['d']: prog_t.update(t=time.time(), d=d_, n=n_)
                if n_:
                    if tl.full:
                        tl.whole = max(tl.whole, min(d_, tl.full)); out(f'COUNT shaders {tl.whole} {tl.full}')
                    out(f'PROGRESS split 4 Compiling a sample of the shaders: {d_:,} of {n_:,}')
            elif ln.startswith('RESULT '):
                try:
                    r = json.loads(ln[7:]); out(f"ESTIMATE {r['projected_total_s']}")
                    if tl.full and prog_t.get('n'): tl.whole = max(tl.whole, min(prog_t['n'], tl.full)); out(f'COUNT shaders {tl.whole} {tl.full}')
                    tl.speed_s = r['projected_shader_s']
                    tl.speed_file = max(logs.glob('speedtest-*.json'), key=lambda f: f.stat().st_mtime, default=None)
                    log(f"estimate: a {r['share']:g}% sample in {time.time() - t_est:.0f} s: shaders {r['projected_shader_s'] / 60:.0f} min, all about {r['projected_total_s'] / 60:.0f} min")
                except (ValueError, KeyError): pass
            elif ln.startswith('ERROR '): log(f'estimate: {ln[6:].strip()} (the build goes on without one)')
        sp.wait()
        tl.base = tl.whole; tl.compile_s += time.time() - t_est   # the sample's shaders are done (restored from the cache later), its time is compile time
        if prog_t['gone']: out('ERROR ' + TOOLCHAIN_GONE); return 1
        with times.open('a') as t: t.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}\t{mac}\testimate sample\t{time.time() - t_est:.1f}\t{int(sp.returncode == 0)}\tinto the build's cache\n")
    out('PHASE building')

    if a.quick_start and quick_part_done(game, work, rt):
        # Continuing a stopped quick-start build whose first part is complete: straight to the background part. Running the first part again would make
        # dmsh_build.py's partial run treat every finished background shader as stale and delete it (todo.md, Builder: the BUG entry)
        log('quick start: its shaders are already in the library image and the game program is ready: continuing with the rest')
        write_ready({'partial': True})   # playable meanwhile, also when the app's Rebuild / Build from scratch removed the mark
        out('PLAYABLE')
        for f in (work / 'run').glob('pso_archive*/prebuilt.tsv'): f.unlink()
        code = run_pass(dict(env, DM_PREBUILD_UNLESS_PLAYING='wait', DMSH_KEEP_IMAGE='1'), 30, 100, 'In the background · ', by_shaders=True)
        if finish(code): return code
        log(f'build finished in {(time.time() - t_start) / 60:.0f} min')
        out('PROGRESS pipelines 100 Ready'); out('DONE')
        return 0
    if a.test or a.quick_start:
        # First the recorded shaders, with everything else the game needs: the game can start after this
        keys_file = merged_recording(recorded, game, repo)
        code = run_pass(dict(env, DMSH_KEYS_FILE=str(keys_file)), 0, 100 if a.test else 30, '' if a.test else 'Quick start · ', partial=not a.test)
        tl.end_pass()
        if a.test:
            if finish(code, {'test': True}): return code
            log(f'test build finished in {(time.time() - t_start) / 60:.0f} min (only the recorded shaders)')
            out('PROGRESS pipelines 100 Ready (test build: only the recorded shaders)'); out('DONE'); return 0
        if finish(code, {'partial': True}): return code
        log(f'quick start: playable after {(time.time() - t_start) / 60:.0f} min; the other shaders compile now at utility priority')
        out('PLAYABLE')
        # The rest: the full build, which resumes the recorded shaders (dmsh_build.py's done list). Utility QoS (taskpolicy -c, inherited by every compile): the game,
        # at user-interactive QoS, comes first. Its pipeline prebuild is skipped while the game runs (the game makes the missing bases itself on its next start)
        for f in (work / 'run').glob('pso_archive*/prebuilt.tsv'): f.unlink()   # the bases of the new shaders: the next prebuild walks the pairs again
        code = run_pass(dict(env, DM_PREBUILD_UNLESS_PLAYING='wait', DMSH_KEEP_IMAGE='1'), 30, 100, 'In the background · ', by_shaders=True)
        if finish(code): return code
    else:
        code = run_pass(env, 0, 100)
        if finish(code): return code
    log(f'build finished in {(time.time() - t_start) / 60:.0f} min')
    out('PROGRESS pipelines 100 Ready'); out('DONE')
    return 0

if __name__ == '__main__':
    sys.exit(main())
