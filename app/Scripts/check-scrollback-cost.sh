#!/bin/bash
#
# Gate: scrollback memory and resize cost do not regress past defined ceilings.
#
# WHY THIS GATE EXISTS
# T2.4 in the best-mac-terminal roadmap raises the default scrollback from 1000 to 5000
# lines for agent REPL sessions. Before doing so, the roadmap requires measured evidence:
#   (A) resident memory per 1k scrollback lines — task_info(TASK_VM_INFO).phys_footprint
#       delta, measured in a fresh process per scrollback size, at 80 and 200 cols;
#   (B) `Terminal.resize` narrow→widen cost at 1k, 3.5k, 5k, 10k, 20k lines, since
#       live window drags fire resize on every pixel change and must stay within the
#       16ms frame budget.
#
# WHY RELEASE BUILD
# The shipped app is a release build. Debug SwiftTerm is ~25x slower (measured:
# 1k p50 ~12,900 µs debug vs ~500 µs release). Ceilings calibrated to debug are either
# uselessly loose (accept any regression up to 25x) or spuriously tight (reject healthy
# code on a slightly-loaded machine). This gate builds and links a RELEASE SwiftTerm.o
# so ceilings are meaningful. check-reflow.sh and check-altbuffer-resize.sh keep their
# debug builds; this gate opts in via BUILD_CONFIG=release in vendored-module.sh.
#
# FALSIFICATION
# FALSIFY=1 re-links the harness against the DEBUG SwiftTerm.o (same vendor tree,
# different build, no source change) and runs the timing assertions. Because debug is
# ~25x slower, the release-calibrated ceilings fire and the gate exits 1 — proving the
# ceilings are not vacuous. A gate whose own ceilings cannot reject a 25x regression is
# not a gate; this one can. Memory assertions are skipped in FALSIFY mode (phys_footprint
# at debug vs release varies by task overhead, not by a predictable factor).
#
# LOAD GUARD (N6 lesson from check-metal-throughput.sh):
#   If the 1-minute load average exceeds 0.70 per CPU at any point, timing assertions
#   exit 2 (environmental). Memory assertions are load-independent and never skipped.
#
# Shape: same as check-reflow.sh — links vendored SwiftTerm.o, exit 1 = assertion failure,
#   exit 2 = environment failure. Harness is Scripts/check-scrollback-cost-harness.swift.
#
# NOT IN CI: the timing half depends on machine load; the existing load guard handles
# transient spikes but cannot guarantee exit 0 on every CI run. check-reflow.sh and
# check-altbuffer-resize.sh are in CI because they are deterministic. This gate is
# local-only and is excluded from checks.yml by the same reasoning as
# check-metal-throughput.sh (also timing-dependent, also local-only).
#
# Usage:
#   ./Scripts/check-scrollback-cost.sh            # run (release build)
#   ./Scripts/check-scrollback-cost.sh --quiet    # summary only
#   FALSIFY=1 ./Scripts/check-scrollback-cost.sh  # confirm debug SwiftTerm fails ceilings
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

# Build release SwiftTerm (see "WHY RELEASE BUILD" above).
BUILD_CONFIG=release . Scripts/vendored-module.sh
BUILD_CONFIG=release resolve_vendored_module   # sets PRODUCTS, or exits 2
REL_PRODUCTS="$PRODUCTS"

cp Scripts/check-scrollback-cost-harness.swift "$TMP/main.swift"

say "compiling harness (against release SwiftTerm.o)…"
if ! swiftc -O \
    -I "$REL_PRODUCTS" \
    "$TMP/main.swift" \
    "$REL_PRODUCTS/SwiftTerm.o" \
    -framework AppKit \
    -o "$TMP/harness" 2>"$TMP/compile.log"; then
  echo "error: harness did not compile — see below." >&2
  cat "$TMP/compile.log" >&2
  exit 2
fi

if [[ "$FALSIFY" == "1" ]]; then
  # Falsification: link the same harness against DEBUG SwiftTerm.o (~25x slower).
  # The release-calibrated ceilings must fire — if they do not, the gate is too loose.
  # Memory assertions are not falsified this way (phys_footprint overhead differs by
  # task infrastructure, not by a stable factor like compilation).
  say "FALSIFY=1: building DEBUG SwiftTerm for falsification…"
  . Scripts/vendored-module.sh
  BUILD_CONFIG=debug resolve_vendored_module   # sets PRODUCTS to debug path
  DBG_PRODUCTS="$PRODUCTS"
  say "FALSIFY=1: compiling harness against debug SwiftTerm.o…"
  if ! swiftc -O \
      -I "$DBG_PRODUCTS" \
      "$TMP/main.swift" \
      "$DBG_PRODUCTS/SwiftTerm.o" \
      -framework AppKit \
      -o "$TMP/harness_debug" 2>"$TMP/compile_debug.log"; then
    echo "FALSIFY=1: error: debug harness did not compile." >&2
    cat "$TMP/compile_debug.log" >&2
    exit 2
  fi
  say "FALSIFY=1: running timing with debug SwiftTerm — ceilings should fire (exit 1 expected)…"
  set +e
  FALSIFY_DEBUG_TIMING=1 "$TMP/harness_debug"
  FALSIFY_EXIT=$?
  set -e
  if [[ "$FALSIFY_EXIT" == "1" ]]; then
    say "FALSIFY=1: confirmed — debug SwiftTerm exceeded release timing ceilings."
    say "FALSIFY=1: gate exits 0 (falsification succeeded as expected)."
    exit 0
  elif [[ "$FALSIFY_EXIT" == "2" ]]; then
    # The harness skipped timing under the N6 load guard (or could not judge): that
    # is environmental, not evidence the ceilings are loose. Reporting it as 1 would
    # be a false regression verdict, observed 2026-10-09 at load ~1.2/CPU.
    echo "FALSIFY=1: inconclusive — debug harness could not time (exit 2, e.g. high load). Re-run at lower load." >&2
    exit 2
  else
    echo "FALSIFY=1: ERROR — debug SwiftTerm did NOT exceed release timing ceilings (exit $FALSIFY_EXIT)." >&2
    echo "  The ceilings are too loose: a 25x regression would pass." >&2
    exit 1
  fi
fi

# Normal run against release SwiftTerm.
"$TMP/harness"
HARNESS_EXIT=$?

if [[ "$HARNESS_EXIT" == "0" ]]; then
  say "check-scrollback-cost: all cases passed."
elif [[ "$HARNESS_EXIT" == "1" ]]; then
  echo "check-scrollback-cost: ASSERTION FAILURE — see output above." >&2
elif [[ "$HARNESS_EXIT" == "2" ]]; then
  echo "check-scrollback-cost: ENVIRONMENT FAILURE — load too high or precondition failed." >&2
fi

exit "$HARNESS_EXIT"
