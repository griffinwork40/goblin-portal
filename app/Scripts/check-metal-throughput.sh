#!/bin/bash
#
# Throughput gate: measure frame-time for both CoreText and Metal renderers under a
# high-throughput payload and assert Metal is no worse than CoreText by more than 35%.
#
# WHY THIS EXISTS. The default renderer was `.coreText` because Metal's speed advantage
# was structurally obvious but unmeasured. This script is the measurement: it creates real
# on-screen views for both paths (offscreen at -20000,-20000 to avoid stealing focus),
# drives a high-throughput text payload through each, and compares median frame-times.
# Metal's `.perRowPersistent` buffering mode rebuilds only dirty rows; CoreText rebuilds
# every visible row through `buildAttributedString` + `CTLineCreateWithAttributedString`
# on every draw. A tie is the measured reality (issue #137 measured 4.29 vs 3.94 ms and
# 4.24 vs 4.66 ms across two runs with the gap approach); the gate's job is to confirm
# Metal does NOT regress, not to prove it wins every run.
#
# TIMING METHOD.
#   CoreText: wall-clock brackets around `view.display()` using CFAbsoluteTimeGetCurrent.
#             `display()` is synchronous — it calls `draw(_:)` on the calling thread and
#             returns when painting is complete, so the delta is exactly one frame's cost.
#   Metal:    wall-clock brackets around `mtkView.draw()` (synchronous MTKView draw).
#             Without an untimed gap between draws, Metal blocks waiting for a free
#             drawable; on a 120 Hz display that wait is ~8.3 ms — one vsync period —
#             dominating the actual render cost (issue #137, bug 2). A 20 ms RunLoop gap
#             between timed frames lets the previous drawable recycle, so the measured
#             interval is GPU encoding cost rather than vsync wait.
#
#   Metric: median frame-time (p50) and p95. Mean is also recorded but NOT used for the
#           pass rule — it is dominated by occasional GC/scheduler spikes that do not
#           reflect steady-state render cost.
#
# PAYLOAD. A 120×40 LocalProcessTerminalView fed ANSI text without a live pty. The
# payload contains colour escapes, bold, and mixed ASCII to exercise the glyph-atlas and
# attribute pipeline rather than trivial blank cells.
#
# PASS RULE. Metal median ≤ CoreText median × 1.35, i.e. ratio ≥ 0.741. Rationale:
# issue #137's reference probe (20 ms gap, same approach) measured ratios of 1.089 and
# 0.910 across two runs — a run-to-run spread of ~18% around the tie point. Doubling that
# for machine-to-machine variation and thermal differences gives ≈36%, rounded to 35%.
# This lets a tie pass on any machine while catching a catastrophic regression like the
# original broken harness's 7.4 ms Metal vs 2.0 ms CoreText. The previous "ratio ≥ 1.0"
# rule (Metal must win) failed on every tie and was the wrong bar: the default flip only
# needs Metal not to regress.
#
# COMPILE FAILURES. A harness that does not compile exits 2 (environmental), NOT 1.
# This is deliberate: a compile failure is a toolchain/environment problem — the harness
# cannot produce a verdict — not evidence that Metal regressed. The compile log is
# printed to stderr so it is not silently excused. (Issue #137 bug 1: the original
# harness lacked `import MetalKit`, so MTKView was out of scope, and passed `[UInt8]`
# where `feed(byteArray:)` requires `ArraySlice<UInt8>`; it always exited 2 and the
# broken harness hid behind the "no GPU / no WindowServer" excuse.)
#
# Exit codes:
#   0  Metal median ≤ CoreText median × 1.35 (validates the default flip)
#   1  Metal regresses by more than 35% vs CoreText (investigate before shipping)
#   2  environmental — no swiftc, no Metal device, no WindowServer, build failed,
#      or the harness would not compile. Never conflated with 1.
#
# Usage:
#   ./Scripts/check-metal-throughput.sh           # run the measurement
#   ./Scripts/check-metal-throughput.sh --quiet   # summary line and failures only

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" = "1" ] || echo "$@"; }

cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- environment ------------------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
fi

# Resolve the SwiftPM bin path the same way check-reflow.sh does — vendored-module.sh
# picks the right backend (Swift Build vs classic) and handles the merged SwiftTerm.o.
. Scripts/vendored-module.sh
resolve_vendored_module          # sets PRODUCTS, or exits 2

# --- compile the harness ----------------------------------------------------------
cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
import Metal
import MetalKit
import SwiftTerm

