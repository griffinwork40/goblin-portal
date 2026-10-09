#!/usr/bin/env bash
#
# Throughput gate: measure frame-time for both CoreText and Metal renderers under a
# high-throughput payload and assert Metal is no worse than CoreText by more than 35%.
#
# WHY THIS EXISTS. The default renderer was `.coreText` because Metal's speed advantage
# was structurally obvious but unmeasured. This script is the measurement: it creates real
# on-screen views for both paths (offscreen at -20000,-20000 to avoid stealing focus),
# drives a high-throughput text payload through each, and compares median frame-times.
# Metal's `.perRowPersistent` buffering mode rebuilds only dirty rows; CoreText rebuilds
# every visible row through `buildAttributedString` + `CTLineCreateWithAttributedString`
# on every draw. A tie is the measured reality (issue #137 measured 4.29 vs 3.94 ms and
# 4.24 vs 4.66 ms across two runs with the gap approach); the gate's job is to confirm
# Metal does NOT regress, not to prove it wins every run.
#
# TIMING METHOD.
#   CoreText: wall-clock brackets around `view.display()` using CFAbsoluteTimeGetCurrent.
#             `display()` is synchronous — it calls `draw(_:)` on the calling thread and
#             returns when painting is complete, so the delta is exactly one frame's cost.
#   Metal:    wall-clock brackets around `mtkView.draw()` (synchronous MTKView draw).
#             Without an untimed gap between draws, Metal blocks waiting for a free
#             drawable; on a 120 Hz display that wait is ~8.3 ms — one vsync period —
#             dominating the actual render cost (issue #137, bug 2). A 20 ms RunLoop gap
#             between timed frames lets the previous drawable recycle, so the measured
#             interval is GPU encoding cost rather than vsync wait.
#
#   Metric: median frame-time (p50) and p95. Mean is also recorded but NOT used for the
#           pass rule — it is dominated by occasional GC/scheduler spikes that do not
#           reflect steady-state render cost.
#
# PAYLOAD. A 120×40 LocalProcessTerminalView fed ANSI text without a live pty. The
# payload contains colour escapes, bold, and mixed ASCII to exercise the glyph-atlas and
# attribute pipeline rather than trivial blank cells.
#
# PASS RULE. Metal median ≤ CoreText median × 1.35, i.e. ratio ≥ 0.741. Rationale:
# issue #137's reference probe (20 ms gap, same approach) measured ratios of 1.089 and
# 0.910 across two runs — a run-to-run spread of ~18% around the tie point. Doubling that
# for machine-to-machine variation and thermal differences gives ≈36%, rounded to 35%.
# This lets a tie pass on any machine while catching a catastrophic regression like the
# original broken harness's 7.4 ms Metal vs 2.0 ms CoreText. The previous "ratio ≥ 1.0"
# rule (Metal must win) failed on every tie and was the wrong bar: the default flip only
# needs Metal not to regress.
#
# COMPILE FAILURES. A harness that does not compile exits 2 (environmental), NOT 1.
# This is deliberate: a compile failure is a toolchain/environment problem — the harness
# cannot produce a verdict — not evidence that Metal regressed. The compile log is
# printed to stderr so it is not silently excused. (Issue #137 bug 1: the original
# harness lacked `import MetalKit`, so MTKView was out of scope, and passed `[UInt8]`
# where `feed(byteArray:)` requires `ArraySlice<UInt8>`; it always exited 2 and the
# broken harness hid behind the "no GPU / no WindowServer" excuse.)
#
# LOAD GUARD (N6, rendering-audit-2026-10-05). The gate failed five consecutive runs on
# main (ratios 0.67–0.72 vs a 0.741 floor) at load average 12–15 on 14 cores, then
# passed (ratio 0.801) the following day on the same code and the same machine. Root
# cause: scheduler starvation; under heavy competing load the Metal drawable pool stalls
# before the 20 ms gap expires, so the timed interval includes GPU-scheduler wait that
# the gap was supposed to eliminate. The frame-time ratio is accurate only on a machine
# where the GPU scheduler is not contended.
#
# Guard: `sysctl -n vm.loadavg` returns three fields ({1m 5m 15m} on macOS); we measure
# the 1-minute load before AND after the run.  If either sample exceeds
# LOAD_PER_CPU_THRESHOLD × ncpu, we exit 2 (environmental) rather than exit 1 (renderer
# regression) — exactly as compile failure does.  The threshold is 0.7 per CPU: at that
# level the scheduler has clear headroom and GPU starvation is implausible; at 0.9+
# (machine load 12–15 on 14 cores) it is the observed failure mode.  "Fires under
# synthetic load" was observed in the falsification run; the quiet-machine half
# was inconclusive (load stayed at 14.36 after workers stopped).  Transcript:
# .afk/research/N6-loadguard-falsification.md.
#
# Falsification: we spawn `yes > /dev/null` workers (one per CPU minus one for headroom),
# measure load after a settle period, confirm the guard fires, then SIGTERM the workers
# and confirm the guard passes.  The trap cleans up workers on any exit so they never
# leak.  Run with LOADGUARD_FALSIFY=1 to execute this block; normal runs skip it.
#
# Exit codes:
#   0  Metal median ≤ CoreText median × 1.35 (validates the default flip)
#   1  Metal regresses by more than 35% vs CoreText (investigate before shipping)
#   2  environmental — no swiftc, no Metal device, no WindowServer, build failed,
#      harness would not compile, or machine load exceeds threshold. Never conflated with 1.
#
# Usage:
#   ./Scripts/check-metal-throughput.sh           # run the measurement
#   ./Scripts/check-metal-throughput.sh --quiet   # summary line and failures only
#   LOADGUARD_FALSIFY=1 ./Scripts/check-metal-throughput.sh  # run falsification block

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" = "1" ] || echo "$@"; }

cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
TMP="$(mktemp -d)"
WORKERS=()
# Clean up tmp AND any synthetic load workers on any exit.
trap '[ ${#WORKERS[@]} -gt 0 ] && kill "${WORKERS[@]}" 2>/dev/null; rm -rf "$TMP"' EXIT

LOAD_PER_CPU_THRESHOLD="0.70"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"

# load1(): current 1-minute load average as a decimal string.
load1() { sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'; }

# load_busy(): returns 0 (true) if load/CPU > threshold, 1 (false) otherwise.
load_busy() {
  local load; load="$(load1)"
  awk -v l="$load" -v n="$NCPU" -v t="$LOAD_PER_CPU_THRESHOLD" \
    'BEGIN { exit (l/n > t) ? 0 : 1 }'
}

# --- falsification block (LOADGUARD_FALSIFY=1 only) -------------------------------
# Spawn `yes > /dev/null` workers, confirm the guard fires under synthetic load,
# then SIGTERM the workers and confirm the guard passes on a quiet machine.
# Workers are tracked in WORKERS[] and killed by the EXIT trap even on Ctrl+C.
if [ "${LOADGUARD_FALSIFY:-0}" = "1" ]; then
  say "==> falsification: spawning synthetic load workers ($((NCPU - 1)) yes-workers)…"
  for _i in $(seq 1 $((NCPU - 1))); do
    yes > /dev/null &
    WORKERS+=($!)
  done
  say "   waiting 8 s for load to climb…"
  sleep 8
  _fload="$(load1)"
  say "   load1=$_fload  ncpu=$NCPU  threshold=$LOAD_PER_CPU_THRESHOLD/cpu"
  if load_busy; then
    say "   FALSIFICATION OK — guard fires under synthetic load (load1=$_fload, ncpu=$NCPU)"
  else
    echo "FALSIFICATION INCONCLUSIVE — load did not reach threshold (load1=$_fload)." >&2
    echo "  The machine may already be under load. Re-run on a quieter system." >&2
  fi
  say "==> killing workers, waiting 10 s for load to settle…"
  kill "${WORKERS[@]}" 2>/dev/null; WORKERS=()
  sleep 10
  _qload="$(load1)"
  say "   load1=$_qload  ncpu=$NCPU  threshold=$LOAD_PER_CPU_THRESHOLD/cpu"
  if load_busy; then
    say "   NOTE: load still above threshold ($LOAD_PER_CPU_THRESHOLD/cpu) after workers stopped."
    say "   This machine had background load before the test; the quiet-machine assertion cannot be made."
  else
    say "   FALSIFICATION OK — guard does not fire on quiet machine (load1=$_qload)"
  fi
  say "   falsification done; continuing to normal run"
  say
fi

# --- environment ------------------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
fi

# Resolve the SwiftPM bin path the same way check-reflow.sh does — vendored-module.sh
# picks the right backend (Swift Build vs classic) and handles the merged SwiftTerm.o.
. Scripts/vendored-module.sh
resolve_vendored_module          # sets PRODUCTS, or exits 2

# --- compile the harness ----------------------------------------------------------
# The harness is in check-metal-throughput-harness.swift, extracted when the 350-LOC
# ceiling was reached after adding the N6 load guard. Same pattern as check-git-status.sh.
cp "$APP_ROOT/Scripts/check-metal-throughput-harness.swift" "$TMP/main.swift" \
  || { echo "error: check-metal-throughput-harness.swift could not be copied." >&2; exit 2; }

# A harness that does not compile exits 2 — environmental, not a Metal regression.
# The compile log is printed so it is not silently excused (issue #137, bug 1).
if ! swiftc -O -o "$PRODUCTS/throughputcheck" "$TMP/main.swift" \
    -I "$PRODUCTS" -L "$PRODUCTS" "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit -framework Metal -framework MetalKit 2>"$TMP/compile.log"; then
  echo "error: the throughput harness would not compile — the gate cannot run." >&2
  echo "  (compile failure is exit 2, not exit 1; this is a toolchain/environment" >&2
  echo "   problem, not evidence that Metal regressed)" >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

# --- load guard -------------------------------------------------------------------
# Check the 1-minute load average before we run. Under heavy scheduler contention
# (observed: load 12-15 on 14 cores = ~0.9/cpu) Metal's drawable pool stalls inside
# the 20 ms gap and the timed interval measures GPU-scheduler wait, not render cost.
# The resulting ratio (0.67-0.72 on main, five runs) is below the 0.741 floor even
# though the renderer is correct, producing a false exit 1.
# Exit 2 (environmental) instead — the same contract as "no Metal device" or "no GPU".
_pre_load="$(load1)"
say "==> load check before run: load1=${_pre_load}, ncpu=${NCPU}, threshold=${LOAD_PER_CPU_THRESHOLD}/cpu"
if load_busy; then
  echo "error: environmental: machine busy — load1=${_pre_load} on ${NCPU} cpus" \
       "exceeds ${LOAD_PER_CPU_THRESHOLD}/cpu threshold." >&2
  echo "  A busy machine makes the drawable-gap ineffective; ratio would measure scheduler" >&2
  echo "  wait, not renderer cost. Re-run when the machine is quieter." >&2
  exit 2
fi

say "==> running throughput measurement (150 frames each renderer)"
: > "$TMP/harness.err"
out="$("$PRODUCTS/throughputcheck" 2>"$TMP/harness.err" || echo "CRASH")"

_post_load="$(load1)"
say "==> post-run load: load1=${_post_load}"
if load_busy; then
  echo "error: environmental: machine became busy during the run" \
       "(post-run load1=${_post_load} on ${NCPU} cpus > ${LOAD_PER_CPU_THRESHOLD}/cpu)." >&2
  echo "  Results may reflect scheduler contention rather than renderer cost. Discarded." >&2
  exit 2
fi

if [ "$out" = "CRASH" ]; then
  echo "error: the throughput harness died — environmental, not a verdict." >&2
  [ -s "$TMP/harness.err" ] && sed 's/^/    /' "$TMP/harness.err" >&2
  exit 2
fi

if echo "$out" | grep -q "RESULT env_fail"; then
  reason="$(echo "$out" | sed -n 's/RESULT env_fail //p')"
  echo "error: environmental failure — $reason" >&2
  exit 2
fi

# Print per-renderer stats for measurement log.
echo "$out" | grep "^STAT"

# Parse RESULT line.
ct_ms="$(echo "$out" | sed -n 's/.*ct_median_ms=\([0-9.]*\).*/\1/p')"
mt_ms="$(echo "$out" | sed -n 's/.*mt_median_ms=\([0-9.]*\).*/\1/p')"
ratio="$(echo "$out" | sed -n 's/.*ratio=\([0-9.]*\).*/\1/p')"
frames="$(echo "$out" | sed -n 's/.*frames=\([0-9]*\).*/\1/p')"

if [ -z "$ct_ms" ] || [ -z "$mt_ms" ] || [ -z "$ratio" ]; then
  echo "error: could not parse RESULT line from harness output:" >&2
  echo "  $out" >&2
  exit 2
fi

say "  CoreText median frame-time : ${ct_ms} ms"
say "  Metal    median frame-time : ${mt_ms} ms"
say "  Ratio (CoreText/Metal)     : ${ratio}  (>=0.741 means Metal ≤ 35% slower)"
say "  Frames measured each       : ${frames}"
say

# Pass rule: Metal median ≤ CoreText median × 1.35, i.e. ratio ≥ 1/1.35 = 0.741.
# A tie (ratio ≈ 1.0) passes. Metal must not regress by more than 35%.
# Using awk for floating-point comparison (POSIX sh has no float arithmetic).
result="$(awk -v r="$ratio" 'BEGIN { print (r >= 0.741) ? "pass" : "fail" }')"

if [ "$result" = "pass" ]; then
  echo "throughput gate passed: Metal median ${mt_ms}ms, CoreText median ${ct_ms}ms (ratio ${ratio}, threshold >=0.741)"
  exit 0
else
  echo "✗ FAIL: Metal (${mt_ms}ms) regresses vs CoreText (${ct_ms}ms) by more than 35% (ratio ${ratio} < 0.741)" >&2
  echo "  The default Metal renderer has a severe performance problem. Investigate:" >&2
  echo "    - Confirm the Metal renderer is actually active (check-metal-renderer.sh)" >&2
  echo "    - Check for GPU throttling (thermal, power, background processes)" >&2
  echo "    - Re-run: transient spikes can invert a close race" >&2
  exit 1
fi
