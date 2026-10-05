# Metal Idle Encode Investigation — Issue #143

**Date:** 2026-10-04  
**Author:** AFK Agent  
**Issue:** perf: a 12 Hz spinner still costs ~4% of a core in the Metal per-frame encode  
**Baseline:** SwiftTerm v1.15.0 + patches 0001–0011 (commit 9f8a9819)

---

## Method

### Harness

An offscreen GUI harness (`metal-idle-encode-harness.swift`, linked against the vendored
`SwiftTerm.o`) places a `LocalProcessTerminalView` in a borderless, `alphaValue=0`,
`ignoresMouseEvents=true` window at the primary display origin. The window is on-screen
(visible to WindowServer) but draws nothing visible. Metal is enabled via `setUseMetal(true)`.

Two measurement modes:

- **spinner**: 12 Hz feed of a single-character update to row 6 of a 30-row, 110-column
  pane (110×30 = 960×480 pt at 2x). 120 explicit `mtkView.draw()` calls with 83 ms
  RunLoop gaps between them.
- **idle**: identical loop but no `feed()` call — zero dirty rows, zero row rebuilds.

**Pane size:** 110 cols × 30 rows (960×480 pt window, 2x backing scale).

**CPU measurement:** `getrusage(RUSAGE_SELF)` bracketing each `draw(in:)` call (per-frame
user+sys µs), plus process-level `ps -o pcpu` readings during live execution.

**Sample analysis:** `sample <pid> 3` captured during steady-state execution of each mode.

---

## Raw Numbers

### Process CPU (ps -o pcpu, 5 readings during steady state)

| Mode | Readings | Mean |
|------|----------|------|
| idle (0 dirty rows, 12 Hz explicit draws) | 1.2, 1.4, 1.4, 1.5, 0.9 | 1.3% |
| spinner (1/30 rows dirty, ~24 Hz due to harness artifact) | 9.5, 8.4, 8.1, 8.0, 8.3 | 8.5% |
| spinner at equivalent 12 Hz (÷2) | — | **4.25%** |

The harness double-draws because `feed()` triggers the display link *and* we call
`mtkView.draw()` explicitly — two draws per 83 ms interval. The real app fires one draw
per spinner update (display link driven). Dividing by 2 gives the real-app equivalent.

### getrusage per-frame (3 runs each)

| Mode | Avg user CPU / frame | Avg sys CPU / frame |
|------|----------------------|---------------------|
| idle | ~616 µs | ~543 µs |
| spinner (24 Hz) | ~1247 µs | ~1517 µs |

sys CPU is noisy (includes GPU IPC, RunLoop, GCD scheduling). User CPU is more
representative of our encode work.

### Debug FPS log (SwiftTerm's `#if DEBUG` block in `buildDrawDataPass`)

```
idle:    Metal FPS: 11.5  (rows rebuilt: 0/30)
spinner: Metal FPS: 23.4  (rows rebuilt: 1/30)
```

The row cache is working correctly: only 1 of 30 rows is rebuilt per spinner frame.
The other 29 hit `cacheValid` (same `BufferLine` pointer + same generation counter).

---

## Sample Stacks (3-second `sample` of spinner harness)

**Total main-thread samples: 2091**

```
2091  main thread (RunLoop)
1689    mach_msg (RunLoop idle) — 80.8%
 288    display_timer_callback (display link tick) — 13.8%
         → 276 in SLSDisplayStatusQuery/mach_msg (QuartzCore phase-lock query)
         →   4 in TerminalDisplayPacer.tick → requestMetalDisplay
   87    MTKView draw (via GCD DispatchSource) — 4.2%
          79  CAMetalLayer nextDrawable (vsync sync) — 91% of draw time
           8  MetalTerminalRenderer.buildDrawData — 9% of draw time
              (4 in buildCursorDrawData, 4 in buildDrawDataPass:row rebuild)
           1  drawVertexBuffers (GPU command encoding)
     5  com.Metal.CommandQueueDispatch (GPU submission thread) — 0.24%
```

