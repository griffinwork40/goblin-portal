// Measures retained GPU/physical memory and release/re-show latency on real TerminalPanes.
// Measurement tool, not a gate. Always exits 0; ENV/ERROR means no usable result.
// No shell, activation, key window, or production-source changes. See shell driver.
import AppKit
import Darwin
import Metal
import MetalKit
@preconcurrency import QuartzCore
@testable import SwiftTerm
@testable import GoblinPortal

func fail(_ why: String) -> Never { print("ERROR=\(why)"); exit(0) }
func pump(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    if rc != KERN_SUCCESS { fail("task_info=\(rc)") }
    return info.phys_footprint
}
func load() -> Double {
    var x = [Double](repeating: 0, count: 3)
    return getloadavg(&x, 3) > 0 ? x[0] / Double(ProcessInfo.processInfo.processorCount) : .infinity
}
nonisolated final class Counter: @unchecked Sendable {
    let lock = NSLock(); var value = 0
    func tick() { lock.lock(); value += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
// Install ONLY in timing processes. Observe the actual layer's drawable, not a second render.
// addPresentedHandler observes presentation, unlike onFramePresented (GPU completion,
// MetalTerminalRenderer.swift:1461-1466). Locks protect these callbacks from Metal threads.
nonisolated final class Presentation: @unchecked Sendable {
    let lock = NSLock()
    var armed = false, generation = 0
    var acquisitions = 0, callbacks = 0, zeroTimes = 0
    var firstTime = 0.0
    var completionTime = 0.0
    var drawable: CAMetalDrawable?
    var excluded: CAMetalLayer?
    var trace: [String] = []
    func diagnostics() -> String { lock.lock(); defer { lock.unlock() }; return trace.joined(separator: ";") }
    func arm() { lock.lock(); generation += 1; firstTime = 0; completionTime = 0; drawable = nil; zeroTimes = 0; trace = []; armed = true; lock.unlock() }
    // Do not pin the preceding sample's drawable through the hidden hold.
    func clear() { lock.lock(); generation += 1; drawable = nil; armed = false; lock.unlock() }
    // GPU completion is a diagnostic floor only, never a presentation substitute.
    // MetalTerminalRenderer.swift:1461-1466 calls this before compositor presentation.
    func completed() { lock.lock(); if armed && completionTime == 0 { completionTime = CACurrentMediaTime() }; lock.unlock() }
    func observe(_ layer: CAMetalLayer, _ d: CAMetalDrawable) {
        lock.lock(); acquisitions += 1
        let active = armed && layer !== excluded
        if active { trace.append("acquire:\(acquisitions):\(CACurrentMediaTime())") }
        let g = generation; lock.unlock()
        if !active { return }
        d.addPresentedHandler { [self] drawn in
            lock.lock(); defer { lock.unlock() }; callbacks += 1
            if generation == g {
                trace.append("callback:\(drawn.presentedTime)")
                if drawn.presentedTime == 0 { zeroTimes += 1 }
            }
            if armed && generation == g && firstTime == 0 && drawn.presentedTime > 0 {
                firstTime = drawn.presentedTime; drawable = d; armed = false
            }
        }
    }
    func result() -> (Double, CAMetalDrawable?) {
        lock.lock(); defer { lock.unlock() }; return (firstTime, drawable)
    }
}
nonisolated let probe = Presentation()
extension CAMetalLayer {
    @objc nonisolated func gpuReleaseNextDrawable() -> CAMetalDrawable? {
        framebufferOnly = false
        let d = gpuReleaseNextDrawable() // original after exchange
        if let d { probe.observe(self, d) }
        return d
    }
}
func hookPresentation() {
    guard let a = class_getInstanceMethod(CAMetalLayer.self, #selector(CAMetalLayer.nextDrawable)),
          let b = class_getInstanceMethod(CAMetalLayer.self, #selector(CAMetalLayer.gpuReleaseNextDrawable))
    else { fail("nextDrawable-hook") }
    method_exchangeImplementations(a, b)
}
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "memory"
let n = args.count > 2 ? Int(args[2]) ?? 0 : 0
let rep = args.count > 3 ? Int(args[3]) ?? 1 : 1
let core = args.count > 4 && args[4] == "coretext"
let releaseArm = args.count > 4 ? args[4] : "shrink"
let presentation = args.count > 5 ? args[5] : "invisible"
let hold = args.count > 6 ? Double(args[6]) ?? 0 : 0
if mode == "timing" && load() > 0.70 { print("SKIP=load-per-CPU load=\(load())"); exit(0) }
print("CONFIG presentation=\(presentation) hold=\(hold) samples=\(n) arm=\(releaseArm) load=\(load())")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen: NSScreen = {
    let preferred = ProcessInfo.processInfo.environment["GPU_RELEASE_SCREEN"]
    let s = preferred == "builtin" ? NSScreen.screens.first(where: {
        guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }) : NSScreen.screens.first
    guard let s else { fail("no-screen") }; return s
}()
print("DISPLAY name=\(screen.localizedName) frame=\(screen.frame) backingScale=\(screen.backingScaleFactor) displayID=\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown")")
let device: MTLDevice = { guard let d = MTLCreateSystemDefaultDevice() else { fail("no-metal") }; return d }()
let win = NSWindow(contentRect: NSRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10,
                                     width: 1100, height: 800),
                   styleMask: [.borderless], backing: .buffered, defer: false)
win.alphaValue = presentation == "visible" ? 1 : 0
win.ignoresMouseEvents = true; win.colorSpace = .sRGB
// Attempt 1 (2026-11-14, visible-hold0-attempt1-incomplete) lost presentation at sample 30
// while the user typed in another app: at normal level that app's window can cover this
// one, and a fully covered layer gets presentedTime 0. Float above normal windows.
// Attempts 2-3 then showed the real mechanism on this machine: Stage Manager is on, and
// switching apps sweeps a normal window off stage. canJoinAllApplications is the Stage
// Manager analogue of canJoinAllSpaces.
if presentation == "visible" { win.level = .floating; win.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .fullScreenAuxiliary] }
// A second, independent visibility signal (window server list), logged beside occlusionState.
func cgOnScreen() -> Bool {
    let l = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    return l.contains { ($0[kCGWindowNumber as String] as? Int) == win.windowNumber }
}
let container = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800))
win.contentView = container; win.orderFrontRegardless()
let counter = Counter()
TerminalView.onFramePresented = { counter.tick(); probe.completed() }
func payload(_ token: Int) -> String {
    var s = "\u{1b}[?25l\u{1b}[2J"
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 !@#$%^&*()[]{}<>?/|;:,.+-=_")
    for row in 0..<46 {
        let text = String((0..<137).map { alphabet[($0 + row + token) % alphabet.count] })
        s += "\u{1b}[\(row + 1);1H\u{1b}[\(31 + row % 7)m" + (row % 3 == 0 ? "\u{1b}[1m" : "\u{1b}[22m") + text
    }
    return s + "\u{1b}[0m"
}
func makePane(_ token: Int, coreText: Bool) -> TerminalPane {
    var cfg = AppConfig.defaults()
    cfg.renderer = coreText ? .coreText : .metal
    cfg.font = AppConfig.preferredMonoFont(family: nil, size: 14).font
    cfg.smoothScrolling = false
    let p = TerminalPane(config: cfg, frame: container.bounds,
                         workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    // Alpha-zero windows are intentionally occluded; permit rendering while attached.
    // MacTerminalView.swift:282-289 provides this benchmark-specific override.
    p.view.suspendsRenderingWhenNotVisible = false
    container.addSubview(p.clipView); pump(0.05)
    p.apply(config: cfg); p.setFontSize(14, persist: false)
    p.view.resize(cols: 137, rows: 46)
    p.clipView.frame = NSRect(origin: .zero, size: p.view.getOptimalFrameSize().size)
    p.view.frame = p.clipView.bounds
    pump(0.1)
    p.view.resize(cols: 137, rows: 46)
    if p.view.isUsingMetalRenderer == coreText { fail("wrong-renderer") }
    if !coreText && !p.view.usesMetalLayerSurface { fail("expected-default-layer-surface") }
    let before = counter.read()
    p.view.feed(text: payload(token)); pump(0.25)
    if !coreText && counter.read() <= before { fail("no-warm-frame") }
    if p.view.getTerminal().cols != 137 || p.view.getTerminal().rows != 46 { fail("wrong-grid") }
    print("WARM token=\(token) metal=\(p.view.isUsingMetalRenderer) cols=137 rows=46 frames=\(counter.read() - before)")
    return p
}
func sample(_ arm: String) {
    // Drain temporary AppKit/CA objects before sampling (same basis as the
    // autoreleasepool around pane construction below); report within-sample range too.
    for _ in 0..<4 { autoreleasepool { pump(0.5) } }
    var phys: [UInt64] = [], gpu: [Int] = []
    for _ in 0..<5 {
        autoreleasepool { pump(0.2) }
        phys.append(footprint()); gpu.append(device.currentAllocatedSize)
    }
    print("MEM rep=\(rep) n=\(n) arm=\(arm) phys=\(phys.sorted()[2]) gpu=\(gpu.sorted()[2]) physMin=\(phys.min()!) physMax=\(phys.max()!) gpuMin=\(gpu.min()!) gpuMax=\(gpu.max()!) load=\(load())")
    fflush(stdout)
}
// A GPU blit reads the presented texture without asking for another drawable.
func pixels(_ drawable: CAMetalDrawable) -> Data {
    let t = drawable.texture, stride = ((t.width * 4 + 255) / 256) * 256
    guard let b = device.makeBuffer(length: stride * t.height, options: .storageModeShared),
          let q = device.makeCommandQueue(), let cb = q.makeCommandBuffer(),
          let blit = cb.makeBlitCommandEncoder() else { fail("capture-setup") }
    blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
              sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: b,
              destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * t.height)
    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    if cb.status != .completed { fail("capture-blit") }
    // Drop alignment padding from comparison.
    var data = Data()
    for r in 0..<t.height { data.append(b.contents().advanced(by: r * stride).assumingMemoryBound(to: UInt8.self), count: t.width * 4) }
    return data
}
func awaitFirst(_ start: Double) -> (Double, Data) {
    let deadline = CACurrentMediaTime() + 3
    while probe.result().0 == 0 && CACurrentMediaTime() < deadline { pump(0.001) }
    let (time, d) = probe.result()
    guard time > start, let d else { fail("no-presented-drawable windowVisible=\(win.occlusionState.contains(.visible)) time=\(time) acquired=\(probe.acquisitions) callbacks=\(probe.callbacks) completed=\(counter.read()) completionFloorMS=\((probe.completionTime - start) * 1000)") }
    return ((time - start) * 1000, pixels(d))
}
if mode == "breakdown" {
    breakdown()
} else if mode == "memory" {
    let visible = autoreleasepool { makePane(0, coreText: core) }
    var hidden: [TerminalPane] = []
    for i in 0..<n {
        autoreleasepool {
            let p = makePane(i + 1, coreText: core)
            p.clipView.removeFromSuperview()
            if p.view.window != nil { fail("hidden-still-in-window") }
            hidden.append(p)
        }
    }
    // Pilot raw run 165814 showed late 4 MiB CA/allocator drops. Do not confuse
    // those with release: let them retire BEFORE the paired no-op measurement.
    for _ in 0..<30 { autoreleasepool { pump(0.5) } }
    sample(core ? "coretext" : "metal")
    // Identical elapsed time and iteration, but no release: paired drift control.
    for p in hidden { if p.view.window != nil { fail("noop-visibility") } }
    sample(core ? "coretext-noop" : "noop")
    if !core {
        for p in hidden { autoreleasepool { do { try p.view.setUseMetal(false) } catch { fail("release-\(error)") } } }
        if hidden.contains(where: { $0.view.isUsingMetalRenderer }) { fail("release-still-metal") }
        sample("released")
    }
    withExtendedLifetime((visible, hidden)) {}
} else {
    runTiming()
}
print("COMPLETE")
exit(0)
