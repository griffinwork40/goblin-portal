#!/bin/bash
# Retained physical/Metal memory of hidden real TerminalPanes and release/re-show cost.
# Measurement tool, not a gate: exits 0 always, including build/environment failures.
# Builds release objects with testable symbols. Alpha-zero click-through windows never activate.
# Usage: ./Scripts/measure-gpu-release.sh [--quick|--timing|--memory]
# Raw output persists in .afk/research/gpu-release-raw-<timestamp>/; no verdict is inferred here.
# Fixed decision rule: >=8 MiB/pane OR >=50 MiB/8 panes returned AND correct p95 <50 ms.
# Timing invalid above 0.70 load/CPU. Memory runs regardless of load.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0
ROOT="$(pwd)"
OUT="${GPU_RELEASE_OUT:-$ROOT/../.afk/research/gpu-release-raw-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
exec > >(tee "$OUT/driver.log") 2>&1
trap 'exit 0' EXIT
MODE="${1:---all}"
echo "Measurement only; thresholds fixed before execution. Output: $OUT"
date; sw_vers; sysctl hw.model hw.ncpu hw.memsize machdep.cpu.brand_string vm.loadavg
printf 'base='; git rev-parse HEAD
shasum -a 256 ../vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift
FLAGS=()
swift build --help 2>&1 | grep -q -- '--build-system' && FLAGS=(--build-system swiftbuild)
if ! swift build "${FLAGS[@]}" -c release -Xswiftc -enable-testing -Xswiftc -no-whole-module-optimization >"$OUT/build.log" 2>&1; then
    echo "ERROR=build"; tail -30 "$OUT/build.log"; exit 0
fi
PRODUCTS="$(swift build "${FLAGS[@]}" -c release --show-bin-path 2>/dev/null)"
OBJS="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
    -path '*GoblinPortal.build/Release/GoblinPortal-p.build/Objects-normal/*' | head -1)"
if [ ! -f "$OBJS/TerminalPane.o" ] || [ ! -f "$PRODUCTS/SwiftTerm.o" ]; then
    echo "ERROR=missing-release-objects"; exit 0
fi
# Bundle.main must find the vendored shader bundle beside this executable.
BIN="$PRODUCTS/gpu-release-measure"
cp Scripts/measure-gpu-release-harness.swift "$OUT/main.swift"
if ! swiftc -O -Xlinker -dead_strip -swift-version 6 -default-isolation MainActor -o "$BIN" "$OUT/main.swift" \
    -I "$OBJS" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $(find "$OBJS" -maxdepth 1 -name '*.o' ! -name 'main.o') "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit -framework Metal -framework MetalKit >"$OUT/compile.log" 2>&1; then
    echo "ERROR=compile"; cat "$OUT/compile.log"; exit 0
fi
run() {
    local label="$1"; shift
    echo "RUN=$label load=$(sysctl -n vm.loadavg)"
    "$BIN" "$@" >"$OUT/$label.txt" 2>"$OUT/$label.err"
    local rc=$?
    cat "$OUT/$label.txt"
    if [ "$rc" != 0 ]; then echo "ERROR=process-exit-$rc"; tail -20 "$OUT/$label.err"; fi
}
if [ "$MODE" = --quick ]; then
    run quick memory 8 1 metal
else
    if [ "$MODE" != --timing ]; then
        for rep in 1 2 3; do
            # Reverse configuration order in the middle repeat to expose drift.
            if [ "$rep" = 2 ]; then sizes="8 4 0"; else sizes="0 4 8"; fi
            for n in $sizes; do
                run "metal-r$rep-n$n" memory "$n" "$rep" metal
                run "coretext-r$rep-n$n" memory "$n" "$rep" coretext
            done
        done
    fi
    if [ "$MODE" != --memory ]; then
        for rep in 1 2 3; do run "timing-r$rep" timing 40 "$rep" metal; done
    fi
fi
echo "Raw observations: $OUT"
exit 0
