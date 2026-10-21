#!/usr/bin/env bash
# check-progress-report.sh — T4.3 gate: OSC 9;4 progress state machine truth table.
#
# Compiles ProgressReportPolicy.swift (Foundation-only) standalone and exercises:
#   P1–P9   per-pane state machine (apply stateCode 0-4, clamp, commandFinished,
#           applyTimeout, unknown code)
#   A1–A8   aggregation (ProgressAggregation.of — all-none, error-dominates,
#           indeterminate, all-determinate mean, all-paused mean, mixed paused,
#           single-pane, empty)
#   R1–R4   payload parser (ProgressPayload.parse — valid, no-pct, invalid, empty)
#
# Exit codes (gate convention):
#   0  = all cases pass
#   1  = at least one assertion failed (a real policy regression)
#   2  = environmental failure (toolchain absent, compile failed, zero mutants applied)
#
# Falsification: two sed mutants on a COPY of ProgressReportPolicy.swift.
#   mutant-error-dominates: removes the `.error` dominance check — aggregation
#     must no longer return .error when mixed with determinate; must exit 1.
#   mutant-clamp: removes the min/max clamp on pct — a 200-pct apply must then
#     store 200 rather than 100; must exit 1.
#
# A zero-mutant run (no mutations applied to either copy) exits 2, proving the
# falsification is not vacuous.
#
set -uo pipefail
cd "$(dirname "$0")/.."
command -v swiftc >/dev/null || exit 2
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC="Sources/GoblinPortal/ProgressReportPolicy.swift"
[ -f "$SRC" ] || { echo "FAIL: $SRC not found"; exit 2; }

# ── Harness ──────────────────────────────────────────────────────────────────
cat > "$TMP/main.swift" << 'SWIFT'
import Foundation

var failures = 0
var total    = 0

func check(_ name: String, _ value: Bool) {
    total += 1
    if !value { failures += 1; print("FAIL \(name)") }
}

// ── P: Per-pane state machine ────────────────────────────────────────────────

// P1  stateCode 1 → determinate
var p = ProgressPanePolicy()
p.apply(stateCode: 1, progress: 50)
check("P1 set→determinate", p.state == .determinate(50))
check("P1 isActive",        p.isActive)

// P2  stateCode 0 → none (remove)
p.apply(stateCode: 0, progress: 0)
check("P2 remove→none",     p.state == .none)
check("P2 not active",      !p.isActive)

// P3  stateCode 2 → error
p.apply(stateCode: 2, progress: 0)
check("P3 error",           p.state == .error)

// P4  stateCode 3 → indeterminate
p.apply(stateCode: 3, progress: 0)
check("P4 indeterminate",   p.state == .indeterminate)

// P5  stateCode 4 → paused with pct
p.apply(stateCode: 4, progress: 75)
check("P5 paused",          p.state == .paused(75))

// P6  pct clamp: over-100 becomes 100
var p6 = ProgressPanePolicy()
p6.apply(stateCode: 1, progress: 200)
check("P6 clamp hi",        p6.state == .determinate(100))

// P7  pct clamp: negative becomes 0
var p7 = ProgressPanePolicy()
p7.apply(stateCode: 1, progress: -5)
check("P7 clamp lo",        p7.state == .determinate(0))

// P8  commandFinished clears active state
var p8 = ProgressPanePolicy()
p8.apply(stateCode: 1, progress: 40)
p8.commandFinished()
check("P8 commandFinished→none", p8.state == .none)
check("P8 not active",           !p8.isActive)

// P9  applyTimeout clears active state
var p9 = ProgressPanePolicy()
p9.apply(stateCode: 3, progress: 0)
p9.applyTimeout()
check("P9 timeout→none",    p9.state == .none)

// P10 unknown stateCode → none (conservative)
var p10 = ProgressPanePolicy()
p10.apply(stateCode: 99, progress: 50)
check("P10 unknown→none",   p10.state == .none)

// P11 lastUpdateDate set on active, nil on remove
var p11 = ProgressPanePolicy()
p11.apply(stateCode: 1, progress: 10)
check("P11 date set",       p11.lastUpdateDate != nil)
p11.apply(stateCode: 0, progress: 0)
check("P11 date cleared",   p11.lastUpdateDate == nil)

// ── A: Aggregation ───────────────────────────────────────────────────────────

