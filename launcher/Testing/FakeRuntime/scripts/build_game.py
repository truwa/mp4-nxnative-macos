#!/usr/bin/env python3
"""Fake build_game.py: prints the launcher contract without touching any game file.

Usage mirrors the real one:
  build_game.py --base <xci|nsp> --update <nsp> --keys <prod.keys> --out <cache dir> --runtime <Runtime dir>
Set FAKE_BUILD_FAIL=1 to end with ERROR, FAKE_BUILD_STEP_SECONDS to slow it down.
"""
import argparse, json, os, sys, time
from datetime import datetime, timezone

p = argparse.ArgumentParser()
p.add_argument("--base", required=True); p.add_argument("--update", required=True)
p.add_argument("--keys", required=True); p.add_argument("--out", required=True)
p.add_argument("--runtime", required=True)
a = p.parse_args()

for name, path in (("base", a.base), ("update", a.update), ("keys", a.keys)):
    if not os.path.exists(path):
        print(f"ERROR {name} file not found: {path}", flush=True); sys.exit(1)

delay = float(os.environ.get("FAKE_BUILD_STEP_SECONDS", "0.4"))
steps = [("extract", "Extracting base game"), ("update", "Applying update"),
         ("romfs", "Unpacking romfs"), ("rewrite", "Rewriting main"), ("tables", "Building tables")]
os.makedirs(a.out, exist_ok=True)
for i, (sid, text) in enumerate(steps):
    for pct in (0, 50, 100):
        overall = int((i * 100 + pct) / len(steps))
        print(f"PROGRESS {sid} {overall} {text} ({pct}%)", flush=True)
        time.sleep(delay)
    print(f"[{sid}] some stderr chatter", file=sys.stderr, flush=True)
    if os.environ.get("FAKE_BUILD_FAIL") and i == 2:
        print("ERROR Fake failure while unpacking romfs", flush=True); sys.exit(2)

os.makedirs(os.path.join(a.out, "rewritten", "v110"), exist_ok=True)
os.makedirs(os.path.join(a.out, "user-data"), exist_ok=True)
# Like the real build: copy the runtime binary into <cache>/build/.
import shutil
os.makedirs(os.path.join(a.out, "build"), exist_ok=True)
shutil.copy2(os.path.join(a.runtime, "bin", "mp4-native"), os.path.join(a.out, "build", "mp4-native"))
with open(os.path.join(a.out, "ready.json"), "w") as f:
    json.dump({"title_id": "010019A01E2F2000", "version": "1.1.0",
               "timestamp": datetime.now(timezone.utc).isoformat()}, f)
print("PROGRESS done 100 Finished", flush=True)
print("DONE", flush=True)
