// Harness for check-display-link.sh — copied to main.swift and linked against the
// vendored SwiftTerm.o. Not part of the app target (Scripts/ is outside Sources/).
//
// Contract: `harness <mode> <renderer> <producerMs> <seconds>`
//   mode      stream | idle | sync | reparent | screenmove
//   renderer  coretext | metal
// Prints one `KEY=value ...` line per result. The shell half owns every verdict; this
// file only measures. Exit 0 = measured, 2 = environmental (no display link ticks, no
// Metal device, or no window server) — never an assertion.
//
// What it measures, and why each number exists:
//   * a REAL draw — `draw(_:)` on a TerminalView subclass (Core Text) or the MTKView's
//     delegate `draw(in:)` via a forwarding proxy (Metal). Not the invalidation: the point
//     where pixels are produced is what the compositor sees.
//   * a REFERENCE display link on a sibling view, whose `timestamp`s are the vsyncs the
//     draws are compared against. `phase` = time since the most recent vsync, and the
//     spread is circular (wrapped around the circular mean) so a cluster straddling the
//     period boundary is not scored as maximally spread.
//   * `resid` = each draw interval's distance to the nearest multiple of the refresh
//     period. Anchor-free: vsync-locked draws give ~0, free-running ones are uniform on
//     [0, P/2]. The in-app GOBLIN_PORTAL_DIAG log uses the same metric.
import AppKit
import MetalKit
import QuartzCore
import SwiftTerm

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "stream"
let renderer = args.count > 2 ? args[2] : "coretext"
let producerMs = args.count > 3 ? Double(args[3]) ?? 16 : 16
let seconds = args.count > 4 ? Double(args[4]) ?? 3 : 3

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // never activates, never steals focus

var draws: [CFTimeInterval] = []
var vsyncs: [CFTimeInterval] = []
var period: CFTimeInterval = 0
var recording = false

final class ProbeView: TerminalView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if recording && renderer == "coretext" { draws.append(CACurrentMediaTime()) }
    }
}

final class MetalProxy: NSObject, MTKViewDelegate {
    let inner: MTKViewDelegate
    init(_ inner: MTKViewDelegate) { self.inner = inner }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        inner.mtkView(view, drawableSizeWillChange: size)
    }
    func draw(in view: MTKView) {
        if recording { draws.append(CACurrentMediaTime()) }
        inner.draw(in: view)
    }
}

final class Ref: NSObject {
    @objc func tick(_ l: CADisplayLink) {
        vsyncs.append(l.timestamp)
        period = l.targetTimestamp - l.timestamp
    }
}

// On a real screen (a display link does not tick for a window on no screen — measured:
// 0 ticks at x=-20000) but fully transparent and click-through, so nothing is visible.
// DL_SCREEN=<index> picks a display (e.g. a 60Hz external next to a 120Hz panel).
let screenIndex = Int(ProcessInfo.processInfo.environment["DL_SCREEN"] ?? "") ?? -1
let screen = (NSScreen.screens.indices.contains(screenIndex) ? NSScreen.screens[screenIndex]
              : NSScreen.main)?.frame ?? .zero
let rect = NSRect(x: screen.minX, y: screen.minY, width: 640, height: 400)
let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
win.alphaValue = 0
win.ignoresMouseEvents = true
let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
win.contentView = container
let view = ProbeView(frame: container.bounds)
container.addSubview(view)
let refView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
container.addSubview(refView)
win.orderFrontRegardless()