// Same posture as check-metal-renderer.sh — accessory policy, window offscreen.
// No focus is stolen, no Dock icon, no menu bar.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard MTLCreateSystemDefaultDevice() != nil else {
    print("RESULT env_fail NO_METAL_DEVICE")
    exit(0)
}

// --- helpers -------------------------------------------------------------------
// A simple TerminalViewDelegate that discards all callbacks. We feed the terminal
// buffer directly via feed() so we do not need a real pty.
class SilentDelegate: NSObject, LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

func makeView() -> LocalProcessTerminalView {
    let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 480))
    let d = SilentDelegate()
    // Hold delegate alive for the view's lifetime inside this function scope.
    objc_setAssociatedObject(v, Unmanaged.passUnretained(v).toOpaque(), d, .OBJC_ASSOCIATION_RETAIN)
    v.processDelegate = d
    return v
}

func makeWindow(view: NSView) -> NSWindow {
    let win = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 480),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    win.contentView = view
    win.makeKeyAndOrderFront(nil)
    return win
}

// High-throughput ANSI payload: colour escapes, bold, mixed ASCII. 40 lines worth.
func buildPayload() -> [UInt8] {
    var s = ""
    let colours = [31, 32, 33, 34, 35, 36, 37]
    for row in 0..<40 {
        let c = colours[row % colours.count]
        s += "\u{1B}[\(c)m\u{1B}[1mRow \(String(format: "%02d", row)):  "
        s += "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do "
        s += "eiusmod tempor incididunt ut labore et dolore\u{1B}[0m\r\n"
    }
    return Array(s.utf8)
}

// stats: emit per-renderer summary for the measurement log.
func stats(_ name: String, _ a: [Double]) {
    let s = a.sorted()
    let median = s[s.count / 2]
    let p95 = s[min(s.count - 1, Int(Double(s.count) * 0.95))]
    let mean = a.reduce(0, +) / Double(a.count)
    let meanEx10 = a.dropFirst(10).reduce(0, +) / Double(a.count - 10)
    print(String(format: "STAT %@ median=%.3f p95=%.3f mean=%.3f mean_excl_first10=%.3f",
                 name, median, p95, mean, meanEx10))
}

let payload = buildPayload()
let FRAMES = 150

// --- CoreText measurement -------------------------------------------------------
let ctView = makeView()
let ctWin = makeWindow(view: ctView)
// Let the view settle into the window before timing.
RunLoop.current.run(until: Date().addingTimeInterval(0.3))

// Prime the cache with the payload once before timing.
// feed(byteArray:) takes ArraySlice<UInt8>; payload[...] converts [UInt8] to a slice.
ctView.feed(byteArray: payload[...])
RunLoop.current.run(until: Date().addingTimeInterval(0.1))

var ctSamples: [Double] = []
for _ in 0..<FRAMES {
    // 20 ms untimed gap: lets CoreText's backing store settle between frames.
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    ctView.feed(byteArray: payload[...])
    let t0 = CFAbsoluteTimeGetCurrent()
    ctView.display()       // synchronous: draw(_:) runs on the calling thread
    let t1 = CFAbsoluteTimeGetCurrent()
    ctSamples.append((t1 - t0) * 1000.0)
}

ctWin.orderOut(nil)
RunLoop.current.run(until: Date().addingTimeInterval(0.1))

// --- Metal measurement ----------------------------------------------------------
let mtView = makeView()
let mtWin = makeWindow(view: mtView)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))

var threw = "none"
do {
    try mtView.setUseMetal(true)
} catch {
    threw = "\(error)"
}
RunLoop.current.run(until: Date().addingTimeInterval(0.2))

if !mtView.isUsingMetalRenderer {
    print("RESULT env_fail METAL_UNAVAILABLE threw=\(threw)")
    exit(0)
}

// Locate the MTKView that setUseMetal installed as a subview.
func findMTKView(in parent: NSView) -> MTKView? {
    for sub in parent.subviews {
        if let mtk = sub as? MTKView { return mtk }
        if let found = findMTKView(in: sub) { return found }
    }
    return nil
}

guard let mtkView = findMTKView(in: mtView) else {
    print("RESULT env_fail NO_MTKVIEW")
    exit(0)
}

mtView.feed(byteArray: payload[...])
RunLoop.current.run(until: Date().addingTimeInterval(0.1))

