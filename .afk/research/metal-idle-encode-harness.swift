// Investigation harness for issue #143: measure where the ~4% per-core cost goes
// in a 12 Hz spinner scenario after patch 0011.
//
// Linked against the vendored SwiftTerm.o (same way as check-metal-throughput.sh).
// Offscreen window at alpha=0, click-through — never steals focus, draws nothing visible.
//
// What it measures:
//   A. Row-rebuild rate — does the cache actually hit on 12 Hz spinner?
//      Uses the DEBUG FPS log line (Metal FPS / rows rebuilt / rows cached) if built
//      in debug mode; in release we measure CPU directly.
//   B. Per-frame CPU time via getrusage (RUSAGE_SELF): user+sys microseconds per frame.
//      Measured in two scenarios:
//        spinner: 12 Hz updates of ONE row, the other rows cached
//        idle:    no updates at all (zero dirty rows, pure "present a cached frame")
//   C. Frame interval distribution: do we draw at all / how often?
//
// Two harness modes:
//   spinner   120 frames of 12 Hz single-row updates (identical to issue #143's scenario)
//   idle      120 frames with zero updates (measure the floor of a present)
//
// Output format (one KEY=val line per result):
//   MODE, FRAMES, DRAWS, PERIOD_MS, CPU_USER_US_PER_FRAME, CPU_SYS_US_PER_FRAME,
//   CPU_TOTAL_US_PER_FRAME, P50_FRAME_MS, P95_FRAME_MS, ROWS_VISIBLE,
//   WINDOW_COMPOSITOR_NOTE
//
// Exit 0: measured; exit 2: environmental (no Metal, no window server).

import AppKit
import Darwin
import Metal
import MetalKit
import SwiftTerm

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "spinner"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // never steals focus

// --- Build an offscreen (alpha=0, click-through) window on the main screen ------
guard let screenFrame = NSScreen.main?.frame else {
    print("ENV=no_screen")
    exit(2)
}
// Put the window at the far corner of the screen — visible to WindowServer (needed
// for display-link ticks) but invisible (alphaValue = 0).
let winRect = NSRect(x: screenFrame.minX, y: screenFrame.minY, width: 960, height: 480)
let win = NSWindow(contentRect: winRect,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
win.alphaValue = 0
win.ignoresMouseEvents = true
win.orderFrontRegardless()

// --- Terminal view in a clip view (matches TerminalPane layout) -----------------
let container = NSView(frame: NSRect(origin: .zero, size: winRect.size))
win.contentView = container

// Simple delegate that discards all pty callbacks.
class SilentDelegate: NSObject, LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
let delegate = SilentDelegate()

let termView = LocalProcessTerminalView(frame: container.bounds)
termView.autoresizingMask = [.width, .height]
container.addSubview(termView)
// Retain delegate for the life of the run.
objc_setAssociatedObject(termView, Unmanaged.passUnretained(termView).toOpaque(),
                         delegate, .OBJC_ASSOCIATION_RETAIN)
termView.processDelegate = delegate

func pump(_ t: Double) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

// Let the view settle into the window.
pump(0.3)

// Switch to Metal.
do {
    try termView.setUseMetal(true)
} catch {
    print("ENV=metal_unavailable error=\(error)")
    exit(2)
}
pump(0.3)

guard termView.isUsingMetalRenderer else {
    print("ENV=metal_not_active")
    exit(2)
}

// Find the MTKView installed by setUseMetal.
func findMTKView(in parent: NSView) -> MTKView? {
    for sub in parent.subviews {
        if let v = sub as? MTKView { return v }
        if let found = findMTKView(in: sub) { return found }
    }
    return nil
}
guard let mtkView = findMTKView(in: termView) else {
    print("ENV=no_mtkview")
    exit(2)
}

// Set up a blinking cursor style so the cursor-blink timer does NOT fire extra draws
// (use steady block — same as the app default Goblin Portal uses after a68fd1eb).
// If we left the default (which may be blinkBlock), the cursor timer fires at 0.7s
// and adds extra setNeedsDisplay calls outside our measurement window.
termView.feed(text: "\u{1b}[2 q\u{1b}[2J\u{1b}[H")
pump(0.2)

// --- Fill the screen with content so the atlas is warm -------------------------
// Use a realistic ANSI payload: mixed colour, bold, text. 40 rows × 100 chars.
var payload = ""
let colours = [31, 32, 33, 34, 35, 36, 37]
for row in 0..<40 {
    let c = colours[row % colours.count]
    payload += "\u{1b}[\(c)m\u{1b}[1mRow \(String(format: "%02d", row)): "
    payload += "Lorem ipsum dolor sit amet consectetur adipiscing elit eiusmod tempor"
    payload += "\u{1b}[0m\r\n"
}
termView.feed(text: payload)
pump(0.3)

// Force the first full frame and let the cache warm.
mtkView.draw()
pump(0.05)
mtkView.draw()
pump(0.05)

// --- Instrument: proxy the MTKView delegate so we can time each frame ----------
var drawTimestamps: [Double] = []
var cpuUserPerFrame: [Double] = []
var cpuSysPerFrame: [Double] = []
var rowsRebuiltLog: [Int] = []
var rowsCachedLog: [Int] = []

final class TimingProxy: NSObject, MTKViewDelegate {
    let inner: MTKViewDelegate

    init(_ inner: MTKViewDelegate) {
        self.inner = inner
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        inner.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        let t0 = CACurrentMediaTime()

        inner.draw(in: view)

        let t1 = CACurrentMediaTime()
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)

        drawTimestamps.append(t1)
        let userUs = Double(after.ru_utime.tv_sec - before.ru_utime.tv_sec) * 1_000_000.0
                  + Double(after.ru_utime.tv_usec - before.ru_utime.tv_usec)
        let sysUs  = Double(after.ru_stime.tv_sec - before.ru_stime.tv_sec) * 1_000_000.0
                   + Double(after.ru_stime.tv_usec - before.ru_stime.tv_usec)
        cpuUserPerFrame.append(userUs)
        cpuSysPerFrame.append(sysUs)
        _ = t0  // captured for potential interval use
    }
}

