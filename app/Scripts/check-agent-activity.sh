#!/bin/bash
# check-agent-activity.sh — headless truth table over AgentActivityPolicy.
#
# Compiles the shipped AgentActivityPolicy.swift (Foundation-only) and runs
# a truth table verifying the output-activity heuristic: isCommand × elapsed →
# OutputActivity.  Two sed mutants on a COPY, each counted only when ITS
# declared case fails.
#
# exit 0  = all cases pass
# exit 1  = assertion failure
# exit 2  = environmental (compile failed, no source, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${GATE_SRC_DIR:-$SCRIPT_DIR/../Sources/GoblinPortal}"
POLICY="$SRC_DIR/AgentActivityPolicy.swift"

[ -f "$POLICY" ] || { echo "FAIL: AgentActivityPolicy.swift not found at $POLICY" >&2; exit 2; }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

HARNESS="$TMPDIR_BASE/main.swift"

cat > "$HARNESS" << 'HARNESS_EOF'
import Foundation

// ── helpers ──────────────────────────────────────────────────────────────────
var passed = 0
var failed = 0

func expect(_ label: String, _ got: OutputActivity, _ want: OutputActivity) {
    if got == want {
        print("  ok  \(label)")
        passed += 1
    } else {
        print("  FAIL  \(label): got \(got), want \(want)")
        failed += 1
    }
}

// ── truth table ──────────────────────────────────────────────────────────────
print("==> check-agent-activity.sh (AgentActivityPolicy truth table)")

// A1: not a command → notApplicable, regardless of elapsed
expect("A1-not-command-nil",
    AgentActivityPolicy.activity(isCommand: false, secondsSinceLastOutput: nil),
    .notApplicable)
expect("A1-not-command-zero",
    AgentActivityPolicy.activity(isCommand: false, secondsSinceLastOutput: 0),
    .notApplicable)
expect("A1-not-command-large",
    AgentActivityPolicy.activity(isCommand: false, secondsSinceLastOutput: 100),
    .notApplicable)

// A2: command, no output yet → silent
expect("A2-command-nil",
    AgentActivityPolicy.activity(isCommand: true, secondsSinceLastOutput: nil),
    .silent)

// A3: command, output within threshold → active
expect("A3-command-fresh-0.5s",
    AgentActivityPolicy.activity(isCommand: true, secondsSinceLastOutput: 0.5),
    .active)
expect("A3-command-fresh-0s",
    AgentActivityPolicy.activity(isCommand: true, secondsSinceLastOutput: 0),
    .active)
expect("A3-command-fresh-2.9s",
    AgentActivityPolicy.activity(isCommand: true, secondsSinceLastOutput: 2.9),
    .active)

// A4: boundary — threshold inclusive
expect("A4-command-boundary-3.0s",
    AgentActivityPolicy.activity(isCommand: true, secondsSinceLastOutput: 3.0),
    .active)

// A5: command, past threshold → silent
expect("A5-command-silent-3.01s",
    AgentActivityPolicy.activity(isCommand: true, secondsSinceLastOutput: 3.01),
    .silent)
expect("A5-command-silent-10s",
    AgentActivityPolicy.activity(isCommand: true, secondsSinceLastOutput: 10),
    .silent)
expect("A5-command-silent-60s",
    AgentActivityPolicy.activity(isCommand: true, secondsSinceLastOutput: 60),
    .silent)

// P1: threshold pin — verify the constant is 3.0
if AgentActivityPolicy.silenceThreshold == 3.0 {
    print("  ok  P1-threshold-pin: 3.0s")
    passed += 1
} else {
    print("  FAIL  P1-threshold-pin: expected 3.0, got \(AgentActivityPolicy.silenceThreshold)")
    failed += 1
}

print("")
if failed > 0 {
    print("\(passed) passed, \(failed) FAILED")
    exit(1)
} else {
    print("\(passed) passed, 0 failed")
}
HARNESS_EOF

# ── compile and run ──────────────────────────────────────────────────────────
BIN="$TMPDIR_BASE/check-agent-activity"
if ! swiftc -O -module-name GoblinPortal -o "$BIN" "$POLICY" "$HARNESS" 2>&1; then
    echo "FAIL: compile error" >&2
    exit 2
fi
"$BIN" || exit 1

# ── falsification ────────────────────────────────────────────────────────────
echo ""
echo "==> falsification (2 mutants on copies)"

MUTANT_PASS=0
MUTANT_TOTAL=0

# m1: change threshold from 3.0 to 0.5 — A3-command-fresh-2.9s must fail
MUTANT_TOTAL=$((MUTANT_TOTAL + 1))
MUTANT_DIR="$TMPDIR_BASE/m1"
mkdir -p "$MUTANT_DIR"
sed 's/silenceThreshold: TimeInterval = 3\.0/silenceThreshold: TimeInterval = 0.5/' \
    "$POLICY" > "$MUTANT_DIR/AgentActivityPolicy.swift"
if ! grep -q 'TimeInterval = 0.5' "$MUTANT_DIR/AgentActivityPolicy.swift"; then
    echo "  m1: pattern no longer applies (exit 2)"
    exit 2
fi
BIN_M1="$TMPDIR_BASE/m1-bin"
if swiftc -O -module-name GoblinPortal -o "$BIN_M1" "$MUTANT_DIR/AgentActivityPolicy.swift" "$HARNESS" 2>/dev/null; then
    if ! "$BIN_M1" >/dev/null 2>&1; then
        echo "  ok  m1: threshold 0.5 caught (exit 1)"
        MUTANT_PASS=$((MUTANT_PASS + 1))
    else
        echo "  FAIL  m1: mutant passed — gate is vacuous"
    fi
else
    echo "  m1: compile failed (exit 2)"
    exit 2
fi

# m2: invert the guard so isCommand:false returns .active — A1 must fail
MUTANT_TOTAL=$((MUTANT_TOTAL + 1))
MUTANT_DIR="$TMPDIR_BASE/m2"
mkdir -p "$MUTANT_DIR"
sed 's/guard isCommand else { return .notApplicable }/guard !isCommand else { return .notApplicable }/' \
    "$POLICY" > "$MUTANT_DIR/AgentActivityPolicy.swift"
if ! grep -q '!isCommand' "$MUTANT_DIR/AgentActivityPolicy.swift"; then
    echo "  m2: pattern no longer applies (exit 2)"
    exit 2
fi
BIN_M2="$TMPDIR_BASE/m2-bin"
if swiftc -O -module-name GoblinPortal -o "$BIN_M2" "$MUTANT_DIR/AgentActivityPolicy.swift" "$HARNESS" 2>/dev/null; then
    if ! "$BIN_M2" >/dev/null 2>&1; then
        echo "  ok  m2: inverted guard caught (exit 1)"
        MUTANT_PASS=$((MUTANT_PASS + 1))
    else
        echo "  FAIL  m2: mutant passed — gate is vacuous"
    fi
else
    echo "  m2: compile failed (exit 2)"
    exit 2
fi

echo ""
echo "$MUTANT_PASS/$MUTANT_TOTAL falsification mutants caught"
[ "$MUTANT_PASS" -eq "$MUTANT_TOTAL" ] || exit 1