func pump(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

let ref = Ref()
let refLink = refView.displayLink(target: ref, selector: #selector(Ref.tick(_:)))
refLink.add(to: .main, forMode: .common)
pump(0.3)
if vsyncs.isEmpty || period <= 0 {
    print("ENV=no-display-link-ticks")
    exit(2)
}

var metalProxy: MetalProxy?
if renderer == "metal" {
    do { try view.setUseMetal(true) } catch { print("ENV=metal-unavailable \(error)"); exit(2) }
    pump(0.2)
    guard let mtk = view.subviews.compactMap({ $0 as? MTKView }).first, let d = mtk.delegate else {
        print("ENV=no-mtkview")
        exit(2)
    }
    metalProxy = MetalProxy(d)
    mtk.delegate = metalProxy
}
// Steady block (DECSCUSR 2), Goblin Portal's default since a68fd1eb: a blinking cursor
// adds renderer-driven draws that no pacer schedules, which would pollute every number.
view.feed(text: "\u{1b}[2 q\u{1b}[2J\u{1b}[H")
pump(0.3)

// --- statistics ---------------------------------------------------------------------
func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
func phaseOf(_ t: CFTimeInterval) -> Double {
    // Most recent vsync at or before t; extrapolate with the period if t is past the list.
    guard let last = vsyncs.last(where: { $0 <= t }) else { return .nan }
    return (t - last).truncatingRemainder(dividingBy: period)
}
func report(_ label: String, producedFrames: Int) {
    let ms = 1000.0
    let intervals = zip(draws.dropFirst(), draws).map { ($0 - $1) * ms }
    let p = period * ms
    let resid = intervals.map { x in abs(x - (x / p).rounded() * p) }
    let phases = draws.map(phaseOf).filter { !$0.isNaN }.map { $0 * ms }
    // Circular mean, then each phase's wrapped deviation from it.
    let ang = phases.map { $0 / p * 2 * Double.pi }
    let cm = atan2(ang.map(sin).reduce(0, +), ang.map(cos).reduce(0, +))
    let dev = ang.map { a -> Double in
        var d = a - cm
        while d > Double.pi { d -= 2 * Double.pi }
        while d < -Double.pi { d += 2 * Double.pi }
        return abs(d) / (2 * Double.pi) * p
    }
    let f = { (x: Double) in String(format: "%.2f", x) }
    print("\(label) draws=\(draws.count) produced=\(producedFrames) period=\(f(p))",
          "int_p50=\(f(pct(intervals, 0.5))) int_p95=\(f(pct(intervals, 0.95)))",
          "int_max=\(f(intervals.max() ?? .nan)) resid_p50=\(f(pct(resid, 0.5)))",
          "resid_p95=\(f(pct(resid, 0.95))) phase_dev_p50=\(f(pct(dev, 0.5))) phase_dev_p95=\(f(pct(dev, 0.95)))",
          "phase_dev_max=\(f(dev.max() ?? .nan)) link_active=\(view.isDisplayLinkActive)")
}

// A small update: one status row redrawn with a changing counter, the shape of an ink
// text-reveal frame (cursor to a fixed row, rewrite a few cells).
var frame = 0
func produce() {
    frame += 1
    view.feed(text: "\u{1b}[5;1Hframe \(frame) \(String(repeating: "#", count: frame % 40))\u{1b}[K")
}
func stream(for duration: Double) -> Int {
    let start = frame
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(Int(producerMs)), leeway: .nanoseconds(0))
    timer.setEventHandler { produce() }
    timer.resume()
    pump(duration)
    timer.cancel()
    return frame - start
}

switch mode {
case "stream":
    recording = true
    let n = stream(for: seconds)
    recording = false
    report("STREAM", producedFrames: n)
case "idle":
    _ = stream(for: 0.5)
    pump(0.3)  // > idleTicksBeforePause at any refresh rate >= 30Hz
    recording = true
    draws = []
    pump(0.5)
    recording = false
    print("IDLE draws=\(draws.count) link_active=\(view.isDisplayLinkActive)")
case "sync":
    view.feed(text: "\u{1b}[?2026h")
    pump(0.05)
    recording = true
    draws = []
    _ = stream(for: 0.3)            // every update lands inside the sync block
    let heldDraws = draws.count
    draws = []
    let end = CACurrentMediaTime()
    view.feed(text: "\u{1b}[?2026l")
    pump(0.2)
    recording = false
    let first = draws.first.map { String(format: "%.2f", ($0 - end) * 1000) } ?? "none"
    let ph = draws.first.map { String(format: "%.2f", phaseOf($0) * 1000) } ?? "none"
    print("SYNC held_draws=\(heldDraws) release_draws=\(draws.count) first_after_ms=\(first)",
          "first_phase_ms=\(ph) period=\(String(format: "%.2f", period * 1000))")
case "screenmove":
    // The link must follow the window to a display with a DIFFERENT refresh rate. Stream
    // on screen 0, move the window to screen 1, then score only post-move draws against
    // a fresh reference link on the new screen. A pacer stuck on the old display's clock
    // would land at a drifting phase here.
    guard NSScreen.screens.count > 1 else { print("SCREENMOVE skip=one-display"); exit(0) }
    _ = stream(for: 0.5)
    let target = NSScreen.screens[1].frame
    win.setFrameOrigin(NSPoint(x: target.minX, y: target.minY))
    refLink.invalidate()
    let ref2View = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    container.addSubview(ref2View)
    vsyncs = []
    let ref2 = ref2View.displayLink(target: ref, selector: #selector(Ref.tick(_:)))
    ref2.add(to: .main, forMode: .common)
    _ = stream(for: 0.3)           // settle on the new display
    recording = true
    draws = []
    let n = stream(for: seconds)
    recording = false
    report("SCREENMOVE", producedFrames: n)
    ref2.invalidate()
case "reparent":
    // A tab dragged out into its own window moves the view to a new NSWindow. A pending
    // frame must follow it: the pacer drops its old link on viewDidMoveToWindow and binds a
    // fresh one to the new window's screen. If it stranded the frame, only the 100ms
    // watchdog would paint it, so latency is the discriminating number, not "did it draw".
    let win2 = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    win2.alphaValue = 0
    win2.ignoresMouseEvents = true
    win2.orderFrontRegardless()
    pump(0.2)
    recording = true
    draws = []
    produce()                      // queues a frame on the OLD window's link
    let t0 = CACurrentMediaTime()
    view.removeFromSuperview()
    win2.contentView = view        // ...and the view leaves before any tick runs
    // viewDidMoveToWindow has run synchronously; under Metal it REBUILT the MTKView
    // (rebindMetalRendererToWindow), so re-wrap the new delegate before any tick.
    if renderer == "metal", let mtk = view.subviews.compactMap({ $0 as? MTKView }).first,
       let d = mtk.delegate {
        metalProxy = MetalProxy(d)
        mtk.delegate = metalProxy
    }
    pump(0.3)
    recording = false
    let first = draws.first.map { String(format: "%.2f", ($0 - t0) * 1000) } ?? "none"
    print("REPARENT draws=\(draws.count) first_after_ms=\(first)",
          "period=\(String(format: "%.2f", period * 1000))")
default:
    print("ENV=unknown-mode \(mode)")
    exit(2)
}
refLink.invalidate()
exit(0)