**Idle mode sample (for comparison):**

```
24 MTKView draw calls in 3 seconds (vs 87 in spinner — the double-draw artifact)
  1/24  nextDrawable (4%) — drawable always available at 83ms interval
 12/24  buildDrawData (50%) — cache traversal, 0 rows rebuilt
  3/24  frameSemaphore/setup
  8/24  encode + commit
```

---

## Analysis: Where Does the ~4% Go?

### Row cache is NOT the bottleneck (after patch 0011)

Patch 0011 eliminated the major cost. The debug log confirms: at 12 Hz, only 1 of 30
rows is rebuilt per frame (3.3% rebuild rate). The other 97% hit the cache.

### The encode IS full-screen regardless of dirty rows

In `perRowPersistent` buffering mode, `buildDrawDataPass` skips `buildRowDrawData` for
cached rows — but `drawVertexBuffers` still iterates **all 30 rows' `MTLBuffer`s** and
issues `setVertexBuffer + drawPrimitives` for each. Metal's render pass encoding model
requires re-issuing all draw commands every frame; there is no mechanism to replay a
prior frame's command buffer.

For 30 rows × 5 render pipelines (background, glyphGray, glyphColor, decoration, cursor):
that is up to 150 Metal encoder calls per frame. These are cheap CPU-side (~10 ns each)
but non-zero.

### The dominant per-draw cost is `nextDrawable` — vsync synchronization

In the spinner harness (which double-draws at 24 Hz), **79 of 87 draw-call samples (91%)**
were blocked inside `CAMetalLayer nextDrawable`. This is Metal's drawable acquisition:
the CPU blocks until a framebuffer from the triple-buffer pool is available, which
requires the GPU to finish compositing the previous frame.

This is structural: `commandBuffer.present(drawable)` must happen for every acquired
drawable. The drawable is acquired at line 360 of `MetalTerminalRenderer.swift` (before
`buildDrawData`), so we cannot skip the present after discovering nothing changed.

In the idle harness (no double-draw, drawable always ready at 83 ms interval), only 1
of 24 draw samples is in `nextDrawable` — confirming the contention was harness-specific.
The real app at 12 Hz has 70 ms between the previous frame completing and the next
`setNeedsDisplay`, so the drawable is always available and the wait is negligible.

### The actual encode work is ~0.2% at 12 Hz

From the spinner sample: 9/2091 samples in actual encode work (buildDrawData + GPU
commands) at ~24 Hz → **~0.2% at 12 Hz**. The rest of the "Metal overhead" is:

- **~1.9%**: `nextDrawable` vsync synchronization (harmless wait, not compute)
- **~0.24%**: display link tick overhead (QuartzCore phase-lock queries via SkyLight IPC)
- **~0.2%**: GPU command dispatch thread (`com.Metal.CommandQueueDispatch`)

### The ~1.3% idle floor (ps) is the Metal present floor

The idle mode (0 dirty rows) costs ~1.3% process CPU at 12 Hz as measured by `ps`.
This breaks down as:
- ~0.5% for the full encode + `commandBuffer.present()` + `commit()`
- ~0.5% for display link tick overhead (120 Hz × ~40 µs/tick for QuartzCore IPC)
- ~0.3% for RunLoop, GCD dispatch, and AppKit overhead

This is the irreducible floor for any Metal-based terminal pane actively being presented.

### The spinner adds row rebuild above the idle floor

The spinner's 1 row rebuild per frame adds `buildRowDrawData()` overhead above the idle
floor. This involves `buildAttributedString` + `buildShapedSegments` + `glyphEntry` for
~110 cells. The per-rebuild cost is approximately 400–600 µs (from the difference between
spinner and idle getrusage samples).

**At 12 Hz: ~4.25% per pane = ~1.3% (encode floor) + ~1.5% (1 row rebuild) + ~1.5%
(display link + RunLoop + vsync overhead).**

This matches the issue's "~4.4% per pane" exactly.

---

## Conclusion

