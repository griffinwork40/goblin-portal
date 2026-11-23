# Fullscreen typing lag on the built-in display: root cause and fix (2026-11-20)

**Report:** typing feels laggy in native fullscreen on the MacBook Pro built-in display.

**Root cause:** `CaretView.resetBlinkAfterInput()` (vendored SwiftTerm, `Mac/MacCaretView.swift`)
runs on every keystroke. It replaced the caret's blink with a `CABasicAnimation` whose
`beginTime` was 0.7 s in the future. While such an animation is pending, in native fullscreen on
the built-in variable-refresh (ProMotion) panel, the terminal's Metal frames are drawn and
committed on time but are not put on screen until the animation starts. Typed characters
therefore appear in bursts about every 690 ms.

**Fix:** vendor patch `0017-restart-caret-blink-from-timer.patch`. The blink is restarted from a
cancellable 0.7 s main-queue work item, so no Core Animation animation is pending while the user
types. The caret looks the same: solid for 0.7 s after input, then the same fade.

**Not established:** why the window server defers a layer's presents behind a pending animation.
Nothing here explains that; the fix removes the trigger.

Machine: M4 Pro, macOS 27.2.1, built-in Liquid Retina XDR (refresh interval 8.3 to 41.7 ms) plus
an external fixed 144 Hz monitor. Metal renderer. Reproduced on the released v1.25.0 build and on
`main`.

## Instruments

1. `[diag] keys:` line (`KeyLatencyDiag.swift`, added in the same change): per second of typing,
   key to pty output, output to the frame's GPU completion, and key to frame.
2. Temporary instrumentation of `TerminalMetalLayerRenderSurface.acquireDrawableFrame()`: time
   spent in `nextDrawable()`, the calling thread, and `MTLDrawable.presentedTime` through
   `addPresentedHandler`, which is the time the frame reached the glass. Not shipped.

Workload for every number below: 35 real key events at 110 ms, at a zsh prompt.

## Decisive measurements (interleaved trials on one binary, fullscreen, built-in display)

| Variant | Trials | Frames over 100 ms to glass | Worst to glass | Worst output to frame |
|---|---|---|---|---|
| Shipped: blink reset with future `beginTime` | 3 | 27/41, 19/30, 25/38 | 577, 548, 694 ms | 407, 637, 380 ms |
| Blink restarted from a timer (the fix) | 3 | 0/73, 0/73, 0/74 | 18, 18, 17 ms | 6.6, 11.9, 2.8 ms |
| Steady caret (DECSCUSR 2) | 2 | 0/68, 0/68 | 16, 18 ms | 8.5, 4.6 ms |
| Blinking control, same batch as steady | 2 | 29/45, 26/42 | 700, 700 ms | 519, 524 ms |

Per-frame trace of a stalled trial: frames are acquired with no wait and reach the glass about
530 ms later, in a burst of three or four, roughly every 690 ms. An idle blinking caret is not
affected (its animation is running, not pending): blink frames reach the glass in 9 ms.

## Where it does and does not happen

| Condition | Worst output to frame |
|---|---|
| Windowed, built-in display | 4 to 12 ms |
| Fullscreen, built-in display, Metal | 380 to 637 ms |
| Fullscreen, external fixed 144 Hz monitor | 9.6 ms (one run) |
| Fullscreen, built-in display, Core Text renderer | 27 ms (one run) |
| Fullscreen, built-in display, MTKView surface | 538 ms (one run) |

## Hypotheses that were wrong, and what refuted them

- **The program being typed into is slow.** Key to pty output stayed near 5 ms during stalls.
- **The frame driver is suspended after the fullscreen transition (#302 class).** The display link
  kept ticking and idle ticks were counted during stalls.
- **A paused display link lets the compositor throttle (the premise of patch 0014).** Holding the
  link at 120 ticks/s did not help: 537 ms.
- **Drawable pool exhaustion from vsync queuing; cure by `displaySyncEnabled = false`.** One run
  looked cured (6.7 ms). Repeats did not hold: clean in 2 of 3 valid trials, stalled in a gate run
  and in 3 of 3 trials with an added Core Animation commit. A `sample` did show `nextDrawable`
  blocked on both the render and main threads, but that is a consequence of unshown frames
  holding the pool, not the cause. A patch built on this was written and withdrawn.
- **The compositor needs any Core Animation commit to pick up the frames.** Committing a
  transaction after every frame did not help.
- **Drawable size churn in fullscreen.** The size was stable and integral (2936x2152) throughout.

## Why the first night's attempts did not reproduce it

They wrote bytes straight to the pane's tty. No key event means `resetBlinkAfterInput()` never
ran, so no animation was pending. Those runs also measured frame counts and main-thread idle
time, not key-to-frame latency. One run that night used real key events and still showed no
stall; that is unexplained.

Two single-run anomalies that night were discarded because they did not replicate. In hindsight
one of them (a link-less presenter losing 26 of 30 frames in fullscreen) may have been the same
compositor behaviour, but it was never re-measured.

## Lesson for this repo

Three conclusions in this investigation rested on a single run and two of them were wrong. The
stall is deterministic once the trigger is known, but until then single runs misled in both
directions. Interleaved repeats on one binary, with an env switch per variant, are what settled it.

## Regression gate

`app/Scripts/check-fullscreen-latency.sh` (local only: takes focus, needs the built-in
variable-refresh display and Accessibility). It forces a blinking caret, types windowed and in
fullscreen, and requires the fullscreen worst output-to-frame under 60 ms. Falsification relaunches
with `SWIFTTERM_CARET_DELAYED_BLINK=1` (the old behaviour) and requires the stall to return.
First full run: shipped 9.3 ms windowed and 8.5 ms fullscreen; old behaviour 8.1 ms windowed and
539 ms fullscreen.

## Not checked

- Other macOS versions, other variable-refresh displays, and Low Power Mode.
- Tearing or power cost: the fix changes neither presentation nor pacing, so none is expected.
- Whether patch 0014's synchronous main-thread draw is still needed now that the trigger is gone.
- `iOSCaretView.swift` has the same future-dated animation and was left alone.
