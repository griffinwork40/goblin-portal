# Metal idle encode: where the spinner cost actually goes (#143, third pass)

**Date:** 2026-10-18 · **Machine:** Apple M4 Pro, 14 CPUs · **Display the window sat on:** external
ES-G27F4Q, **144 Hz**, 1x (the built-in is 120 Hz, 2x) · **Build:** release SwiftTerm (vendored,
`verify-vendor.sh` exit 0) · **Pane:** 137 cols x 46 rows, read back from `terminal.cols/rows`
after resizing the window until it matched (the 2026-10-11 harness asserts the size from a
point estimate; this pass did not trust it).

## Answer

**The cost is mostly not the Metal encode.** In a 12 Hz spinner, `MetalTerminalRenderer.draw(in:)`
is about a quarter to a third of the process's main-thread time. The largest share is
**CoreAnimation's per-tick display-link overhead**. Most of it is paid on ticks where Goblin
Portal has nothing to paint, because patch 0010's pacer keeps the link running for
`idleTicksBeforePause = 8` ticks after every paint.

The "it's the Metal present floor" conclusion of the 2026-10-11 doc came from a measurement
blind spot. That harness's `idle` mode drives `mtkView.setNeedsDisplay` directly, which bypasses the
pacer, so it showed **zero** display-link ticks. It therefore measured a floor that excludes the
largest cost centre of the real app path.

## Evidence

### 1. Sample buckets (main thread, spinner, shipped pacer, quiet run at load 5.4)

`sample <pid> 8` during steady state; inclusive counts; 175 busy samples ≈ 2.9 % of a core,
matching `ps` (2.2 to 2.9 %).

| Bucket | Samples | Share of busy |
|---|---|---|
| Display-link ticks (`display_timer_callback`) | 103 | 59 % |
| · `CA::Display::DisplayTimingsControl::power_state()` → `SLSDisplayStatusQuery` → `mach_msg` | 52 | 30 % |
| · `CA::Display::DisplayLink::align_phase_locked` / `timing_reference` → SLS `mach_msg` | 27 | 15 % |
| · our `TerminalDisplayPacer.tick` → `updateDisplay` (actual app work) | 7 | 4 % |
| `MetalTerminalRenderer.draw(in:)` | 57 | 33 % |
| `CA::Transaction::commit` | 15 | 9 % |

Process-wide top-of-stack is dominated by `mach_msg2_trap`. Each tick makes a **synchronous call
into WindowServer**, so every tick also costs WindowServer CPU. The app-side CPU% understates the
system-wide cost.

### 2. Tick counts (deterministic, load-independent)

The pacer was instrumented in a scratch clone; the shipped vendor was untouched. 240 spinner frames:

| `idleTicksBeforePause` | ticks | paints | resumes | ticks / paint |
|---|---|---|---|---|
| 8 (shipped) | 2160 | 240 | 240 | 9.0 |
| 2 | 720 | 240 | 240 | 3.0 |
| 1 | 480 | 240 | 240 | 2.0 |

`resumes == paints` in **every** variant. A 12 Hz producer's gap (83 ms) is longer than 8 ticks at
144 Hz (56 ms), so the link already pauses and resumes once per frame. The 7 extra idle ticks per
frame buy nothing. The pacer's stated reason for 8 ticks ("a steady stream never
pause/resume-churns", `MacDisplayLinkPacer.swift:22-24`) does not apply to producers slower than
the window. At 144 Hz that is about 108 wasted CA ticks per second per spinning pane.

### 3. CPU, normalised for the clock confound

Raw CPU% is **bimodal across runs of identical code**: `draw(in:)` p50 is about 450 µs in some
runs and about 1,000 µs in others. That pattern looks like CPU frequency or cluster placement,
and it means a quiet machine can read *higher* CPU% than a busy one. Comparing raw `ps`% across
runs is therefore unreliable on this machine, which also undermines the single-run figures in
both earlier docs. The comparison below uses CPU spent outside `draw(in:)` per frame divided by
the same run's draw cost, which cancels the clock state:

| Run | ticks / paint | outside-draw ÷ draw |
|---|---|---|
| fast-clock runs, k = 8 (shipped) | 9.0 | 3.48, 3.66 |
| fast-clock runs, k = 2 | 3.0 | 2.82, 2.65 |
| fast-clock runs, k = 1 | 2.0 | 2.50, 2.55 |
| slow-clock runs, shipped | 9.0 | 2.24, 2.17 |
| slow-clock runs, adaptive (below) | 2.0 | 1.79, 1.81, 1.79 |

Per frame, at matched clock state, removing the 7 idle ticks cuts **total** process CPU by about
14 % (slow clock) to 24 % (fast clock: about 2,140 → 1,635 µs/frame). That works out to roughly
40 to 70 µs of app CPU per idle tick, plus the WindowServer side, which was not isolated
because WindowServer `ps` is too noisy at this load. The `draw(in:)` cost itself does not change.