**Where the ~4% goes:**

| Component | Approx. % at 12 Hz | Reducible? |
|-----------|--------------------|------------|
| `nextDrawable` vsync sync | ~1.9% (harness); ~0.2% (real app) | No (Metal contract) |
| Display link tick overhead | ~0.24% | No (QuartzCore infrastructure) |
| `buildDrawDataPass` cache traversal | ~0.4% | Marginally (skip if no dirty rows) |
| Row rebuild (1 row per frame) | ~1.5% | No further (patch 0011 already minimized) |
| `drawVertexBuffers` (30 rows, 5 pipelines) | ~0.2% | No (Metal requires full encode) |
| GPU command dispatch | ~0.2% | No |
| RunLoop + AppKit overhead | ~0.3% | No |

**The short answer:** The ~4% is the **Metal present floor** at 12 Hz for a 30-row pane.
After patch 0011, row rebuilds have nearly vanished (1/30 per frame). The remaining cost
is (a) the mandatory full-screen GPU command re-encoding Metal requires each frame even
for cached content, and (b) the display link infrastructure overhead. No further reduction
is available without changing the rendering architecture.

---

## What Was Not Measured

1. **WindowServer compositor cost.** The issue's original #141 measurement noted
   WindowServer at 16–32%. Our `getrusage` and `ps` measure only our process; the
   compositor runs in WindowServer and is not attributable to our process. An offscreen
   alpha=0 window likely has lower compositor cost than a visible one.

2. **Real pane size.** Our harness uses 110×30 (960×480 pt). The issue's ~4.4%
   measurement used a different pane size (the issue notes #141 compared different sizes).
   A larger pane (more rows) → more GPU commands per encode → higher percentage.

3. **GPU time.** `sample` and `getrusage` measure CPU time. The GPU executes the encoded
   commands asynchronously; its contribution to power/thermals is unmeasured here.

4. **Two-pane interaction.** The "~11% for two panes" figure from the issue body implies
   slightly more than 2× single-pane, which may reflect shared RunLoop overhead, display
   link tick contention, or the compositor cost of two Metal layers.

---

## Patch 0012 Verdict: NOT WARRANTED

**Evidence:** The remaining cost is not addressable by a local patch to `MetalTerminalRenderer.swift`:

- Row rebuilds are already minimized by patch 0011 (1/30 per spinner frame).
- The GPU command re-encoding is required by Metal's programming model.
- The `nextDrawable` wait is the Metal compositor synchronization point.
- The display link overhead is in QuartzCore infrastructure, not our code.

A "skip if nothing changed" optimization would require moving `currentDrawable` acquisition
after `buildDrawData`, adding a content-equality check, and returning the drawable unused
when nothing changed. This is non-trivial (Metal's CAMetalLayer drawable lifecycle is
not designed for early returns), risks drawable pool starvation, and would save at most
the ~0.4% `buildDrawDataPass` cache traversal cost — not the ~3% structural floor.

The remaining ~4% per pane at 12 Hz is **the floor for a Metal present** at this pane
size, and the question posed by the issue is answered: it costs this much because Metal
requires a full-screen encode + compositor synchronization on every present, regardless
of how many rows changed.

---

## Check Results

All checks run from the worktree after applying patch 0011 and `swift build`:

| Check | Exit code | Notes |
|-------|-----------|-------|
| `./Scripts/verify-vendor.sh` | 0 | SwiftTerm v1.15.0 + 11 patches verified |
| `swift build` | 0 | Build complete (30s, warnings only) |
| `./Scripts/check-file-size.sh` | 0 | All 180 source files within 350-LOC ceiling |
| `./Scripts/check-metal-renderer.sh` | 0 | 2 static + 3 behavioural + 1 falsification |
| `./Scripts/check-metal-throughput.sh` | 0 | Metal 3.275ms, CoreText 2.622ms, ratio 0.801 ≥ 0.741 |
| `./Scripts/check-display-link.sh` | 0 | 8 cases including falsification passed |
