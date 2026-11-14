#!/bin/bash
# Hidden-pane resource census + full/partial release and actual presentation timing.
# Measurement only: exits 0, ERROR/SKIP means missing evidence, never a passing gate.
# Examples: --breakdown --repeats 3; --timing --presentation visible --hold 5 --samples 40
# --census instruments ONLY a disposable vendor copy (verify-vendor must pass first).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0
ROOT="$(pwd)"
OUT="${GPU_RELEASE_OUT:-$ROOT/../.afk/research/gpu-release-raw-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
exec > >(tee "$OUT/driver.log") 2>&1
trap 'exit 0' EXIT
MODE=--all; PRESENTATION=invisible; HOLD=0; SAMPLES=40; REPEATS=3; CENSUS=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --all|--quick|--memory|--timing|--breakdown) MODE="$1"; shift ;;
        --presentation) PRESENTATION="${2:-}"; shift 2 ;;
        --hold) HOLD="${2:-}"; shift 2 ;;
        --samples) SAMPLES="${2:-}"; shift 2 ;;
        --repeats) REPEATS="${2:-}"; shift 2 ;;
        --census) CENSUS=1; shift ;;
        *) echo "ERROR=unknown-option-$1"; exit 0 ;;
    esac
done
case "$PRESENTATION" in invisible|visible) ;; *) echo ERROR=presentation; exit 0 ;; esac
if ! python3 - "$HOLD" "$SAMPLES" "$REPEATS" <<'PY'
import sys
assert float(sys.argv[1]) >= 0
assert int(sys.argv[2]) > 0 and int(sys.argv[3]) > 0
PY
then echo ERROR=parameters; exit 0; fi
if [ "$PRESENTATION" = visible ] && [ "$MODE" != --timing ]; then
    echo ERROR=visible-only-for-explicit-timing; exit 0
fi
echo "Measurement only. Output: $OUT"
echo "CONFIG mode=$MODE presentation=$PRESENTATION hold=$HOLD samples=$SAMPLES repeats=$REPEATS census=$CENSUS"
date; sw_vers; sysctl hw.model hw.ncpu hw.memsize machdep.cpu.brand_string vm.loadavg
printf 'base='; git rev-parse HEAD
VENDOR="$ROOT/../vendor/SwiftTerm/Sources/SwiftTerm"
SWIFTFLAGS=(-D GPU_RELEASE_MEASUREMENT)
if [ "$CENSUS" = 1 ]; then
    # Preserve original bytes and exact experiment delta; never touch the main checkout.
    mkdir -p "$OUT/vendor-before"
    for f in Apple/TerminalRenderOwner.swift Apple/Metal/GlyphAtlas.swift Apple/Metal/MetalTerminalRenderer.swift Apple/Metal/TerminalMetalLayerView.swift; do
        cp "$VENDOR/$f" "$OUT/vendor-before/$(basename "$f")"
    done
    if ! python3 Scripts/measure-gpu-release-instrument.py; then echo ERROR=instrument; exit 0; fi
    SWIFTFLAGS=(-D GPU_RELEASE_CENSUS)
    for f in Apple/TerminalRenderOwner.swift Apple/Metal/GlyphAtlas.swift Apple/Metal/MetalTerminalRenderer.swift Apple/Metal/TerminalMetalLayerView.swift; do
        diff -u "$OUT/vendor-before/$(basename "$f")" "$VENDOR/$f" || true
    done > "$OUT/vendor-census.diff"
fi
shasum -a 256 "$VENDOR/Mac/MacTerminalView.swift" "$VENDOR/Apple/Metal/MetalTerminalRenderer.swift"
FLAGS=()
# swiftbuild + no-WMO fails its plugin dependency-file expectation on Swift 6.4.
# Native SPM emits individual .swift.o files and preserves the same -O renderer.
swift build --help 2>&1 | grep -q -- '--build-system' && FLAGS=(--build-system native)
if ! swift build "${FLAGS[@]}" -c release -Xswiftc -enable-testing -Xswiftc -no-whole-module-optimization >"$OUT/build.log" 2>&1; then
    echo "ERROR=build"; tail -30 "$OUT/build.log"; exit 0
fi
PRODUCTS="$(swift build "${FLAGS[@]}" -c release --show-bin-path 2>/dev/null)"
OBJS="$PRODUCTS/GoblinPortal.build"
if [ ! -f "$OBJS/TerminalPane.swift.o" ]; then echo ERROR=missing-release-objects; exit 0; fi
# Use the package's complete dependency closure, excluding only its entry point.
grep -v '/GoblinPortal.build/main.swift.o$' "$PRODUCTS/GoblinPortal.product/Objects.LinkFileList" > "$OUT/objects.list"
BIN="$PRODUCTS/gpu-release-measure"
cp Scripts/measure-gpu-release-harness.swift "$OUT/main.swift"
cp Scripts/measure-gpu-release-resources.swift "$OUT/resources.swift"
if ! swiftc -O -Xlinker -dead_strip -swift-version 6 -default-isolation MainActor "${SWIFTFLAGS[@]}" -o "$BIN" \
    "$OUT/main.swift" "$OUT/resources.swift" -I "$PRODUCTS/Modules" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    @"$OUT/objects.list" \
    -framework AppKit -framework Metal -framework MetalKit >"$OUT/compile.log" 2>&1; then
    echo "ERROR=compile"; cat "$OUT/compile.log"; exit 0
fi
run() {
    local label="$1"; shift
    echo "RUN=$label load=$(sysctl -n vm.loadavg)"
    "$BIN" "$@" "$PRESENTATION" "$HOLD" >"$OUT/$label.txt" 2>"$OUT/$label.err"
    local rc=$?
    cat "$OUT/$label.txt"
    if [ "$rc" != 0 ]; then echo "ERROR=process-exit-$rc"; tail -20 "$OUT/$label.err"; fi
}
if [ "$MODE" = --quick ]; then
    run quick breakdown 8 1 shrink
elif [ "$MODE" = --breakdown ]; then
    for rep in $(seq 1 "$REPEATS"); do
        if [ "$rep" = 2 ]; then arms="drain contents device shrink"; else arms="shrink device contents drain"; fi
        for arm in $arms; do run "$arm-r$rep" breakdown 8 "$rep" "$arm"; done
    done
else
    if [ "$MODE" != --timing ]; then
        for rep in $(seq 1 "$REPEATS"); do
            if [ "$rep" = 2 ]; then sizes="8 4 0"; else sizes="0 4 8"; fi
            for n in $sizes; do
                run "metal-r$rep-n$n" memory "$n" "$rep" metal
                run "coretext-r$rep-n$n" memory "$n" "$rep" coretext
            done
        done
    fi
    if [ "$MODE" != --memory ]; then
        # One explicit command = one uncensored timing population.
        run timing timing "$SAMPLES" 1 metal
    fi
fi
echo "Raw observations: $OUT"
exit 0
