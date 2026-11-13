#!/bin/bash
# check-session-highlight.sh — headless truth table over SessionHighlightPolicy.
#
# Compiles the shipped SessionHighlightPolicy.swift (Foundation-only) and runs
# a truth table verifying the accumulation store: baseline capture, union growth,
# effective-path subtraction, reset, and repository identity (#298: a different
# repository is a different session, R cases).  Four sed mutants on a COPY, each
# counted only when ITS declared case fails; a stale pattern or a mutant that does
# not compile exits 2.
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

func expectRoot(_ label: String, _ got: String?, _ want: String?) {
    if got == want {
        print("  ok  \(label)")
        passed += 1
    } else {
        print("  FAIL  \(label): got \(got ?? "nil"), want \(want ?? "nil")")
        failed += 1
    }
}

// Two working-tree roots. Paths are repo-relative, so both repos can hold a README.md.
let A = "/tmp/repo-a"
let B = "/tmp/repo-b"

// ── cases ────────────────────────────────────────────────────────────────────

// S1: fresh store has no paths and has not started
var s = SessionHighlightStore()
expectBool("S1 hasStarted", s.hasStarted, false)
expectSet("S1 effectivePaths", s.effectivePaths, [])

// S2: first accumulate captures baseline — effective is empty because
// the first snapshot's paths ARE the baseline
s.accumulate(entryKeys: ["a.swift", "b.swift"], repositoryRoot: A)
expectBool("S2 hasStarted", s.hasStarted, true)
expectSet("S2 baseline", s.baselinePaths ?? [], ["a.swift", "b.swift"])
expectSet("S2 accumulated", s.accumulatedPaths, ["a.swift", "b.swift"])
expectSet("S2 effectivePaths", s.effectivePaths, [])

// S3: second accumulate with a NEW file — only the new file is effective
s.accumulate(entryKeys: ["a.swift", "c.swift"], repositoryRoot: A)
expectSet("S3 accumulated", s.accumulatedPaths, ["a.swift", "b.swift", "c.swift"])
expectSet("S3 effectivePaths", s.effectivePaths, ["c.swift"])

// S4: accumulate after a commit — "a.swift" was committed (no longer in
// entries), but it is still in accumulated. "d.swift" is new.
s.accumulate(entryKeys: ["c.swift", "d.swift"], repositoryRoot: A)
expectSet("S4 accumulated", s.accumulatedPaths, ["a.swift", "b.swift", "c.swift", "d.swift"])
expectSet("S4 effectivePaths", s.effectivePaths, ["c.swift", "d.swift"])

// S5: a committed-then-clean file survives — "c.swift" committed, empty snapshot
s.accumulate(entryKeys: [], repositoryRoot: A)
expectSet("S5 accumulated", s.accumulatedPaths, ["a.swift", "b.swift", "c.swift", "d.swift"])
expectSet("S5 effectivePaths", s.effectivePaths, ["c.swift", "d.swift"])

// S6: reset clears everything
s.reset()
expectBool("S6 hasStarted", s.hasStarted, false)
expectSet("S6 effectivePaths", s.effectivePaths, [])
expectSet("S6 accumulated", s.accumulatedPaths, [])

// S7: fresh session after reset — new baseline
s.accumulate(entryKeys: ["x.swift"], repositoryRoot: A)
expectSet("S7 effectivePaths", s.effectivePaths, [])
s.accumulate(entryKeys: ["x.swift", "y.swift"], repositoryRoot: A)
expectSet("S7 effectivePaths after new file", s.effectivePaths, ["y.swift"])

// S8: pre-session dirty file stays suppressed even when modified further
var s8 = SessionHighlightStore()
s8.accumulate(entryKeys: ["dirty.swift"], repositoryRoot: A)   // baseline
s8.accumulate(entryKeys: ["dirty.swift"], repositoryRoot: A)   // still dirty — suppressed
expectSet("S8 pre-session suppressed", s8.effectivePaths, [])

// S9: empty baseline — everything after is effective
var s9 = SessionHighlightStore()
s9.accumulate(entryKeys: [], repositoryRoot: A)               // clean repo at session start
s9.accumulate(entryKeys: ["new.swift"], repositoryRoot: A)     // agent creates a file
expectSet("S9 clean-start new file", s9.effectivePaths, ["new.swift"])

// S10: baseline nil guard — effectivePaths before any accumulate
var s10 = SessionHighlightStore()
expectSet("S10 no accumulate", s10.effectivePaths, [])

// ── repository identity (#298): a different repository is a different session ──

// R1: repo A's touched README.md must not light repo B's README.md, and B's
// pre-existing dirt (never in A's baseline) must not read as touched.
var r = SessionHighlightStore()
r.accumulate(entryKeys: [], repositoryRoot: A)               // A clean at start
r.accumulate(entryKeys: ["README.md"], repositoryRoot: A)    // touched in A
expectSet("R0 touched in A", r.effectivePaths, ["README.md"])
r.accumulate(entryKeys: ["README.md", "old.swift"], repositoryRoot: B)
expectSet("R1 effectivePaths", r.effectivePaths, [])
expectSet("R1 baseline is B's first snapshot", r.baselinePaths ?? [], ["README.md", "old.swift"])
expectRoot("R1 repositoryRoot", r.repositoryRoot, B)