var mtSamples: [Double] = []
for _ in 0..<FRAMES {
    // 20 ms untimed gap: lets Metal's drawable pool recycle so the timed interval
    // measures GPU encoding cost, not vsync wait. Without the gap, draw() blocks
    // for ~8.3 ms on a 120 Hz display waiting for a free drawable (issue #137, bug 2).
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    mtView.feed(byteArray: payload[...])
    let t0 = CFAbsoluteTimeGetCurrent()
    mtkView.draw()         // synchronous MTKView draw: encodes + commits the frame
    let t1 = CFAbsoluteTimeGetCurrent()
    mtSamples.append((t1 - t0) * 1000.0)
}

mtWin.orderOut(nil)

// --- report --------------------------------------------------------------------
stats("coretext", ctSamples)
stats("metal",    mtSamples)

let ctMedian = ctSamples.sorted()[ctSamples.count / 2]
let mtMedian = mtSamples.sorted()[mtSamples.count / 2]
let ratio = ctMedian / mtMedian   // > 1.0 means Metal is faster; tie is ~1.0

print(String(format: "RESULT ct_median_ms=%.3f mt_median_ms=%.3f ratio=%.3f frames=%d",
             ctMedian, mtMedian, ratio, FRAMES))
SWIFT

# A harness that does not compile exits 2 — environmental, not a Metal regression.
# The compile log is printed so it is not silently excused (issue #137, bug 1).
if ! swiftc -O -o "$PRODUCTS/throughputcheck" "$TMP/main.swift" \
    -I "$PRODUCTS" -L "$PRODUCTS" "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit -framework Metal -framework MetalKit 2>"$TMP/compile.log"; then
  echo "error: the throughput harness would not compile — the gate cannot run." >&2
  echo "  (compile failure is exit 2, not exit 1; this is a toolchain/environment" >&2
  echo "   problem, not evidence that Metal regressed)" >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

say "==> running throughput measurement (150 frames each renderer)"
: > "$TMP/harness.err"
out="$("$PRODUCTS/throughputcheck" 2>"$TMP/harness.err" || echo "CRASH")"

if [ "$out" = "CRASH" ]; then
  echo "error: the throughput harness died — environmental, not a verdict." >&2
  [ -s "$TMP/harness.err" ] && sed 's/^/    /' "$TMP/harness.err" >&2
  exit 2
fi

if echo "$out" | grep -q "RESULT env_fail"; then
  reason="$(echo "$out" | sed -n 's/RESULT env_fail //p')"
  echo "error: environmental failure — $reason" >&2
  exit 2
fi

# Print per-renderer stats for measurement log.
echo "$out" | grep "^STAT"

# Parse RESULT line.
ct_ms="$(echo "$out" | sed -n 's/.*ct_median_ms=\([0-9.]*\).*/\1/p')"
mt_ms="$(echo "$out" | sed -n 's/.*mt_median_ms=\([0-9.]*\).*/\1/p')"
ratio="$(echo "$out" | sed -n 's/.*ratio=\([0-9.]*\).*/\1/p')"
frames="$(echo "$out" | sed -n 's/.*frames=\([0-9]*\).*/\1/p')"

if [ -z "$ct_ms" ] || [ -z "$mt_ms" ] || [ -z "$ratio" ]; then
  echo "error: could not parse RESULT line from harness output:" >&2
  echo "  $out" >&2
  exit 2
fi

say "  CoreText median frame-time : ${ct_ms} ms"
say "  Metal    median frame-time : ${mt_ms} ms"
say "  Ratio (CoreText/Metal)     : ${ratio}  (>=0.741 means Metal ≤ 35% slower)"
say "  Frames measured each       : ${frames}"
say

# Pass rule: Metal median ≤ CoreText median × 1.35, i.e. ratio ≥ 1/1.35 = 0.741.
# A tie (ratio ≈ 1.0) passes. Metal must not regress by more than 35%.
# Using awk for floating-point comparison (POSIX sh has no float arithmetic).
result="$(awk -v r="$ratio" 'BEGIN { print (r >= 0.741) ? "pass" : "fail" }')"

if [ "$result" = "pass" ]; then
  echo "throughput gate passed: Metal median ${mt_ms}ms, CoreText median ${ct_ms}ms (ratio ${ratio}, threshold >=0.741)"
  exit 0
else
  echo "✗ FAIL: Metal (${mt_ms}ms) regresses vs CoreText (${ct_ms}ms) by more than 35% (ratio ${ratio} < 0.741)" >&2
  echo "  The default Metal renderer has a severe performance problem. Investigate:" >&2
  echo "    - Confirm the Metal renderer is actually active (check-metal-renderer.sh)" >&2
  echo "    - Check for GPU throttling (thermal, power, background processes)" >&2
  echo "    - Re-run: transient spikes can invert a close race" >&2
  exit 1
fi
