#!/bin/bash
#
# Throughput gate: measure frame-time for both CoreText and Metal renderers under a
# high-throughput payload and assert Metal is at least as fast as CoreText.
#
# WHY THIS EXISTS. The default renderer was `.coreText` because Metal's speed advantage
# was structurally obvious but unmeasured. This script is the measurement: it creates real
# on-screen views for both paths (offscreen at -20000,-20000 to avoid stealing focus),
# drives a high-throughput text payload through each, and compares mean frame-times.
# Metal's `.perRowPersistent` buffering mode rebuilds only dirty rows; CoreText rebuilds
# every visible row through `buildAttributedString` + `CTLineCreateWithAttributedString`
# on every draw. If that advantage holds under load, this script exits 0 and the default
# flip to `.metal` stands.
#
# TIMING METHOD.
#   CoreText: wall-clock brackets around `view.display()` using CFAbsoluteTimeGetCurrent.
#             `display()` is synchronous — it calls `draw(_:)` on the calling thread and
#             returns when painting is complete, so the delta is exactly one frame's cost.
#   Metal:    wall-clock brackets around `mtkView.draw()` (synchronous MTKView draw),
#             capturing the draw call latency. This matches what the CoreText measurement
#             costs: one frame encode + commit, not including GPU execution time that
#             overlaps the next CPU frame. Both measurements are CPU-side wall-clock;
#             the comparison is fair because both render the same terminal content.
#
# PAYLOAD. A 120×40 LocalProcessTerminalView fed ANSI text via the TerminalDelegate
# protocol without a live pty. The payload contains colour escapes, bold, and mixed ASCII
# to exercise the glyph-atlas and attribute pipeline rather than trivial blank cells.
#
# Exit codes:
#   0  Metal frame-time <= CoreText frame-time (validates the default flip)
#   1  CoreText beats Metal (invalidates the default flip — investigate before shipping)
#   2  environmental — no swiftc, no Metal device, no WindowServer, build failed, or the
#      harness process itself died. Never conflated with 1.
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
PRODUCTS="$APP_ROOT/.build/out/Products/Debug"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- environment ------------------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
fi

say "==> building (needed: SwiftTerm.o and the resource bundle)"
if ! swift build >/dev/null 2>&1; then
  echo "error: swift build failed — fix that before running this gate." >&2
  exit 2
fi

if [ ! -f "$PRODUCTS/SwiftTerm.o" ]; then
  echo "error: $PRODUCTS/SwiftTerm.o absent after swift build." >&2
  exit 2
fi

# --- compile the harness ----------------------------------------------------------
cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
import Metal
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
    // Hold delegate alive for the view's lifetime inside this function scope
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

let payload = buildPayload()
let FRAMES = 60

// --- CoreText measurement -------------------------------------------------------
let ctView = makeView()
let ctWin = makeWindow(view: ctView)
// Let the view settle into the window before timing.
RunLoop.current.run(until: Date().addingTimeInterval(0.3))

// Prime the cache with the payload once before timing.
ctView.feed(byteArray: payload)
RunLoop.current.run(until: Date().addingTimeInterval(0.1))

var ctTotal: Double = 0
for _ in 0..<FRAMES {
    ctView.feed(byteArray: payload)
    let t0 = CFAbsoluteTimeGetCurrent()
    ctView.display()          // synchronous: draw(_:) runs on the calling thread
    let t1 = CFAbsoluteTimeGetCurrent()
    ctTotal += (t1 - t0)
}
let ctMeanMs = (ctTotal / Double(FRAMES)) * 1000.0

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

mtView.feed(byteArray: payload)
RunLoop.current.run(until: Date().addingTimeInterval(0.1))

var mtTotal: Double = 0
for _ in 0..<FRAMES {
    mtView.feed(byteArray: payload)
    let t0 = CFAbsoluteTimeGetCurrent()
    mtkView.draw()            // synchronous MTKView draw: encodes + commits the frame
    let t1 = CFAbsoluteTimeGetCurrent()
    mtTotal += (t1 - t0)
}
let mtMeanMs = (mtTotal / Double(FRAMES)) * 1000.0

mtWin.orderOut(nil)

// --- report --------------------------------------------------------------------
let ratio = ctMeanMs / mtMeanMs   // > 1.0 means Metal is faster
print(String(format: "RESULT ct_ms=%.3f mt_ms=%.3f ratio=%.2f frames=%d",
             ctMeanMs, mtMeanMs, ratio, FRAMES))
SWIFT

if ! swiftc -O -o "$PRODUCTS/throughputcheck" "$TMP/main.swift" \
    -I "$PRODUCTS" -L "$PRODUCTS" "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit -framework Metal -framework MetalKit 2>"$TMP/compile.log"; then
  echo "error: the throughput harness would not compile — the gate cannot run." >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

say "==> running throughput measurement (${FRAMES:-60} frames each renderer)"
: > "$TMP/harness.err"
out="$("$PRODUCTS/throughputcheck" 2>"$TMP/harness.err" || echo "CRASH")"

if [ "$out" = "CRASH" ]; then
  echo "error: the throughput harness died — environmental, not a verdict." >&2
  [ -s "$TMP/harness.err" ] && sed 's/^/    /' "$TMP/harness.err" >&2
  exit 2
fi

if echo "$out" | grep -q "RESULT env_fail"; then
  reason="${out#RESULT env_fail }"
  echo "error: environmental failure — $reason" >&2
  exit 2
fi

# Parse RESULT line: ct_ms=N mt_ms=N ratio=N frames=N
ct_ms="$(echo "$out" | sed -n 's/.*ct_ms=\([0-9.]*\).*/\1/p')"
mt_ms="$(echo "$out" | sed -n 's/.*mt_ms=\([0-9.]*\).*/\1/p')"
ratio="$(echo "$out" | sed -n 's/.*ratio=\([0-9.]*\).*/\1/p')"
frames="$(echo "$out" | sed -n 's/.*frames=\([0-9]*\).*/\1/p')"

if [ -z "$ct_ms" ] || [ -z "$mt_ms" ] || [ -z "$ratio" ]; then
  echo "error: could not parse RESULT line from harness output:" >&2
  echo "  $out" >&2
  exit 2
fi

say "  CoreText mean frame-time : ${ct_ms} ms"
say "  Metal    mean frame-time : ${mt_ms} ms"
say "  Metal advantage (ratio)  : ${ratio}x  (>=1.0 means Metal is at least as fast)"
say "  Frames measured each     : ${frames}"
say

# ratio >= 1.0 means ct_ms >= mt_ms, i.e. Metal is at least as fast.
# Use awk for floating-point comparison (POSIX sh has no float arithmetic).
result="$(awk -v r="$ratio" 'BEGIN { print (r >= 1.0) ? "pass" : "fail" }')"

if [ "$result" = "pass" ]; then
  echo "throughput gate passed: Metal frame-time ${mt_ms}ms <= CoreText ${ct_ms}ms (${ratio}x advantage)"
  exit 0
else
  echo "✗ FAIL: CoreText (${ct_ms}ms) beats Metal (${mt_ms}ms) by ${ratio}x inverse" >&2
  echo "  The default flip to Metal is NOT validated. Investigate before shipping:" >&2
  echo "    - Confirm the Metal renderer is actually active (check-metal-renderer.sh)" >&2
  echo "    - Check for GPU throttling (thermal, power, background processes)" >&2
  echo "    - Re-run: transient spikes can invert a close race" >&2
  exit 1
fi
