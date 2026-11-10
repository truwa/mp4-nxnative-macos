#!/usr/bin/env python3
"""Fake prepare_shaders.py: prints the real script's progress lines quickly and writes a report.json.
FAKE_PREP_STEP_SECONDS slows it; FAKE_PREP_DISK=1 fails with the disk message."""
import argparse, hashlib, json, os, sys, time
ap = argparse.ArgumentParser()
ap.add_argument("--game-root", required=True); ap.add_argument("--background", action="store_true")
a = ap.parse_args()
root = a.game_root
d = float(os.environ.get("FAKE_PREP_STEP_SECONDS", "0.3"))
state = os.path.join(root, "shader-prep", "run-" + hashlib.sha256(b"fake").hexdigest()[:12])
os.makedirs(state, exist_ok=True)
print(f"[prepare] binary {root}/build/mp4-native\n[prepare] cache {root}/build/shader-cache\n[prepare] results {state}\n[prepare] settings 'fake'", flush=True)
if os.environ.get("FAKE_PREP_DISK"):
    print("[prepare] 16 GiB needed for 249364 shaders, 3 GiB free: use --pak or --limit", file=sys.stderr, flush=True); sys.exit(1)
N = 20000
print(f"[translate] {N} selected, 0 already done, {N} to do", flush=True)
for i in range(5000, N + 1, 5000):
    time.sleep(d); print(f"[translate] {i}/{N} {{'ok': {i}}} {i//500} s", flush=True)
print(f"[compile] {N} to do with 8 threads", flush=True)
for i in range(5000, N + 1, 5000):
    time.sleep(d * 2); print(f"[compile] {i}/{N} {i//100} s", flush=True)
report = {"selected": N, "translate": {"ok": N}, "compile": {"ok": N - 3, "fail": 3}, "written": time.strftime("%Y-%m-%d %H:%M:%S")}
open(os.path.join(state, "report.json"), "w").write(json.dumps(report, indent=1) + "\n")
print(json.dumps(report)); print(f"[report] {state}/report.json, 3 failures in {state}/failures.tsv", flush=True)
