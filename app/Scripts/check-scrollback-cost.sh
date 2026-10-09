#!/bin/bash
#
# Gate: scrollback memory and resize cost do not regress past defined ceilings.
#
# WHY THIS GATE EXISTS
# T2.4 in the best-mac-terminal roadmap raises the default scrollback from 1000 to a
# higher value for agent REPL sessions. Before doing so, the roadmap requires measuring:
#   (A) resident memory per 1k scrollback lines — confirm/refute the A1a ~10.5 KB/line
#       estimate (from `.afk/research/best-mac-terminal-2026-10-07/A1a-perf.md`);
#   (B) `Terminal.resize` narrow→widen cost at 1k, 3.5k, 5k, 10k, 20k lines, since
#       live window drags fire resize on every pixel change and must stay well within
#       the 16ms frame budget.
#
# WHAT IS MEASURED
# Memory: `MemoryLayout<CharData>.stride × cols × lines.count` for the normal buffer.
#   alt buffer only holds `rows` lines, contributing negligibly.
#   This is CharData heap footprint only — the full tab cost also includes Metal glyph
#   atlas (~5-10 MB), CA backing, and SwiftTerm state — but CharData scales linearly with
#   scrollback and is the dominant term above ~2k lines.
#   Access: `HeadlessTerminal.terminal.displayBuffer.lines.count` (public API).
#   `MemoryLayout<CharData>.stride` is measured from the live binary — no estimate.
#
# Resize cost: wall-clock of `Terminal.resize(cols: newCols, rows: rows)` narrow then
#   widen, 50 iterations each, using `ContinuousClock`. Median (p50) and p95 reported.
#   Realistic workload: feed N full-width SGR-attributed lines first so the buffer is
#   maximally stressed (scrollback full, reflow fires). SGR: `ESC[1;31m` + 79 chars +
#   `ESC[m` — bold red, text, reset. Short lines every 5th (realistic terminal mix).
#
# ASSERTIONS (ceilings):
#   Memory ceiling: stride × cols × (scrollback + rows) ≤ 2 MB per 1k scrollback lines.
#     (10.5 KB/line × 80 cols × 1000 = 840 KB CharData; ceiling is 2 MB to allow for
#     BufferLine object overhead and any future struct growth.)
#   Resize p50 ceiling: ≤ 100 µs at 10k lines (16ms budget, 60fps drag → one resize per
#     frame; 100 µs = 0.6% of frame, safe; at 5k it is ~50 µs per A1a estimates).
#   Resize p95 ceiling: ≤ 3× p50 (healthy distribution; larger spike = GC or cache miss).
#
# FALSIFICATION: the falsification case runs at scrollback=50 (32 buffer rows) and
#   asserts that THAT case fails the 2-MB-per-1k ceiling — it would fail trivially at
#   50 lines if the ceiling were violated. That verifies the harness rejects bad numbers,
#   not that it always accepts.  Actually: we falsify by computing a deliberately-wrong
#   memory value (stride=1) and asserting it FAILS the ceiling, confirming the ceiling
#   is not vacuous.  See FALSIFY=1 env var below.
#
# LOAD GUARD (N6 lesson from check-metal-throughput.sh):
#   If the 1-minute load average exceeds 0.70 per CPU at any point, timing assertions
#   exit 2 (environmental) rather than 1 (regression). Memory assertions are unaffected
#   by load and are never guarded.
#
# Shape: same as check-reflow.sh — links vendored SwiftTerm.o, exit 1 = assertion failure,
#   exit 2 = environment failure. Harness is Scripts/check-scrollback-cost-harness.swift.
#
# Usage:
#   ./Scripts/check-scrollback-cost.sh            # run
#   ./Scripts/check-scrollback-cost.sh --quiet    # summary only
#   FALSIFY=1 ./Scripts/check-scrollback-cost.sh  # confirm falsification exits 1
#
# Exit codes:
#   0  every case passed
#   1  assertion failure (memory or resize regression, or falsification broken)
#   2  environment failure (vendor missing, no toolchain, build failed, high load)

set -euo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
FALSIFY="${FALSIFY:-0}"

say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"
VENDOR="$REPO_ROOT/vendor/SwiftTerm"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- environment gates, all exit 2 -------------------------------------------
if [[ ! -d "$VENDOR" ]]; then
  echo "error: vendor/SwiftTerm is missing — nothing to check." >&2
  echo "       See app/README.md (\"Dependency note\") or run ./Scripts/verify-vendor.sh" >&2
  exit 2
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
fi

. Scripts/vendored-module.sh
resolve_vendored_module   # sets PRODUCTS, or exits 2

cp Scripts/check-scrollback-cost-harness.swift "$TMP/main.swift"

say "compiling harness…"
# Same link pattern as check-reflow.sh: pass SwiftTerm.o directly (it is a merged
# module object from the Swift Build backend), add -framework AppKit (SwiftTerm
# imports AppKit even in the HeadlessTerminal path via the Apple/ sources),
# and -I to resolve the SwiftTerm module interface. No -lSwiftTerm needed:
# the .o provides all the symbols; -l would look for a .dylib which does not exist.
if ! swiftc -O \
    -I "$PRODUCTS" \
    "$TMP/main.swift" \
    "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit \
    -o "$TMP/harness" 2>"$TMP/compile.log"; then
  echo "error: harness did not compile — see below." >&2
  cat "$TMP/compile.log" >&2
  exit 2
fi

# Pass FALSIFY through env
FALSIFY="$FALSIFY" "$TMP/harness"
HARNESS_EXIT=$?

if [[ "$HARNESS_EXIT" == "0" ]]; then
  say "check-scrollback-cost: all cases passed."
elif [[ "$HARNESS_EXIT" == "1" ]]; then
  echo "check-scrollback-cost: ASSERTION FAILURE — see output above." >&2
elif [[ "$HARNESS_EXIT" == "2" ]]; then
  echo "check-scrollback-cost: ENVIRONMENT FAILURE — load too high or precondition failed." >&2
fi

exit "$HARNESS_EXIT"