guard let originalDelegate = mtkView.delegate else {
    print("ENV=no_delegate")
    exit(2)
}
let proxy = TimingProxy(originalDelegate)
mtkView.delegate = proxy

// --- Measure: the spinner scenario (12 Hz, one row updated per frame) ----------
//
// We drive the MTKView synchronously via mtkView.draw() with a 83 ms gap between
// calls (12 Hz ≈ 83ms). One row update per frame: move cursor to row 5, rewrite
// a single spinner character. This mimics the agent spinner exactly.
//
// "idle" mode: same loop but no feed() call — zero dirty rows, pure present.
//
let FRAMES = 120
let SPINNER = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
var spinIdx = 0

// Reset getrusage baseline to the measurement window only.
var baselineUsage = rusage()
getrusage(RUSAGE_SELF, &baselineUsage)

for i in 0..<FRAMES {
    // 83 ms untimed gap: simulates 12 Hz producer interval.
    pump(0.083)

    if mode == "spinner" {
        // Update only row 5 of the terminal: move to position, write spinner char.
        let s = SPINNER[spinIdx % SPINNER.count]
        spinIdx += 1
        termView.feed(text: "\u{1b}[6;1H\(s) frame \(i)  ")
    }
    // else idle: no update — the MTKView is told to draw via its display link or
    // we call draw() below to force a frame for measurement.

    mtkView.draw()
}

var finalUsage = rusage()
getrusage(RUSAGE_SELF, &finalUsage)

// --- Compute stats --------------------------------------------------------------
func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
func avg(_ xs: [Double]) -> Double {
    xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count)
}

let draws = drawTimestamps.count
let intervals = zip(drawTimestamps.dropFirst(), drawTimestamps).map { ($0 - $1) * 1000.0 }
let p50frame = pct(intervals, 0.5)
let p95frame = pct(intervals, 0.95)

let p50userCPU = pct(cpuUserPerFrame, 0.5)
let p50sysCPU  = pct(cpuSysPerFrame, 0.5)
let p50total   = p50userCPU + p50sysCPU
let avgUserCPU = avg(cpuUserPerFrame)
let avgSysCPU  = avg(cpuSysPerFrame)

// Whole-measurement CPU from getrusage for a cross-check.
let totalUserUs = Double(finalUsage.ru_utime.tv_sec  - baselineUsage.ru_utime.tv_sec)  * 1_000_000.0
                + Double(finalUsage.ru_utime.tv_usec - baselineUsage.ru_utime.tv_usec)
let totalSysUs  = Double(finalUsage.ru_stime.tv_sec  - baselineUsage.ru_stime.tv_sec)  * 1_000_000.0
                + Double(finalUsage.ru_stime.tv_usec - baselineUsage.ru_stime.tv_usec)

let totalWallMs = Double(FRAMES) * 83.0  // nominal measurement window in ms
let cpuFraction = (totalUserUs + totalSysUs) / (totalWallMs * 1000.0)

// Terminal geometry for context.
let cols = termView.terminal.cols
let rows = termView.terminal.rows

print(String(format: """
MODE=%@ FRAMES=%d DRAWS=%d COLS=%d ROWS=%d
P50_FRAME_MS=%.1f P95_FRAME_MS=%.1f
P50_CPU_USER_US=%.0f P50_CPU_SYS_US=%.0f P50_CPU_TOTAL_US=%.0f
AVG_CPU_USER_US=%.0f AVG_CPU_SYS_US=%.0f
TOTAL_CPU_USER_US=%.0f TOTAL_CPU_SYS_US=%.0f
NOMINAL_WALL_MS=%.0f CPU_FRACTION=%.4f
NOTE=offscreen_alpha0_windowserver_compositor_cost_not_included
""",
    mode, FRAMES, draws, cols, rows,
    p50frame, p95frame,
    p50userCPU, p50sysCPU, p50total,
    avgUserCPU, avgSysCPU,
    totalUserUs, totalSysUs,
    totalWallMs, cpuFraction))
