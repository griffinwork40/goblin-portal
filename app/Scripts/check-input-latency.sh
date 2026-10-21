#!/bin/bash
#
# Gate + measurement tool: keystroke-to-echo round trip through a real pty, via the SAME
# write path the app uses (LocalProcess.send → DispatchIO.write), against the bare write(2)
# floor a synchronous-write patch could reach. Roadmap item T3.1.
#
# WHY THIS EXISTS
# T3.1 proposed a vendor patch (synchronous non-blocking write(2) for small payloads) on an
# ESTIMATED latency win (A1a GAP 3). The roadmap requires "a delta or the patch is dropped".
# The harness (Scripts/check-input-latency-harness.swift) prints p50/p95/p99 for both arms in
# two regimes and the delta, which is an UPPER BOUND on what any such patch could win; the
# findings are in .afk/research/input-latency-2026-10-21.md.
#
# WHAT IT ASSERTS (exit 1 on failure)
#   1. every echoed byte is the byte sent;
#   2. ordering: a 256 KiB paste then 32 keystrokes, all through the app path, echo in order;
#   3. FALSIFICATION of (2): INPUT_LATENCY_FALSIFY=naive sends the keystrokes through a bare
#      write(2) while the paste is still queued in DispatchIO — the naive T3.1 patch — and the
#      ordering case MUST fail. If it passes, the ordering case cannot see a reorder and its
#      green means nothing;
#   4. SENSITIVITY: INPUT_LATENCY_INJECT_US=1500 delays every app-path send by 1.5 ms, and the
#      measured p50 delta MUST rise to ≥ 1000 µs (the floor). If it does not, the harness
#      could not have seen a delta of the size the patch would need, and "no delta" would be
#      a blind instrument's answer.
# It does NOT fail on the size of the delta: whether a delta justifies a patch is a decision
# recorded in the findings doc, and a machine-dependent latency number is not a regression.
#
# WHY RELEASE BUILD: same reason as check-scrollback-cost.sh — the app ships release SwiftTerm.
# LOAD GUARD (N6): > 0.70/CPU before or after the timing → exit 2. INPUT_LATENCY_IGNORE_LOAD=1
#   runs anyway and labels the numbers unguarded (for smoke tests only).
# NOT IN CI: timing-dependent, like check-scrollback-cost.sh and check-metal-throughput.sh.
#
# Usage:  ./Scripts/check-input-latency.sh            # ordering + falsification + measurement
#         INPUT_LATENCY_SAMPLES=1000 ./Scripts/check-input-latency.sh
# Exit:   0 ok · 1 echo/ordering failure or a falsification that did not fire · 2 environmental

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(cd .. && pwd)"
VENDOR="$REPO_ROOT/vendor/SwiftTerm"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say() { echo "$@"; }

if [[ ! -d "$VENDOR" ]]; then
  echo "error: vendor/SwiftTerm is missing — run ./Scripts/bootstrap-vendor.sh" >&2
  exit 2
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
fi

BUILD_CONFIG=release . Scripts/vendored-module.sh
BUILD_CONFIG=release resolve_vendored_module   # sets PRODUCTS, or exits 2

cp Scripts/check-input-latency-harness.swift "$TMP/main.swift"
say "compiling harness (against release SwiftTerm.o)…"
if ! swiftc -O -I "$PRODUCTS" "$TMP/main.swift" "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit -o "$TMP/harness" 2>"$TMP/compile.log"; then
  echo "error: harness did not compile:" >&2
  cat "$TMP/compile.log" >&2
  exit 2
fi

# --- falsification of the ordering case: the naive patch must be caught ------------------
say ""
say "== falsification: keystrokes via bare write(2) behind a queued paste (must FAIL) =="
set +e
INPUT_LATENCY_FALSIFY=naive "$TMP/harness"
rc=$?
set -e
case "$rc" in
  1) say "falsification: caught — the ordering case sees a reorder." ;;
  2) echo "falsification: inconclusive (environmental, exit 2)." >&2; exit 2 ;;
  *) echo "falsification: BLIND — naive write(2) passed the ordering case (exit $rc)." >&2; exit 1 ;;
esac

# --- sensitivity: a 1.5 ms injected delay must show up as a ≥ floor delta -----------------
say ""
say "== sensitivity: app path delayed 1500 µs (delta must reach the 1000 µs floor) =="
set +e
INPUT_LATENCY_INJECT_US=1500 INPUT_LATENCY_SAMPLES=150 "$TMP/harness" >"$TMP/sens.log"
rc=$?
set -e
cat "$TMP/sens.log"
[[ "$rc" == "0" ]] || exit "$rc"
sens="$(sed -n 's/^DELTA_P50_US=//p' "$TMP/sens.log")"
if [[ -z "$sens" ]]; then
  echo "sensitivity: harness printed no DELTA_P50_US — cannot judge." >&2
  exit 2
fi
if (( sens < 1000 )); then
  echo "sensitivity: BLIND — an injected 1500 µs delay measured as ${sens} µs (< 1000)." >&2
  exit 1
fi
say "sensitivity: ok — injected delay measured as ${sens} µs."

# --- the measurement ---------------------------------------------------------------------
say ""
say "== measurement: shipped write path vs bare write(2) floor =="
set +e
"$TMP/harness"
rc=$?
set -e
case "$rc" in
  0) say "check-input-latency: ordering held, falsification and sensitivity fired, numbers above." ;;
  1) echo "check-input-latency: ASSERTION FAILURE — see above." >&2 ;;
  *) echo "check-input-latency: ENVIRONMENT FAILURE — see above." >&2 ;;
esac
exit "$rc"
