// measure-metal-idle-encode-harness.swift
//
// Measurement harness for measure-metal-idle-encode.sh (issue #143 follow-up).
//
// Linked against vendored SwiftTerm.o via vendored-module.sh (same pattern as
// check-metal-throughput-harness.swift). Compiled and run by the shell script;
// not a gate — exits 0 always on success, 2 on environmental failure.
//
// MEASUREMENT BASIS: single basis — getrusage(RUSAGE_SELF) per draw(in:) call,
// bracketed via a TimingProxy MTKViewDelegate. Draws driven ONLY by the display-
// link path: feed() marks a row dirty → display link fires → draw(in:) is called.
// No explicit mtkView.draw() calls. This eliminates the double-draw artifact
// from the #146 harness (which called both feed() and mtkView.draw()).
//
// PANE SIZE: 46 rows × 137 cols — the exact size from issue #143.
//
// WINDOW: on-screen, alphaValue=0, ignoresMouseEvents=true, at primary display
// origin. WindowServer composites it; display-link ticks at the display refresh
// rate. Technique from check-display-link.sh.
//
// OUTPUT (stdout, KEY=value lines):
//   READY                      — printed after warm-up; shell starts sampling ps
//   DRAWS=N                    — total draw() calls recorded
//   COLS=N ROWS=N              — actual terminal geometry
//   P50_CPU_USER_US=N          — median per-frame user CPU (µs)
//   P50_CPU_SYS_US=N           — median per-frame sys CPU (µs)
//   P50_CPU_TOTAL_US=N         — median per-frame total CPU (µs)
//   AVG_CPU_USER_US=N
//   AVG_CPU_SYS_US=N
//   TOTAL_CPU_USER_US=N        — getrusage total over measurement window
//   TOTAL_CPU_SYS_US=N
//   NOMINAL_WALL_MS=N          — expected wall time (frames × 83ms)
//   CPU_FRACTION=N             — (total_user+sys) / nominal_wall, as decimal
//
// MODE (argv[1]): "spinner" or "idle" (default: spinner)
//
// Exit 0: success. Exit 2: environmental (no Metal, no screen, build mismatch).

import AppKit
import Darwin
import Metal
import MetalKit
import SwiftTerm

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "spinner"

// --- App setup -----------------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no focus steal

// --- On-screen invisible window ------------------------------------------------
guard let screen = NSScreen.main else {
    fputs("ENV=no_screen\n", stderr); exit(2)
}

// 46 rows × 137 cols. Approximate cell size: 7×17pt at default font.
// Use 959×782 pt (137×7=959, 46×17=782). Must be on the real screen for the
// display link to tick — at x=-20000 the link fires but at 0 Hz (measured).
let ptW: CGFloat = 959
let ptH: CGFloat = 782
let winRect = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                     width: ptW, height: ptH)

let win = NSWindow(contentRect: winRect,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
win.alphaValue = 0               // invisible to the user
win.ignoresMouseEvents = true    // click-through
win.orderFrontRegardless()       // on-screen so WindowServer composites it

// --- Terminal view -------------------------------------------------------------
let container = NSView(frame: NSRect(origin: .zero, size: winRect.size))
win.contentView = container

class SilentDelegate: NSObject, LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
let termDelegate = SilentDelegate()

let termView = LocalProcessTerminalView(frame: container.bounds)
termView.autoresizingMask = [.width, .height]
container.addSubview(termView)
objc_setAssociatedObject(termView, Unmanaged.passUnretained(termView).toOpaque(),
                         termDelegate, .OBJC_ASSOCIATION_RETAIN)
termView.processDelegate = termDelegate

func pump(_ t: Double) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

// --- Settle and switch to Metal ------------------------------------------------
pump(0.3)

do {
    try termView.setUseMetal(true)
} catch {
    fputs("ENV=metal_unavailable error=\(error)\n", stderr); exit(2)
}
pump(0.3)

guard termView.isUsingMetalRenderer else {
    fputs("ENV=metal_not_active\n", stderr); exit(2)
}

// --- Find MTKView --------------------------------------------------------------
func findMTKView(in parent: NSView) -> MTKView? {
    for sub in parent.subviews {
        if let v = sub as? MTKView { return v }
        if let found = findMTKView(in: sub) { return found }
    }
    return nil
}
guard let mtkView = findMTKView(in: termView) else {
    fputs("ENV=no_mtkview\n", stderr); exit(2)
}

// MTKView must be in display-link mode (not timer mode) so that feed() → dirty
// → setNeedsDisplay → display link fires → draw(in:) is called once per frame.
// Patch 0010 sets isPaused=true / enableSetNeedsDisplay=true in MacTerminalView.
// Verify that is in effect:
guard mtkView.isPaused && mtkView.enableSetNeedsDisplay else {
    fputs("ENV=mtkview_not_in_displaylink_mode isPaused=\(mtkView.isPaused) enableSetNeedsDisplay=\(mtkView.enableSetNeedsDisplay)\n", stderr)
    exit(2)
}

// --- Steady cursor (no blink timer firing extra draws) ------------------------
termView.feed(text: "\u{1b}[2 q\u{1b}[2J\u{1b}[H")
pump(0.2)

// --- Fill atlas with warm content ---------------------------------------------
var payload = ""
let colours = [31, 32, 33, 34, 35, 36, 37]
for row in 0..<50 {
    let c = colours[row % colours.count]
    payload += "\u{1b}[\(c)m\u{1b}[1mRow \(String(format: "%02d", row)): "
    payload += "Lorem ipsum dolor sit amet consectetur adipiscing elit sed eiusmod tempor incididunt"
    payload += "\u{1b}[0m\r\n"
}
termView.feed(text: payload)
pump(0.5)

// --- Instrument: proxy MTKView delegate to bracket each draw with getrusage ---
var cpuUserPerFrame:  [Double] = []
var cpuSysPerFrame:   [Double] = []
var cpuTotalPerFrame: [Double] = []
var drawTimestamps:   [Double] = []

final class TimingProxy: NSObject, MTKViewDelegate {
    let inner: MTKViewDelegate
    init(_ inner: MTKViewDelegate) { self.inner = inner }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        inner.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)

        inner.draw(in: view)

        var after = rusage()
        getrusage(RUSAGE_SELF, &after)

        drawTimestamps.append(CACurrentMediaTime())

        let userUs = Double(after.ru_utime.tv_sec  - before.ru_utime.tv_sec)  * 1_000_000
                   + Double(after.ru_utime.tv_usec - before.ru_utime.tv_usec)
        let sysUs  = Double(after.ru_stime.tv_sec  - before.ru_stime.tv_sec)  * 1_000_000
                   + Double(after.ru_stime.tv_usec - before.ru_stime.tv_usec)
        cpuUserPerFrame.append(userUs)
        cpuSysPerFrame.append(sysUs)
        cpuTotalPerFrame.append(userUs + sysUs)
    }
}

