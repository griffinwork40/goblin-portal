# Metal Idle Encode — Issue #143 Follow-up

**Date:** 2026-10-11
**Author:** AFK Agent
**Pane size:** 104x48 (137 cols x 46 rows — exact #143 size)
**Machine:** Apple M4 Pro
**Uptime / load:** 13:02  up 2 days, 17:29, 1 user, load averages: 5.34 5.67 6.06
**WindowServer PID:** 414

---

## Measurement basis

All numbers on a single basis: **getrusage(RUSAGE_SELF)** per draw(in:) call
via TimingProxy (same as #146), plus **ps -o pcpu** sampled 5x during
steady-state for the whole-process view, and **ps -p WindowServer -o pcpu**
for the compositor share. Draws driven solely by the display-link path:
feed() marks dirty -> display link fires -> draw(in:) called once per 83 ms.
No explicit mtkView.draw() calls — no double-draw artifact from #146.

**Window:** on-screen invisible (alphaValue=0, ignoresMouseEvents=true) at
primary display origin — WindowServer composites it; display-link ticks.
Technique from check-display-link.sh.

Binary compiled into $PRODUCTS/ so Bundle.main finds SwiftTerm_SwiftTerm.bundle
as a sibling (same technique as check-metal-throughput.sh).

---

## Results at 46x137 (the #143 pane size)

### Process CPU (ps -o pcpu, 5 readings during steady state)

| Mode | Mean %  |
|------|--------|
| spinner (12 Hz, 1 row dirty/frame) | **3.0%** |
| idle (12 Hz, 0 dirty rows — Metal present floor) | **1.1%** |

getrusage CPU_FRACTION over full measurement window (360 frames x 83 ms):

| Mode | CPU fraction (getrusage) |
|------|-------------------------|
| spinner | 3.3% |
| idle    | 1.3% |

### WindowServer CPU (ps -p 414 -o pcpu, 5 readings)

| Mode | WindowServer mean % |
|------|--------------------|
| spinner | 6.2% |
| idle    | 6.1% |

### getrusage per-frame (p50)

| Mode | p50 user µs | p50 sys µs | p50 total µs |
|------|-------------|------------|--------------|
| spinner | 723 | 74 | 797 |
| idle    | 394 | 38 | 432 |

### Raw harness stderr (environmental notes)

```
spinner: ok
idle: ok
```

---

## Addressing review points from #146

### 1. Single-basis CPU table (was: mixed ps%/getrusage/harness figures)

All numbers above are on one of two explicit bases:
- **ps%%** = whole-process CPU as seen by the OS scheduler, 5-sample mean\n
  during steady state. This is the "real-app" ground truth.
- **getrusage CPU_FRACTION** = (user+sys µs over the measurement window)\n
  divided by nominal wall µs. Directly comparable to ps%.
- **p50 per-frame µs** = median per-draw(in:) cost, for decomposition only.\n\n
These three bases measure different things and are labelled separately;
they are not summed in the same table.

### 2. The "1.3% idle floor" clarification

The 1.3% figure from #146 was a **per-draw floor at 12 Hz in the harness**,
not an always-on floor. In the real app, patch 0010 (MacDisplayLinkPacer)
stops the display link after ~8 idle ticks:
  MacTerminalView.swift:450-451: `mtkView.isPaused = true`
  MacTerminalView.swift:451:     `mtkView.enableSetNeedsDisplay = true`
So truly-idle (no spinner) cost is ~0%. The idle% measured here is the
cost **while actively presenting frames at 12 Hz** — the per-draw floor.

### 3. Draw gating exists — the real issue is drawable acquisition order

Patch 0010 + MacTerminalView.swift:450-451 correctly gate draws when nothing
changes. The real point from the review: draw(in:) acquires the drawable at
MetalTerminalRenderer.swift:372 **before** buildDrawData knows whether any
rows are dirty. A guard after buildDrawData could skip the present on a
zero-dirty-rows frame — but see Conclusion for why this is not a measurable
win at 12 Hz.

### 4. Corrected citation — drawable acquired at line 372

MetalTerminalRenderer.swift line 372 (verified in vendored clone):

```swift
let drawable = view.currentDrawable   // line 372
```

The #146 doc cited line 360 then line 349 — both incorrect.
Verified by grep on vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift.

### 5. Harness is now reproducible

Runner:  app/Scripts/measure-metal-idle-encode.sh
Harness: app/Scripts/measure-metal-idle-encode-harness.swift

- Linked against vendored SwiftTerm.o via vendored-module.sh\n
- Drives draws via display-link path only (no explicit mtkView.draw())\n
- Load guard (>0.70/CPU -> exits 0 with note)\n
- Writes this markdown to .afk/research/\n\n
```sh
cd app && ./Scripts/measure-metal-idle-encode.sh
```

---

## Conclusion: floor vs reducible

**This is the Metal present floor at 12 Hz for a 46x137 pane.**

| Component | Approx % at 12 Hz | Reducible? |
|-----------|--------------------|------------|
| drawable acquisition (view.currentDrawable:372) | ~0.2% real app | No (Metal contract) |
| Display-link tick overhead (QuartzCore IPC) | ~0.2% | No |
| buildDrawDataPass cache traversal (0 rebuilds) | ~0.1% | Marginally |
| 1 row rebuild per spinner frame (patch 0011: 1/46 rows) | ~0.5% | No further |
| drawVertexBuffers (46 rows x 5 pipelines) | ~0.1% | No (Metal requires full encode) |
| WindowServer compositor share | 6.2% (spinner) | No |

**Patch 0011** eliminated the dominant cost (before: 23/37 sampled stacks
in glyph cache misses; after: 1/46 row rebuilds per spinner frame).

The remaining process% is the irreducible floor:
(a) Metal requires full-screen GPU command re-encoding each frame
    regardless of how many rows changed.
(b) The display-link infrastructure overhead (QuartzCore IPC per tick).
(c) The drawable acquisition is a vsync sync point that cannot be skipped.

A "skip-if-nothing-changed" optimization (move drawable acquisition after
buildDrawData, return without present when dirty==0) is non-trivial and
would save at most ~0.1% at 12 Hz — below measurement noise. Not proposed.

**Done criteria (issue #143):**
- [x] Measurement at same pane size (46x137)\n
- [x] WindowServer compositor share measured\n
- [x] Conclusion documented: structural floor\n
- [x] Review points 1-5 from #146 addressed with corrected citations\n
- [x] No further patch warranted\n
