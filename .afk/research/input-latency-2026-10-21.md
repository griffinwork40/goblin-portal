# T3.1 keystroke latency: measured, patch dropped (2026-10-21)

**Verdict: MEASUREMENT-ONLY.** The roadmap's rule for T3.1 was "must show a delta or the patch
is dropped". The delta is real but tiny (tens of µs), two orders of magnitude below the
1,000 µs floor the gate sets, so no `0017` vendor patch was written.

## Hypothesis under test

A1a GAP 3 (`.afk/research/best-mac-terminal-2026-10-07/A1a-perf.md`) said SwiftTerm's
keystroke write, `LocalProcess.send(data:)` → `DispatchIO.write` on a `.userInitiated` global
queue (`vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:215-241`), adds "0.1–5 ms"
of GCD jitter, with "45–65 ms structural" key-to-photon latency. Both numbers were ESTIMATES.
The proposed fix was a synchronous non-blocking `write(2)` for small payloads.

## Method (`app/Scripts/check-input-latency.sh` + `-harness.swift`)

- Links the RELEASE vendored `SwiftTerm.o`, the same tree `verify-vendor.sh` passes (v1.15.0
  + 16 patches, bootstrapped by `bootstrap-vendor.sh`).
- The child is `/bin/sh -c 'stty raw -echo; printf READY; exec cat'` on a real pty spawned by
  `LocalProcess.startProcess`, so the echo crosses the same read loop (own queue) and main-queue
  hop that the app's echo takes before SwiftTerm feeds it.
- **app arm**: `LocalProcess.send(data:)`, the exact call `MacLocalTerminalView.send(source:data:)`
  makes for every keystroke (`Mac/MacLocalTerminalView.swift:145-147`).
- **floor arm**: bare `write(2)` of the same byte on the same `childfd`. Any sync-write patch adds
  a branch on top of this path and cannot go below it, so `app − floor` is an UPPER BOUND on T3.1's win.
- The two arms alternate sample by sample so drift cancels. The first 20 samples are warm-up and
  dropped. Each echoed byte is checked against the byte sent.
- Two regimes: burst (no gap) and typing (a 20 ms gap so dispatch's worker threads go idle, the
  case GAP 3 worried about).
- Load guard: exit 2 at more than 0.70/CPU before or after (N6).

## Numbers (M4 Pro, 14 CPUs, 590 samples per arm, two consecutive clean runs)

| run | load (before → after) | regime | app p50 / p95 µs | floor p50 / p95 µs | delta p50 / p95 µs |
|---|---|---|---|---|---|
| 2 | 0.55 → 0.54 /CPU | burst | 25.1 / 49.6 | 17.8 / 32.1 | **+7.2 / +17.5** |
| 2 | | typing | 221.6 / 306.0 | 167.0 / 222.4 | **+54.6 / +83.6** |
| 3 | 0.56 → 0.12 /CPU | burst | 46.6 / 72.3 | 29.3 / 44.8 | **+17.3 / +27.5** |
| 3 | | typing | 222.2 / 322.4 | 145.8 / 227.2 | **+76.4 / +95.2** |

Earlier exploratory runs on the vendor copied from the main checkout (see "Vendor note" below)
landed in the same band: deltas of 10–74 µs at p50.

**Reading it.** The entire write → child wakes → child echoes → read loop → main-queue round trip
takes about 0.2 ms when idle and about 0.03 ms when warm. DispatchIO's share of that is at most
about 0.08 ms. One 120 Hz frame is 8,333 µs, and the echo paints on the next display-link tick
(patch 0010), so a win under 100 µs changes which tick catches the echo in roughly 1% of
keystrokes. GAP 3's "0.1–5 ms" jitter does not reproduce at a guarded load. The "45–65 ms"
figure cannot be produced by this path at all; whatever latency exists lives in
keyDown/feed/paint, not in the pty write.

## Instrument checks (why "no delta" is not a blind instrument)

- **Sensitivity:** with `INPUT_LATENCY_INJECT_US=1500`, every app-arm send is delayed 1.5 ms. The
  harness measured the delta as 1,562–1,658 µs at p50, so it can see a delta at the floor's scale.
- **Ordering falsification:** a 256 KiB paste is sent through the app path, then 32 keys. Run
  normally, the echo comes back byte-identical and in order. With `INPUT_LATENCY_FALSIFY=naive`
  (keys sent by bare `write(2)`, the naive T3.1 patch), the first keystroke arrived at offset 0
  instead of 262,144. The keys jumped ahead of the paste DispatchIO still had queued, and the gate
  exits 1. Any future sync-write patch must drain or queue behind pending DispatchIO writes.
  This case is the guard that would catch it if it did not.

## Not measured

keyDown → `send` and SwiftTerm feed → paint are identical for both arms and outside this gate.
Photons are not measured; a T3.4-style end-to-end probe would need the app and a window server.
Only one machine was used (M4 Pro), plus a 60/120 Hz reasoning step. Load at more than 0.70/CPU
is excluded by design: under contention both arms slow down, the floor arm included.

## Vendor note

The main checkout's `vendor/` is missing patch 0016 (`MacDisplayLinkPacer.swift` hash
`15395368…`, pin `f7442711…`), so `verify-vendor.sh` exits 3 there. The numbers above come from a
worktree vendor rebuilt by `bootstrap-vendor.sh`, which verifies clean. 0016 touches only the
display-link pacer, not the write path.