guard let originalDelegate = mtkView.delegate else {
    fputs("ENV=no_delegate\n", stderr); exit(2)
}
let proxy = TimingProxy(originalDelegate)
mtkView.delegate = proxy

// --- Warm-up: 20 frames before measurement ------------------------------------
// Drive via feed() so display link fires; use a real 83ms RunLoop pump.
let SPINNER_CHARS = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
var spinIdx = 0

for _ in 0..<20 {
    pump(0.083)
    if mode == "spinner" {
        let s = SPINNER_CHARS[spinIdx % SPINNER_CHARS.count]; spinIdx += 1
        termView.feed(text: "\u{1b}[6;1H\(s)  ")
    }
}
// Discard warm-up measurements
cpuUserPerFrame.removeAll()
cpuSysPerFrame.removeAll()
cpuTotalPerFrame.removeAll()
drawTimestamps.removeAll()

// Signal to shell that we're in steady state — shell starts ps sampling now
print("READY")
fflush(stdout)

// --- Measurement: 360 frames at 12 Hz (30 seconds) ---------------------------
let FRAMES = 360
var baseRusage = rusage()
getrusage(RUSAGE_SELF, &baseRusage)

for i in 0..<FRAMES {
    pump(0.083)   // 83ms ≈ 12 Hz
    if mode == "spinner" {
        let s = SPINNER_CHARS[spinIdx % SPINNER_CHARS.count]; spinIdx += 1
        termView.feed(text: "\u{1b}[6;1H\(s) frame \(i)  ")
    }
    // idle mode: no feed() — display link does not fire → no draw.
    // Force one draw via setNeedsDisplay so we still measure the present floor.
    if mode == "idle" {
        mtkView.setNeedsDisplay(mtkView.bounds)
    }
}

var finalRusage = rusage()
getrusage(RUSAGE_SELF, &finalRusage)

// --- Stats --------------------------------------------------------------------
func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
func avg(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count) }

let totalUserUs = Double(finalRusage.ru_utime.tv_sec  - baseRusage.ru_utime.tv_sec)  * 1_000_000
                + Double(finalRusage.ru_utime.tv_usec - baseRusage.ru_utime.tv_usec)
let totalSysUs  = Double(finalRusage.ru_stime.tv_sec  - baseRusage.ru_stime.tv_sec)  * 1_000_000
                + Double(finalRusage.ru_stime.tv_usec - baseRusage.ru_stime.tv_usec)
let nominalWallMs = Double(FRAMES) * 83.0
let cpuFraction = (totalUserUs + totalSysUs) / (nominalWallMs * 1000.0)

let draws = drawTimestamps.count

print(String(format: """
DRAWS=%d COLS=%d ROWS=%d
P50_CPU_USER_US=%.0f P50_CPU_SYS_US=%.0f P50_CPU_TOTAL_US=%.0f
AVG_CPU_USER_US=%.0f AVG_CPU_SYS_US=%.0f
TOTAL_CPU_USER_US=%.0f TOTAL_CPU_SYS_US=%.0f
NOMINAL_WALL_MS=%.0f CPU_FRACTION=%.4f
""",
    draws, termView.terminal.cols, termView.terminal.rows,
    pct(cpuUserPerFrame, 0.5), pct(cpuSysPerFrame, 0.5),
    pct(cpuTotalPerFrame, 0.5),
    avg(cpuUserPerFrame), avg(cpuSysPerFrame),
    totalUserUs, totalSysUs,
    nominalWallMs, cpuFraction))
