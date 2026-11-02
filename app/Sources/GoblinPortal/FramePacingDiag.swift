//
//  FramePacingDiag.swift
//  The GOBLIN_PORTAL_DIAG frame-pacing log: is the terminal painting in step with the display?
//
//  Its own file because it is one whole concern with no other home: it is not about a pane
//  (it aggregates every terminal view in the process), not about config, and not about the
//  renderer choice. It exists because the vendored SwiftTerm's FrameDriver paces redraws on
//  CADisplayLink, and "the animation looks even now" is a claim that should be checkable on
//  the user's own machine, on the user's own workload (an agent-afk ink reveal through tmux),
//  rather than only in `check-display-link.sh`'s synthetic producer.
//
//  WHAT IT PRINTS. Once a second while anything paints, one stderr line:
//
//    [diag] frames: n=60 int_p50=16.7 int_p95=17.9 int_max=25.0 resid_p95=0.4 \
//                   period=8.33 paced=true
//
//  `int_*` are paint-to-paint intervals in ms; `n` is paints in that second. `resid_p95` is
//  the 95th percentile distance of an interval from the nearest whole multiple of the
//  display's refresh period (`period`, read from the key window's screen).
//
//  DRIVER LINE (new): every second, whether or not any frame paints:
//
//    [diag] driver: ticks=120 frames=7 idle=113 imm=0 deliveries=7
//
//  `ticks` = display link callbacks per second (should be ~120 on ProMotion).
//  `frames` = ticks where dirty was true (actual paints).
//  `idle` = ticks where dirty was false.
//  If ticks is low, the display link is being throttled by macOS (ProMotion).
//  If ticks is high but frames is low, dirty signals are not arriving.
//
//  HOW TO READ IT, from measurements on this machine (check-display-link.sh, 2026-09-27):
//  for a producer writing every ~16ms, display-link pacing shows n~60 and int_p50~16.7;
//  upstream's timer (`SWIFTTERM_DISPLAY_LINK=0`) shows n~32 and int_p50~32. Nothing is
//  printed while idle, so a quiet terminal stays quiet.
//
//  HOOK: `TerminalView.onFramePresented` — a static callback that fires from both renderers:
//  MetalTerminalRenderer.swift:1466 (render thread) and MacTerminalView.swift:1856 (main
//  thread, CoreText path). The timestamp is captured on the calling thread (accurate) and
//  dispatched to main for storage.
//
//  COST WHEN OFF: nothing. The callback is only installed under GOBLIN_PORTAL_DIAG; otherwise
//  `onFramePresented` stays nil.
//

import AppKit
import QuartzCore
import SwiftTerm

@MainActor
enum FramePacingDiag {
    private static var timestamps: [CFTimeInterval] = []
    private static var lastFlush: CFTimeInterval = 0
    private static var driverTimer: Timer?

    /// Installs the observer when GOBLIN_PORTAL_DIAG is set. Idempotent.
    static func installIfRequested() {
        guard ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil else { return }
        // onFramePresented fires on both renderers: from MetalTerminalRenderer on the
        // render thread, and from MacTerminalView.draw() on the main thread. Capture the
        // timestamp on the calling thread (accurate), then dispatch to main for storage.
        TerminalView.onFramePresented = {
            let now = CACurrentMediaTime()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { record(now) }
            }
        }
        FileHandle.standardError.write(Data(
            "[diag] frames: pacing=\(TerminalView.displayLinkPacingEnabled ? "display-link" : "timer (SWIFTTERM_DISPLAY_LINK=0)")\n".utf8))

        // 1-second timer to dump FrameDriver counters even when nothing paints.
        // This is the key diagnostic: ticks vs frames tells us whether the display
        // link itself is throttled (ProMotion) or whether dirty signals are lost.
        driverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { flushDriverCounters() }
        }
    }

    private static func record(_ now: CFTimeInterval) {
        timestamps.append(now)
        if now - lastFlush >= 1.0 {
            lastFlush = now
            flush()
        }
    }

    private static func flushDriverCounters() {
        guard let view = findTerminalView() else { return }
        let d = view.diagnostics
        // Skip if nothing happened (no ticks = driver not running yet)
        guard d.ticks > 0 else { return }
        let line = "[diag] driver: ticks=\(d.ticks) frames=\(d.frames) "
            + "idle=\(d.idleTicks) batches=\(d.batches) "
            + "bytes=\(d.bytesFed)\n"
        FileHandle.standardError.write(Data(line.utf8))
        view.resetDiagnostics()
    }

    /// Walk the key window to find a terminal view for diagnostics.
    private static func findTerminalView() -> TerminalView? {
        guard let window = NSApp.keyWindow else { return nil }
        return findTerminalViewIn(window.contentView)
    }

    private static func findTerminalViewIn(_ view: NSView?) -> TerminalView? {
        guard let view else { return nil }
        if let tv = view as? TerminalView { return tv }
        for sub in view.subviews {
            if let found = findTerminalViewIn(sub) { return found }
        }
        return nil
    }

    private static func flush() {
        guard timestamps.count >= 3 else {
            timestamps.removeAll(keepingCapacity: true)
            return
        }
        let ms = zip(timestamps.dropFirst(), timestamps).map { ($0 - $1) * 1000 }
        let sorted = ms.sorted()
        let pct = { (p: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let period: Double
        if let fps = screen?.maximumFramesPerSecond, fps > 0 {
            period = 1000.0 / Double(fps)
        } else {
            period = 1000.0 / 60
        }
        let resid = ms.map { abs($0 - ($0 / period).rounded() * period) }.sorted()
        let r95 = resid[min(resid.count - 1, Int(Double(resid.count - 1) * 0.95))]
        let f = { (x: Double) in String(format: "%.2f", x) }
        let line = "[diag] frames: n=\(timestamps.count) "
            + "int_p50=\(f(pct(0.5))) int_p95=\(f(pct(0.95))) int_max=\(f(sorted.last ?? 0)) "
            + "resid_p95=\(f(r95)) period=\(f(period)) "
            + "paced=\(TerminalView.displayLinkPacingEnabled)\n"
        FileHandle.standardError.write(Data(line.utf8))
        timestamps.removeAll(keepingCapacity: true)
    }
}
