#!/usr/bin/env python3
"""Serial, load-guarded fresh-process comparison. Never replaces a failed attempt.

No focus/input automation. Source snapshots and each process's stdout/stderr survive.
The 0.70 load/CPU ceiling is the pre-existing decision rule, not a fitted cutoff.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--samples", type=int, default=20)
parser.add_argument("--repeats", type=int, default=3)
parser.add_argument("--holds", default="0,5")
parser.add_argument("--budget-seconds", type=int, default=1200)
args = parser.parse_args()
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
for source in Path(__file__).parent.glob("measure-gpu-release*"):
    if source.is_file():
        shutil.copy2(source, out / source.name)
end = time.monotonic() + args.budget_seconds
cpus = int(subprocess.check_output(["sysctl", "-n", "hw.ncpu"], text=True))
env = dict(os.environ, GPU_RELEASE_SCREEN="builtin")
with (out / "processes.jsonl").open("a", buffering=1) as ledger:
    def record(row):
        ledger.write(json.dumps(row) + "\n")
        print(json.dumps(row), flush=True)

    for rep in range(1, args.repeats + 1):
        holds = args.holds.split(",")
        if rep % 2 == 0:
            holds.reverse()
        for hold in holds:
            arms = ["released", "control"] if rep % 2 else ["control", "released"]
            for arm in arms:
                label = f"r{rep}-hold{hold}-{arm}"
                while True:
                    raw_load = subprocess.check_output(["sysctl", "-n", "vm.loadavg", "hw.ncpu"], text=True)
                    load = float(raw_load.split()[1]) / cpus
                    record(dict(event="load-check", label=label, epoch=time.time(), load=load, raw=raw_load))
                    if load <= 0.70:
                        break
                    if time.monotonic() + 15 > end:
                        record(dict(event="abandoned", reason="no-quiet-window", label=label))
                        raise SystemExit(2)
                    time.sleep(15)
                if time.monotonic() + 30 > end:
                    record(dict(event="abandoned", reason="budget", label=label))
                    raise SystemExit(2)
                command = [args.binary, "timing", str(args.samples), str(rep), arm, "visible", hold]
                record(dict(event="start", label=label, epoch=time.time(), command=command, load=load))
                with (out / f"{label}.txt").open("w") as stdout, (out / f"{label}.err").open("w") as stderr:
                    try:
                        result = subprocess.run(command, env=env, stdout=stdout, stderr=stderr,
                                                timeout=min(end - time.monotonic(), args.samples * (float(hold) + 4) + 20))
                        record(dict(event="exit", label=label, epoch=time.time(), returncode=result.returncode))
                    except subprocess.TimeoutExpired:
                        record(dict(event="timeout", label=label, epoch=time.time()))
                print((out / f"{label}.txt").read_text(), flush=True)
record_end = dict(event="finished", epoch=time.time())
print(json.dumps(record_end), flush=True)
