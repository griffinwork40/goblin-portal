// Uncensored control/full-release timing on the same real TerminalPane lifecycle.
// All acquired drawables are traced; endpoint is the FIRST actually presented frame.
// Missing presentation remains an attempted, censored observation (not a fast sample).
import AppKit
import Metal
@preconcurrency import QuartzCore
@testable import SwiftTerm
@testable import GoblinPortal

func runTiming() {
    hookPresentation()
    let visible = makePane(0, coreText: false)
    probe.excluded = visible.view.metalView?.layer as? CAMetalLayer
    let p = makePane(1, coreText: false)
    func capture(_ token: Int) -> Data {
        probe.arm(); let start = CACurrentMediaTime()
        p.view.feed(text: payload(token)); return awaitFirst(start).1
    }
    let oracle = capture(2), decoy = capture(3)
    if oracle == decoy || Set(oracle).count < 10 { fail("pixel-control-vacuous") }
    if let layer = p.view.metalView?.layer as? CAMetalLayer {
        print("GEOMETRY windowScreen=\(win.screen?.localizedName ?? "nil") windowScale=\(win.backingScaleFactor) drawable=\(layer.drawableSize) grid=137x46 format=\(layer.pixelFormat.rawValue)")
    }
    let released = releaseArm != "control"
    var samples: [Double] = [], correctCount = 0, missing = 0
    let beforeLoad = load()
    var peakLoad = beforeLoad
    print("VISIBILITY occlusionVisible=\(win.occlusionState.contains(.visible)) cgOnScreen=\(cgOnScreen()) key=\(win.isKeyWindow) alpha=\(win.alphaValue)")
    for i in 0..<n {
        autoreleasepool {
            let preLoad = load()
            peakLoad = max(peakLoad, preLoad)
            if preLoad > 0.70 { fail("timing-load-guard sample=\(i) load=\(preLoad)") }
            probe.clear()
            p.clipView.removeFromSuperview()
            if p.view.window != nil { fail("timing-not-detached") }
            if released {
                do { try p.view.setUseMetal(false) } catch { fail("timing-release-\(error)") }
                if p.view.isUsingMetalRenderer { fail("timing-release-still-metal") }
            } else if !p.view.isUsingMetalRenderer { fail("control-lost-renderer") }
            let hiddenAt = CACurrentMediaTime()
            let token = i % 2 == 0 ? 2 : 3
            p.view.feed(text: payload(token))
            while CACurrentMediaTime() - hiddenAt < hold { autoreleasepool { pump(min(0.05, hold)) } }
            let showLoad = load()
            peakLoad = max(peakLoad, showLoad)
            if showLoad > 0.70 { fail("timing-load-after-hold sample=\(i) load=\(showLoad)") }
            print("ATTEMPT i=\(i) arm=\(releaseArm) hold=\(hold) preLoad=\(preLoad) showLoad=\(showLoad) onScreen=\(cgOnScreen())")
            fflush(stdout)
            probe.arm(); let start = CACurrentMediaTime()
            // Include synchronous attachment and reconstruction work, not only a later draw.
            container.addSubview(p.clipView)
            if released {
                do { try p.view.setUseMetal(true) } catch { fail("timing-enable-\(error)") }
            }
            win.displayIfNeeded(); CATransaction.flush()
            let deadline = start + 3
            while probe.result().0 == 0 && CACurrentMediaTime() < deadline { pump(0.001) }
            let (time, drawable) = probe.result()
            if time > start, let drawable {
                let actual = pixels(drawable)
                let correct = actual == (token == 2 ? oracle : decoy) && actual != (token == 2 ? decoy : oracle)
                let ms = (time - start) * 1000
                samples.append(ms)
                if correct { correctCount += 1 }
                print("SHOW i=\(i) arm=\(releaseArm) ms=\(ms) correct=\(correct) bytes=\(actual.count) load=\(load()) onScreen=\(cgOnScreen())")
            } else {
                missing += 1
                print("MISSING i=\(i) arm=\(releaseArm) timeoutMS=3000 zeroTimeCallbacks=\(probe.zeroTimes) onScreen=\(cgOnScreen()) completionFloorMS=\((probe.completionTime - start) * 1000) load=\(load())")
            }
            print("TRACE i=\(i) start=\(start) events=\(probe.diagnostics())")
            fflush(stdout)
            peakLoad = max(peakLoad, load())
            // Same retirement gap in both arms; no failed attempt is retried/replaced.
            pump(0.1)
        }
    }
    let sorted = samples.sorted()
    func pct(_ p: Double) -> Double { sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)] }
    print("TIMING arm=\(releaseArm) count=\(samples.count) requested=\(n) hold=\(hold) presentation=\(presentation) p50=\(pct(0.5)) p95=\(pct(0.95)) max=\(sorted.last ?? .nan) correct=\(correctCount)/\(n) missing=\(missing) peakLoad=\(peakLoad) valid=\(peakLoad <= 0.70)")
    withExtendedLifetime((visible, p)) {}
}