// A1  all none → hidden
check("A1 all-none",        ProgressAggregation.of([.none, .none]) == .hidden)

// A2  empty → hidden
check("A2 empty",           ProgressAggregation.of([]) == .hidden)

// A3  error dominates over indeterminate and determinate
check("A3 error-dom",       ProgressAggregation.of([.error, .indeterminate, .determinate(50)]) == .error)

// A4  indeterminate dominates over determinate/paused (when no error)
check("A4 indet-dom",       ProgressAggregation.of([.indeterminate, .determinate(60)]) == .indeterminate)

// A5  all determinate → mean
check("A5 mean",            ProgressAggregation.of([.determinate(20), .determinate(80)]) == .determinate(50))

// A6  all paused → paused mean
check("A6 all-paused",      ProgressAggregation.of([.paused(30), .paused(70)]) == .paused(50))

// A7  mixed determinate + paused → determinate mean (not all-paused)
check("A7 mixed-paused",    ProgressAggregation.of([.determinate(40), .paused(60)]) == .determinate(50))

// A8  single determinate → that pct
check("A8 single",          ProgressAggregation.of([.determinate(77)]) == .determinate(77))

// A9  none mixed with determinate → ignore none
check("A9 none+det",        ProgressAggregation.of([.none, .determinate(50)]) == .determinate(50))

// ── R: Payload parser ────────────────────────────────────────────────────────

func bytes(_ s: String) -> ArraySlice<UInt8> { Array(s.utf8)[...] }

// R1  valid state+pct
if let r = ProgressPayload.parse(bytes("1;50")) {
    check("R1 stateCode", r.stateCode == 1)
    check("R1 progress",  r.progress  == 50)
} else { check("R1 parse", false) }

// R2  state only, no pct → pct = 0
if let r = ProgressPayload.parse(bytes("3")) {
    check("R2 stateCode", r.stateCode == 3)
    check("R2 pct=0",     r.progress  == 0)
} else { check("R2 parse", false) }

// R3  invalid (empty) → nil
check("R3 empty→nil",       ProgressPayload.parse(bytes("")) == nil)

// R4  non-numeric → nil
check("R4 bad→nil",         ProgressPayload.parse(bytes("set;50")) == nil)

// ── Verdict ──────────────────────────────────────────────────────────────────
print("\(total - failures)/\(total) passed")
exit(failures == 0 ? 0 : 1)
SWIFT

# ── Compile and run the truth table ─────────────────────────────────────────
compile() { swiftc "$1" "$TMP/main.swift" -o "$TMP/gate" 2>"$TMP/compile.log" || {
    cat "$TMP/compile.log"; exit 2; }; }
compile "$SRC"
"$TMP/gate" || exit $?

# ── Falsification mutants ────────────────────────────────────────────────────
# Each mutant counts only when ITS declared case fails: exit 1 from some other case
# is WRONG-CASE and a miss. A pattern that no longer applies to the shipped policy is
# environmental (exit 2) — never a silent skip, which the first version allowed for
# either mutant as long as the other one still matched.
mutant() {  # $1 name, $2 declared case label, $3 sed expression
    sed "$3" "$SRC" > "$TMP/mutant-$1.swift"
    if cmp -s "$SRC" "$TMP/mutant-$1.swift"; then
        echo "FAIL mutant $1: pattern no longer applies to the shipped policy (environmental)"
        exit 2
    fi
    compile "$TMP/mutant-$1.swift"
    local code=0
    "$TMP/gate" > "$TMP/$1.log" 2>&1 || code=$?
    if [ "$code" -eq 1 ] && grep -q "^FAIL $2" "$TMP/$1.log"; then
        echo "ok mutant $1 caught by $2"
    elif [ "$code" -eq 1 ]; then
        echo "FAIL mutant $1: WRONG-CASE (exit 1 but $2 did not fail)"; exit 1
    else
        echo "FAIL mutant $1 exited $code, expected 1 with $2 failing"; exit 1
    fi
}

# error-dominates: drop the `.error` dominance branch; A3 must fail.
mutant error-dominates "A3 " '/if active.contains(.error) { return .error }/d'
# clamp: drop the min/max clamp so 200 is stored; P6 must fail.
mutant clamp "P6 " 's/let pct = min(max(progress, 0), 100)/let pct = progress/'

echo "check-progress-report: passed (2 mutants, each caught by its declared case)"