## Shipped as patch 0016 (same day)

`patches/swiftterm/0016-pause-sooner-for-slow-producers.patch` implements the rule below
in `MacDisplayLinkPacer.swift`, with a `SWIFTTERM_ADAPTIVE_PAUSE=0` kill switch. Evidence:

- `check-display-link.sh` case 9 (new), both renderers: a 200ms producer reads **1.0**
  link ticks per paint with 0016 and **8.0** with the switch off, which is the falsification.
  A 33ms stream shows exactly 1 pause. Direct runs show it is the burst-start pause: 1 with
  0016, 0 without, at both 16ms and 33ms, and every frame is painted in both cases.
  Cases 1 to 8 are unchanged and green.
- CPU A/B, one binary, interleaved, quiet machine (load about 2), 137x46, 240 spinner
  frames: shipped **4.85 / 4.57 / 4.63 %** of a core (this reproduces #143's original 4.4 %),
  0016 **3.22 / 4.61 / 3.76 %**. The outside-draw ÷ draw ratio is 2.01 / 1.93 / 1.96 vs
  1.76 / 1.52 / 1.63, about **17 %** less process CPU. The high adaptive rep coincides with
  a slower draw (1,520 µs vs about 1,300 µs), the same clock confound as above.
- `verify-vendor.sh` exits 3 on a tree with 0010 but not 0016 (one combined pin hash).
  Green: `check-metal-renderer.sh`, `check-metal-throughput.sh` (ratio 0.798),
  `check-file-size.sh`, `check-afk-loc.sh`, `swift build`. `check-render-parity.sh` exited
  2 (environmental: it needs a 2x main screen, and this run's main screen was the 1x
  external). 0016 touches no drawing code.

## Proposed fix (as prototyped)

**Adaptive pause.** On each paint, check whether the gap since the previous paint was longer than
the idle window (`idleTicksBeforePause × tick duration`). If it was, the producer is slower than
the link can bridge, so pause after **1** idle tick instead of 8. Fast producers have short gaps,
so their behaviour is unchanged by construction.

| Producer | Shipped ticks / resumes | Adaptive ticks / resumes |
|---|---|---|
| 12 Hz spinner (240 frames) | 2160 / 240 | **480** / 240 |
| 60 fps stream (600 frames) | 1481 / 1 | 1479 / 1 |
| 30 fps stream (600 frames) | 2904 / 1 | 2902 / 2 |

Adaptive cuts spinner ticks by 78 % and adds no churn to streams. It only ever pauses *sooner*, so
`check-display-link.sh` case 4 (paused after a burst) cannot regress. The prototype diff
(instrumentation removed) is about 10 lines in `MacDisplayLinkPacer.swift`. Landing it means a new
`patches/swiftterm/0016-*`, the pin hash in `verify-vendor-views.sh`, and a green run of
`check-display-link.sh`, `check-metal-renderer.sh` and `check-metal-throughput.sh`.

## What remains after the fix, and the bigger lever

At k = 1 the outside-draw cost is still about 2.5x the draw cost. That covers two ticks and one
link *resume* (the `align_phase_locked` SLS round trip), plus CA commit. A slow producer gains
nothing visible from vsync phase alignment, so painting it directly instead of resuming the link
would remove most of that remainder. That changes 0010's contract ("paint only on a tick"), so it
needs its own measurement and a stutter check before it is proposed. Not prototyped.

## Not checked

- WindowServer CPU attributable to ticks. `ps` on WindowServer swung 3 to 66 % per reading under
  a background `node` at 200 %. Needs a quiet machine, or an Instruments trace of the
  `SLSDisplayStatusQuery` server side.
- 60 Hz and 120 Hz displays. The idle window is 133 ms at 60 Hz, so a 12 Hz spinner (83 ms gap)
  does **not** churn there. The link never pauses, every tick between paints is idle, and adaptive
  does not trigger. The waste per frame is then (ticks per frame − 1) = 4 at 60 Hz, which needs a
  time-based rule instead. Measure before generalising.
- The real app, as opposed to the harness. Same vendored pacer, same code path, but there is no
  in-app tick counter yet. `FramePacingDiag` (patch 0010's `frameTimingObserver`) counts paints,
  not ticks.

## Reproduction

The scratch harness (`measure-metal-idle-encode-harness.swift` + size-to-137x46 loop +
`FRAMES` env), the instrumented clone, the raw outputs, the `sample` files and
`prototype-adaptive-pause.diff` live in the main checkout's untracked `.afk/scratch-143/`. Not
committed: the clone is a full vendor copy.