// R2: inside B, a newly dirty file is touched; A's paths stay gone
r.accumulate(entryKeys: ["README.md", "old.swift", "new.swift"], repositoryRoot: B)
expectSet("R2 effectivePaths", r.effectivePaths, ["new.swift"])
expectSet("R2 accumulated", r.accumulatedPaths, ["README.md", "old.swift", "new.swift"])

// R3: returning to A is a fresh session: A's README.md (still dirty) is now
// baseline, so it is not highlighted. False negative by design, never a positive.
r.accumulate(entryKeys: ["README.md"], repositoryRoot: A)
expectSet("R3 effectivePaths", r.effectivePaths, [])
expectRoot("R3 repositoryRoot", r.repositoryRoot, A)

// R4: no repository ends the session and nothing is tracked
r.accumulate(entryKeys: ["README.md", "x.swift"], repositoryRoot: A)
expectSet("R4 before", r.effectivePaths, ["x.swift"])
r.accumulate(entryKeys: [], repositoryRoot: nil)
expectBool("R4 hasStarted", r.hasStarted, false)
expectSet("R4 effectivePaths", r.effectivePaths, [])
expectRoot("R4 repositoryRoot", r.repositoryRoot, nil)

// R5: keys under a nil repository are never accumulated, and the next repository
// starts from its own first snapshot
r.accumulate(entryKeys: ["stray.swift"], repositoryRoot: nil)
expectSet("R5 nil-repo keys dropped", r.accumulatedPaths, [])
r.accumulate(entryKeys: ["x.swift"], repositoryRoot: A)
expectSet("R5 back in A, baseline only", r.effectivePaths, [])

// R6: reset clears the repository too
r.reset()
expectRoot("R6 reset repositoryRoot", r.repositoryRoot, nil)

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
# Each mutant is applied to a COPY of the shipped source (AFK.md, "Falsification
# must mutate a copy of SHIPPED source"). A mutant counts as caught only when ITS
# declared case fails. A pattern that no longer applies, or a mutant that does not
# compile, exits 2: it proves nothing, so it must not read as caught or skipped.

echo ""
echo "falsification..."

MUTANT_DIR="$TMPDIR_BASE/mutants"
mkdir -p "$MUTANT_DIR"

falsify_ok=0
falsify_fail=0

# run_mutant NAME SED_EXPR DECLARED_CASE DESCRIPTION
run_mutant() {
    local name="$1" expr="$2" declared="$3" desc="$4"
    cp "$POLICY" "$MUTANT_DIR/$name.swift"
    sed -i '' "$expr" "$MUTANT_DIR/$name.swift"
    if cmp -s "$POLICY" "$MUTANT_DIR/$name.swift"; then
        echo "FAIL: $name pattern no longer applies to the shipped source" >&2
        exit 2
    fi
    if ! swiftc -o "$MUTANT_DIR/$name" "$MUTANT_DIR/$name.swift" "$HARNESS" 2>/dev/null; then
        echo "FAIL: $name does not compile" >&2
        exit 2
    fi
    "$MUTANT_DIR/$name" > "$MUTANT_DIR/$name.out" 2>&1 || true
    if grep -q "FAIL  $declared:" "$MUTANT_DIR/$name.out"; then
        echo "  ok  $name ($desc) caught by $declared"
        falsify_ok=$((falsify_ok + 1))
    else
        echo "  FAIL  $name ($desc) not caught by its declared case $declared"
        falsify_fail=$((falsify_fail + 1))
    fi
}

# m1: remove baseline subtraction; S2 effective must be empty after the first snapshot.
run_mutant m1 's/return accumulatedPaths\.subtracting(baseline)/return accumulatedPaths/' \
    "S2 effectivePaths" "no baseline subtraction"

# m2: never capture baseline; S2 hasStarted must be true after the first snapshot.
run_mutant m2 's/if baselinePaths == nil {/if false {/' \
    "S2 hasStarted" "no baseline capture"

# m3: ignore repository identity, the #298 false positive. Repo A's touched path
# and repo B's pre-existing dirt both show in B, so R1 must fail.
run_mutant m3 's/if hasStarted \&\& root != repositoryRoot {/if false {/' \
    "R1 effectivePaths" "repository identity ignored"

# m4: a nil repository keeps the old session alive; R4 hasStarted must be false.
run_mutant m4 's/if hasStarted \&\& root != repositoryRoot {/if hasStarted \&\& root != nil \&\& root != repositoryRoot {/' \
    "R4 hasStarted" "no-repository keeps session"

echo ""
echo "falsification: $falsify_ok caught, $falsify_fail missed"

if [ "$falsify_ok" -eq 0 ] && [ "$falsify_fail" -eq 0 ]; then
    echo "FAIL: no mutant ran" >&2
    exit 2
fi
if [ "$falsify_fail" -gt 0 ]; then
    echo "FAIL: falsification" >&2
    exit 1
fi

echo ""
echo "all checks passed"
