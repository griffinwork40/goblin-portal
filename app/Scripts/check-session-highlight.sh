#!/bin/bash
# check-session-highlight.sh — headless truth table over SessionHighlightPolicy.
#
# Compiles the shipped SessionHighlightPolicy.swift (Foundation-only) and runs
# a truth table verifying the accumulation store: baseline capture, union growth,
# effective-path subtraction, and reset.  Two sed mutants on a COPY, each counted
# only when ITS declared case fails.
#
# exit 0  = all cases pass
# exit 1  = assertion failure
# exit 2  = environmental (compile failed, no source, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${GATE_SRC_DIR:-$SCRIPT_DIR/../Sources/GoblinPortal}"
POLICY="$SRC_DIR/SessionHighlightPolicy.swift"

[ -f "$POLICY" ] || { echo "FAIL: SessionHighlightPolicy.swift not found at $POLICY" >&2; exit 2; }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

HARNESS="$TMPDIR_BASE/main.swift"

cat > "$HARNESS" << 'HARNESS_EOF'
import Foundation

// ── helpers ──────────────────────────────────────────────────────────────────
var passed = 0
var failed = 0

func expectSet(_ label: String, _ got: Set<String>, _ want: Set<String>) {
    if got == want {
        print("  ok  \(label)")
        passed += 1
    } else {
        print("  FAIL  \(label): got \(got.sorted()), want \(want.sorted())")
        failed += 1
    }
}

func expectBool(_ label: String, _ got: Bool, _ want: Bool) {
    if got == want {
        print("  ok  \(label)")
        passed += 1
    } else {
        print("  FAIL  \(label): got \(got), want \(want)")
        failed += 1
    }
}

// ── cases ────────────────────────────────────────────────────────────────────

// S1: fresh store has no paths and has not started
var s = SessionHighlightStore()
expectBool("S1 hasStarted", s.hasStarted, false)
expectSet("S1 effectivePaths", s.effectivePaths, [])

// S2: first accumulate captures baseline — effective is empty because
// the first snapshot's paths ARE the baseline
s.accumulate(entryKeys: ["a.swift", "b.swift"])
expectBool("S2 hasStarted", s.hasStarted, true)
expectSet("S2 baseline", s.baselinePaths ?? [], ["a.swift", "b.swift"])
expectSet("S2 accumulated", s.accumulatedPaths, ["a.swift", "b.swift"])
expectSet("S2 effectivePaths", s.effectivePaths, [])

// S3: second accumulate with a NEW file — only the new file is effective
s.accumulate(entryKeys: ["a.swift", "c.swift"])
expectSet("S3 accumulated", s.accumulatedPaths, ["a.swift", "b.swift", "c.swift"])
expectSet("S3 effectivePaths", s.effectivePaths, ["c.swift"])

// S4: accumulate after a commit — "a.swift" was committed (no longer in
// entries), but it is still in accumulated. "d.swift" is new.
s.accumulate(entryKeys: ["c.swift", "d.swift"])
expectSet("S4 accumulated", s.accumulatedPaths, ["a.swift", "b.swift", "c.swift", "d.swift"])
expectSet("S4 effectivePaths", s.effectivePaths, ["c.swift", "d.swift"])

// S5: a committed-then-clean file survives — "c.swift" committed, empty snapshot
s.accumulate(entryKeys: [])
expectSet("S5 accumulated", s.accumulatedPaths, ["a.swift", "b.swift", "c.swift", "d.swift"])
expectSet("S5 effectivePaths", s.effectivePaths, ["c.swift", "d.swift"])

// S6: reset clears everything
s.reset()
expectBool("S6 hasStarted", s.hasStarted, false)
expectSet("S6 effectivePaths", s.effectivePaths, [])
expectSet("S6 accumulated", s.accumulatedPaths, [])

// S7: fresh session after reset — new baseline
s.accumulate(entryKeys: ["x.swift"])
expectSet("S7 effectivePaths", s.effectivePaths, [])
s.accumulate(entryKeys: ["x.swift", "y.swift"])
expectSet("S7 effectivePaths after new file", s.effectivePaths, ["y.swift"])

