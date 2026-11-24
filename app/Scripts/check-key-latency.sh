#!/bin/bash
# check-key-latency.sh owns headless compilation and mutation orchestration.
# Assertions live in the sibling harness so both concerns stay below 350 LOC.
# Mutants edit APFS copies of SHIPPED source, not expectations (AFK.md Conventions).
# Exit 0 = pass, 1 = assertion/missed mutant, 2 = missing source/compile/stale mutant.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${GATE_SRC_DIR:-$SCRIPT_DIR/../Sources/GoblinPortal}"
MODEL="$SRC_DIR/KeyLatencyModel.swift"
[ -f "$MODEL" ] || { echo "missing $MODEL" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$SCRIPT_DIR/check-key-latency-harness.swift" "$TMP/main.swift"

compile() {
    if ! swiftc -swift-version 6 -O -o "$2" "$1" "$TMP/main.swift"; then
        echo "compile failed (exit 2)" >&2
        exit 2
    fi
}
compile "$MODEL" "$TMP/baseline"
"$TMP/baseline" || exit 1

echo "==> falsification (4 mutants on shipped-source copies)"
ran=0
caught=0
mutate() {
    local name="$1" expression="$2" declared="$3"
    local copy="$TMP/$name.swift" binary="$TMP/$name" output="$TMP/$name.out"
    # A file-level clone is sufficient: the model has no source dependencies.
    # No mutation is ever written to SRC_DIR (check-agent-activity.sh:126).
    cp -c "$MODEL" "$copy" || { echo "clone failed (exit 2)"; exit 2; }
    sed "$expression" "$copy" > "$TMP/changed.swift"
    if cmp -s "$copy" "$TMP/changed.swift"; then
        echo "$name: pattern no longer applies (exit 2)"
        exit 2
    fi
    cp "$TMP/changed.swift" "$copy"
    compile "$copy" "$binary"
    ran=$((ran + 1))
    local status=0
    "$binary" > "$output" 2>&1 || status=$?
    if [ "$status" -eq 1 ] && grep -Fxq "FAIL $declared" "$output"; then
        echo "ok $name: caught by $declared (exit 1)"
        caught=$((caught + 1))
    else
        echo "FAIL $name: missed or WRONG-CASE (exit $status; expected $declared)"
        cat "$output"
    fi
}
mutate output-order 's/pending\[index\].key <= time/pending[index].key >= time/' output-before-key
mutate frame-order 's/output <= time/output >= time/' frame-before-output
mutate timeout 's/let echoTimeout: TimeInterval = 2.0/let echoTimeout: TimeInterval = 20.0/' unechoed-timeout
mutate frame-timeout 's/let frameTimeout: TimeInterval = 5.0/let frameTimeout: TimeInterval = 50.0/' output-no-frame-expires
[ "$ran" -gt 0 ] || { echo "no mutant ran (exit 2)"; exit 2; }
echo "$caught/$ran falsification mutants caught"
[ "$caught" -eq "$ran" ] || exit 1
