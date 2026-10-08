# N6 load-guard falsification transcript — 2026-10-05

Gate: `app/Scripts/check-metal-throughput.sh`
Machine: 14-core Apple Silicon, macOS 27.0.1
Baseline load: 12.77 (1m), 11.93 (5m), 12.53 (15m) — machine was already busy

## Falsification run (LOADGUARD_FALSIFY=1)

```
==> falsification: spawning synthetic load workers (13 yes-workers)…
   waiting 8 s for load to climb…
   load1=14.95  ncpu=14  threshold=0.70/cpu
   FALSIFICATION OK — guard fires under synthetic load (load1=14.95, ncpu=14)
==> killing workers, waiting 10 s for load to settle…
[13× "Terminated: 15  yes > /dev/null"]
   load1=14.36  ncpu=14  threshold=0.70/cpu
   NOTE: load still above threshold (0.70/cpu) after workers stopped.
   This machine had background load before the test; the quiet-machine assertion cannot be made.
   falsification done; continuing to normal run

building SwiftTerm first (the harness links the vendored module)…
==> load check before run: load1=14.01, ncpu=14, threshold=0.70/cpu
error: environmental: machine busy — load1=14.01 on 14 cpus exceeds 0.70/cpu threshold.
  A busy machine makes the drawable-gap ineffective; ratio would measure scheduler
  wait, not renderer cost. Re-run when the machine is quieter.
EXIT: 2
```

## Interpretation

The guard fires correctly when load is high: `14.95/14 = 1.07` per CPU >> threshold 0.70.
The gate exits 2 (environmental) rather than 1 (renderer regression) — the correct contract.

The machine could not settle below 0.70/cpu after workers were killed because it had
substantial background load (12-13) before the test. That prevents asserting "guard does NOT
fire on a quiet machine" from this particular run. The "quiet machine" half of the falsification
requires running the test on a machine with load1 < 0.70/ncpu ≈ 9.8, which this machine was not.

## Reasoning for the 0.70/cpu threshold

- Observed failure mode: ratios 0.67-0.72 at load 12-15 on 14 cores = 0.86-1.07/cpu.
- Observed pass: ratio 0.801 the following day (same code, quieter machine).
- Gap between failure zone (>0.86/cpu) and threshold (0.70/cpu): 0.16/cpu = ~18% headroom.
- At 0.70/cpu (9.8 load on 14 cores) the GPU scheduler has substantial idle time and
  drawable-pool starvation is not the observed failure mode.
- At 0.90+/cpu the drawable gap is demonstrably ineffective (five failures documented).