// S8: pre-session dirty file stays suppressed even when modified further
var s8 = SessionHighlightStore()
s8.accumulate(entryKeys: ["dirty.swift"])   // baseline
s8.accumulate(entryKeys: ["dirty.swift"])   // still dirty — suppressed
expectSet("S8 pre-session suppressed", s8.effectivePaths, [])

// S9: empty baseline — everything after is effective
var s9 = SessionHighlightStore()
s9.accumulate(entryKeys: [])               // clean repo at session start
s9.accumulate(entryKeys: ["new.swift"])     // agent creates a file
expectSet("S9 clean-start new file", s9.effectivePaths, ["new.swift"])

// S10: baseline nil guard — effectivePaths before any accumulate
var s10 = SessionHighlightStore()
expectSet("S10 no accumulate", s10.effectivePaths, [])

// ── verdict ──────────────────────────────────────────────────────────────────
print("\n\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
HARNESS_EOF

echo "compiling SessionHighlightPolicy.swift + harness..."
if ! swiftc -o "$TMPDIR_BASE/test" "$POLICY" "$HARNESS" 2>&1; then
    echo "FAIL: compile error" >&2
    exit 2
fi

echo ""
echo "running truth table..."
"$TMPDIR_BASE/test"
RESULT=$?

if [ "$RESULT" -ne 0 ]; then
    echo "FAIL: truth table" >&2
    exit 1
fi

# ── falsification ─────────────────────────────────────────────────────────────
# Each mutant is applied to a COPY of the shipped source. A mutant counts as
# caught only when ITS declared case fails.

echo ""
echo "falsification..."

MUTANT_DIR="$TMPDIR_BASE/mutants"
mkdir -p "$MUTANT_DIR"

falsify_ok=0
falsify_fail=0

# m1: remove baseline subtraction — effectivePaths returns accumulatedPaths raw.
# Must fail S2 (effective should be empty after first accumulate, but without
# subtraction it returns the baseline paths).
cp "$POLICY" "$MUTANT_DIR/m1.swift"
sed -i '' 's/return accumulatedPaths\.subtracting(baseline)/return accumulatedPaths/' "$MUTANT_DIR/m1.swift"
if swiftc -o "$MUTANT_DIR/m1" "$MUTANT_DIR/m1.swift" "$HARNESS" 2>/dev/null; then
    "$MUTANT_DIR/m1" > "$MUTANT_DIR/m1.out" 2>&1 || true
    if grep -q "FAIL.*S2 effectivePaths" "$MUTANT_DIR/m1.out"; then
        echo "  ok  m1 (no baseline subtraction) caught by S2"
        falsify_ok=$((falsify_ok + 1))
    else
        echo "  FAIL  m1 not caught by its declared case"
        falsify_fail=$((falsify_fail + 1))
    fi
else
    echo "  skip  m1 does not compile (pattern changed)"
fi

# m2: never capture baseline — baselinePaths stays nil forever.
# Must fail S2 (hasStarted should be true after first accumulate).
cp "$POLICY" "$MUTANT_DIR/m2.swift"
sed -i '' 's/if baselinePaths == nil {/if false {/' "$MUTANT_DIR/m2.swift"
if swiftc -o "$MUTANT_DIR/m2" "$MUTANT_DIR/m2.swift" "$HARNESS" 2>/dev/null; then
    "$MUTANT_DIR/m2" > "$MUTANT_DIR/m2.out" 2>&1 || true
    if grep -q "FAIL.*S2 hasStarted" "$MUTANT_DIR/m2.out"; then
        echo "  ok  m2 (no baseline capture) caught by S2"
        falsify_ok=$((falsify_ok + 1))
    else
        echo "  FAIL  m2 not caught by its declared case"
        falsify_fail=$((falsify_fail + 1))
    fi
else
    echo "  skip  m2 does not compile (pattern changed)"
fi

echo ""
echo "falsification: $falsify_ok caught, $falsify_fail missed"

if [ "$falsify_fail" -gt 0 ]; then
    echo "FAIL: falsification" >&2
    exit 1
fi

echo ""
echo "all checks passed"
