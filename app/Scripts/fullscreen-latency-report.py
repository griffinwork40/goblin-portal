#!/usr/bin/env python3
# Owns log parsing and verdicts for check-fullscreen-latency.sh, separate so AX
# orchestration stays readable. Thresholds are from the 2026-11-20 measurements
# in .afk/research/fullscreen-typing-lag-2026-11-20.md, not a synthetic timing loop.
import pathlib
import re
import sys


def parse(path):
    phase = None
    samples = {"W": [], "F": []}
    for line in path.read_text().splitlines():
        if line.startswith("##### "):
            phase = line[len("##### "): ]
        if phase not in samples or "[diag] keys:" not in line:
            continue
        fields = dict(re.findall(r"(\w+)=([^\s]+)", line))
        try:
            paired = int(fields["paired"])
            maximum = float(fields["output_frame_max"])
            fullscreen = fields["fullscreen"] == "true"
        except (KeyError, ValueError) as error:
            raise ValueError("malformed recorder line") from error
        if paired:
            if fullscreen != (phase == "F"):
                raise ValueError(f"{phase}: recorder fullscreen context disagrees")
            if not (0 <= maximum < float("inf")):
                raise ValueError("non-finite or negative latency")
            samples[phase].append((paired, maximum))
    result = {}
    for name, rows in samples.items():
        if not rows:
            lines = path.read_text().splitlines()
            markers = [line for line in lines if '#####' in line]
            key_lines = sum('[diag] keys:' in line for line in lines)
            raise ValueError(f"{path.stem} {name}: no paired recorder samples; "
                             f"key_lines={key_lines}, markers={markers}")
        result[name] = (sum(row[0] for row in rows), max(row[1] for row in rows))
    return result


def main():
    directory = pathlib.Path(sys.argv[1])
    falsify = sys.argv[2] == "1"
    labels = ["shipped", "delayed-blink"] if falsify else ["shipped"]
    try:
        runs = {label: parse(directory / f"{label}.log") for label in labels}
    except (OSError, ValueError) as error:
        print(f"environment: {error}", file=sys.stderr)
        return 2
    print("RUN             CASE            PAIRED  MAX(ms)  OBSERVED  REQUIRED")
    failed = False
    for label, phases in runs.items():
        for name in ("W", "F"):
            paired, maximum = phases[name]
            passed = maximum < 60
            expected = "FAIL >150" if label == "delayed-blink" and name == "F" else "PASS <60"
            print(f"{label:15} {name + '-output-frame':16} {paired:6} {maximum:8.2f}  "
                  f"{'PASS' if passed else 'FAIL':8}  {expected}")
            if expected == "PASS <60" and not passed:
                failed = True
        paired, maximum = phases["F"]
        print(f"{label:15} {'F-paired':16} {paired:6} {'—':>8}  "
              f"{'PASS' if paired >= 20 else 'FAIL':8}  >=20")
        if paired < 20:
            failed = True
    if failed:
        print("FAIL: a shipped case, windowed control, or paired-key case failed")
        return 1
    if falsify and runs["delayed-blink"]["F"][1] <= 150:
        print("environment: delayed blink did not reproduce >150 ms; this machine or OS "
              "no longer reproduces the defect, so the gate cannot be judged here")
        return 2
    print("PASS: latency cases and delayed-blink falsification" if falsify else
          "PASS: latency cases only (falsification explicitly skipped)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
