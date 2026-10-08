#!/bin/bash
#
# check-file-ops.sh — gates FileOperationPolicy.swift (Foundation-only).
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/FileOperationPolicy.swift` only: the
# decision layer of the sidebar's file operations (name validation, free-or-suffix
# naming, collision refusal, case-only rename and its rollback, descendant checks).
# It is Foundation-only BY DESIGN so it compiles headless with `swiftc` — compiling
# the SHIPPED file, not a restatement of it, is the whole point. The assertions live
# in `check-file-ops-harness.swift`; this script builds and runs them.
#
# 16 CASES (see the harness): validity, suffix naming, case-only detection,
# isDescendant, create, rename, case-only rename read back from the LISTING (a bare
# fileExists proves nothing about case on this volume), move, trash, move collision,
# paste keeps a free name, duplicate always suffixes, collisions never overwrite
# (original content intact), case-only rollback when step 2 fails (forced through
# the policy's `moveItem` seam), and caseSensitiveFSAtRoot (returns a Bool, no
# crash — value is volume-dependent and printed as informational).
#
# FALSIFICATION — A REAL MUTATION. The shipped policy is copied to a temp dir and
# sed breaks one rule: the free-name line in `availableName` is rewritten so a free
# name is suffixed anyway. The SAME harness is recompiled against that copy and must
# exit 1. If it exits 0 the gate is blind to the rule it claims to guard (exit 1);
# if sed changed nothing the falsification itself is blind (exit 2).
# The previous version compiled a naive function beside the real one, which proved
# only that the harness could tell two functions it had written apart.
#
# EXIT CODES: 0 = all cases passed and the mutant was caught. 1 = real failure.
# 2 = environmental (no toolchain, compile failure, harness crash or signal, blind
# falsification). A broken environment must never read as a green gate.
#
# Usage:  ./Scripts/check-file-ops.sh [--quiet]

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/FileOperationPolicy.swift"
HARNESS="Scripts/check-file-ops-harness.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }
for f in "$SRC" "$HARNESS"; do
    [[ -f "$f" ]] || { echo "error: $f not found — did the file move?" >&2; exit 2; }
done

TMP=$(mktemp -d) || { echo "error: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
# The harness is top-level code, so it must be compiled as main.swift.
cp "$HARNESS" "$TMP/main.swift"

# build <policy-file> <out-binary>: exit 2 on a compile failure (environmental).
build() {
    if ! swiftc -O -o "$2" "$1" "$TMP/main.swift" 2>"$TMP/compile.err"; then
        echo "error: harness failed to compile against $1" >&2
        cat "$TMP/compile.err" >&2
        exit 2
    fi
}

# run <binary>: prints its output (unless quiet) and sets RUN_STATUS. A status above
# 1 (incl. 128+N for a signal) is a crash, never an assertion failure.
run() {
    local out
    out=$("$1" 2>&1); RUN_STATUS=$?
    [[ "$QUIET" == "1" && $RUN_STATUS -eq 0 ]] || echo "$out"
}

# ── Real run ─────────────────────────────────────────────────────────────────
build "$SRC" "$TMP/harness"
say "==> running check-file-ops (16 cases) against the shipped policy"
run "$TMP/harness"
if [[ $RUN_STATUS -gt 1 ]]; then
    echo "error: harness crashed (status $RUN_STATUS) — environmental, not a verdict" >&2
    exit 2
fi
[[ $RUN_STATUS -eq 0 ]] || exit 1

# ── Falsification: a sed-mutated copy of the shipped policy must FAIL ─────────
mkdir -p "$TMP/mutant"
MUT="$TMP/mutant/FileOperationPolicy.swift"
# Break the free-name rule: a free name now falls through to the suffixing path.
sed 's|if !lower.contains(base.lowercased()) { return base }  // FREE-NAME-RULE|if false { return base }  // FREE-NAME-RULE|' \
    "$SRC" > "$MUT"
if cmp -s "$SRC" "$MUT"; then
    echo "error: falsification is BLIND — sed changed nothing (FREE-NAME-RULE line moved?)" >&2
    exit 2
fi
build "$MUT" "$TMP/mutant/harness"
say "==> falsification: harness against a policy whose free names are always suffixed"
QUIET=1 run "$TMP/mutant/harness"
case $RUN_STATUS in
    1) say "falsification: mutant rejected, as required" ;;
    0) echo "FAIL: the mutated policy PASSED — this gate cannot see the free-name rule" >&2; exit 1 ;;
    *) echo "error: mutant harness crashed (status $RUN_STATUS)" >&2; exit 2 ;;
esac

say "check-file-ops: exit 0 — all cases passed, mutant caught"
exit 0
