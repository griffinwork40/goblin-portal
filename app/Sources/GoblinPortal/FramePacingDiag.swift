//
//  FramePacingDiag.swift
//  The GOBLIN_PORTAL_DIAG frame-pacing log: is the terminal painting in step with the display?
//
//  Its own file because it is one whole concern with no other home: it is not about a pane
//  (it aggregates every terminal view in the process), not about config, and not about the
//  renderer choice. It exists because patch 0010 (`MacDisplayLinkPacer.swift` in the vendored
//  SwiftTerm) moved redraws from a free-running 16.67ms `asyncAfter` onto `CADisplayLink`, and
//  "the animation looks even now" is a claim that should be checkable on the user's own
//  machine, on the user's own workload (an agent-afk ink reveal through tmux), rather than
//  only in `check-display-link.sh`'s synthetic producer.
//
//  WHAT IT PRINTS. Once a second while anything paints, one stderr line per view:
//
//    [diag] frames: view=0x… n=60 int_p50=16.7 int_p95=17.9 int_max=25.0 resid_p95=0.4 \
//                   period=8.33 paced=true
//
//  `int_*` are paint-to-paint intervals in ms; `n` is paints in that second. `resid_p95` is
//  the 95th percentile distance of an interval from the nearest whole multiple of the
//  display's refresh period (`period`, read from the screen the window is on NOW).
//
//  HOW TO READ IT, from measurements on this machine (check-display-link.sh, 2026-09-27):
//  for a producer writing every ~16ms, display-link pacing shows n≈60 and int_p50≈16.7;
//  upstream's timer (`SWIFTTERM_DISPLAY_LINK=0`) shows n≈32 and int_p50≈32 — it drops every
//  other frame because its one-shot 16.67ms timer is still pending when the next update
//  arrives. That is the primary signal. `resid_p95` separates the paths cleanly on a 144Hz
//  display (≈1ms vs ≈3.4ms) but only weakly at 120Hz, where the timer's ~32ms intervals
//  happen to sit near 4 × 8.33ms; the gate measures phase against a reference link instead.
//  Nothing is printed while idle, so a quiet terminal stays quiet.
//
//  COST WHEN OFF: nothing. The observer is only installed under GOBLIN_PORTAL_DIAG; otherwise
//  SwiftTerm's `frameTimingObserver` stays nil and each paint pays one nil check.
//

import AppKit
import QuartzCore
import SwiftTerm

@MainActor
enum FramePacingDiag {
    private static var samples: [ObjectIdentifier: [CFTimeInterval]] = [:]
    private static var periods: [ObjectIdentifier: Double] = [:]
    private static var lastFlush: CFTimeInterval = 0

    /// Installs the observer when GOBLIN_PORTAL_DIAG is set. Idempotent.
    static func installIfRequested() {
        guard ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil else { return }
        // The observer is a plain closure typed without an actor, but SwiftTerm only ever
        // calls it from updateDisplay(), which runs on the main thread (a display-link tick,
        // or upstream's main-queue asyncAfter). assumeIsolated makes that contract explicit.
        TerminalView.frameTimingObserver = { view in
            MainActor.assumeIsolated { record(view) }
        }
        FileHandle.standardError.write(Data(
            "[diag] frames: pacing=\(TerminalView.displayLinkPacingEnabled ? "display-link" : "timer (SWIFTTERM_DISPLAY_LINK=0)")\n".utf8))
    }

    private static func record(_ view: TerminalView) {
        let now = CACurrentMediaTime()
        let key = ObjectIdentifier(view)
        samples[key, default: []].append(now)
        // The refresh period of the screen the view is on right now: it moves with the
        // window, which is the property patch 0010 depends on.
        if let fps = view.window?.screen?.maximumFramesPerSecond, fps > 0 {
            periods[key] = 1000.0 / Double(fps)
        }
        if now - lastFlush >= 1.0 {
            lastFlush = now
            flush()
        }
    }

    private static func flush() {
        for (key, times) in samples where times.count >= 3 {
            let ms = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
            let sorted = ms.sorted()
            let pct = { (p: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
            let period = periods[key] ?? 1000.0 / 60
            let resid = ms.map { abs($0 - ($0 / period).rounded() * period) }.sorted()
            let r95 = resid[min(resid.count - 1, Int(Double(resid.count - 1) * 0.95))]
            let f = { (x: Double) in String(format: "%.2f", x) }
            let line = "[diag] frames: view=\(key.hashValue & 0xFFFF) n=\(times.count) "
                + "int_p50=\(f(pct(0.5))) int_p95=\(f(pct(0.95))) int_max=\(f(sorted.last ?? 0)) "
                + "resid_p95=\(f(r95)) period=\(f(period)) "
                + "paced=\(TerminalView.displayLinkPacingEnabled)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        samples.removeAll(keepingCapacity: true)
    }
}
