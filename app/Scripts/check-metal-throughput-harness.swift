//
//  check-metal-throughput-harness.swift
//  Measurement harness for check-metal-throughput.sh.
//
//  Extracted from the parent script when it crossed the 350-LOC ceiling (N6 load-guard
//  addition). Same split pattern as check-git-status-harness.swift — the harness is pure
//  Swift and carries its own concern (frame measurement), while the shell half owns
//  environment checking, load guarding, and pass/fail policy.
//
//  Outputs (to stdout):
//    STAT coretext median=<ms> p95=<ms> mean=<ms> mean_excl_first10=<ms>
//    STAT metal    median=<ms> p95=<ms> mean=<ms> mean_excl_first10=<ms>
//    RESULT ct_median_ms=<ms> mt_median_ms=<ms> ratio=<r> frames=<n>
//  or on environmental failure:
//    RESULT env_fail <reason>
//
//  Exit: always 0. The shell half reads the RESULT line and owns the verdict.

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
