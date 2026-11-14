// Resource census and surface-only release experiments; measurement code only.
// Uses public CAMetalLayer properties via SwiftTerm's internal metalView handle.
// No layer nextDrawable interception here: that would change framebufferOnly/accounting.
import AppKit
import Metal
@preconcurrency import QuartzCore
@testable import SwiftTerm
@testable import GoblinPortal

func surfaceRelease(_ p: TerminalPane, arm: String) {
    guard p.view.window == nil, p.view.renderOwner.waitForMetalIdle(),
          let layer = p.view.metalView?.layer as? CAMetalLayer else { fail("partial-not-idle-layer") }
    switch arm {
    case "shrink": layer.drawableSize = CGSize(width: 1, height: 1)
    case "drain":
        layer.drawableSize = CGSize(width: 1, height: 1)
        guard let d = layer.nextDrawable(), let q = layer.device?.makeCommandQueue(),
              let cb = q.makeCommandBuffer() else { fail("tiny-drawable") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = d.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { fail("tiny-encoder") }
        enc.endEncoding(); cb.present(d); cb.commit(); cb.waitUntilCompleted()
        if cb.status != .completed { fail("tiny-frame") }
    case "device": layer.device = nil
    case "contents": layer.contents = nil
    default: fail("unknown-partial-arm")
    }
    CATransaction.flush()
    if !p.view.isUsingMetalRenderer { fail("partial-dropped-renderer") }
}

func census(_ panes: [TerminalPane], arm: String) {
#if GPU_RELEASE_CENSUS
    for (i, p) in panes.enumerated() {
        guard p.view.renderOwner.waitForMetalIdle() else { fail("census-not-idle") }
        let values = p.view.renderOwner.measurementMetalResources()
        let fields = values.keys.sorted().map { "\($0)=\(values[$0] ?? -1)" }.joined(separator: " ")
        print("RESOURCE arm=\(arm) pane=\(i) \(fields)")
        if let v = p.view.metalView as? TerminalMetalLayerView {
            let d = v.measurementDrawableResources()
            print("DRAWABLE arm=\(arm) pane=\(i) " + d.keys.sorted().map { "\($0)=\(d[$0] ?? -1)" }.joined(separator: " "))
        }
        if let l = p.view.metalView?.layer as? CAMetalLayer {
            print("LAYER arm=\(arm) pane=\(i) width=\(l.drawableSize.width) height=\(l.drawableSize.height) maxDrawables=\(l.maximumDrawableCount) format=\(l.pixelFormat.rawValue) device=\(l.device != nil)")
        }
    }
#endif
}

func breakdown() {
    let keeper = autoreleasepool { makePane(0, coreText: false) }
    var hidden: [TerminalPane] = []
    for i in 0..<n {
        autoreleasepool {
            let p = makePane(i + 1, coreText: false)
            p.clipView.removeFromSuperview()
            hidden.append(p)
        }
    }
    for _ in 0..<30 { autoreleasepool { pump(0.5) } }
    census(hidden, arm: "retained")
    sample("retained")
    // Equal observation/wait schedule before the intervention is the no-op arm.
    census(hidden, arm: "noop")
    sample("noop")
    for p in hidden { autoreleasepool { surfaceRelease(p, arm: releaseArm) } }
    census(hidden, arm: "partial")
    sample("partial-" + releaseArm)
    for p in hidden { autoreleasepool {
        do { try p.view.setUseMetal(false) } catch { fail("full-release-\(error)") }
    } }
    if hidden.contains(where: { $0.view.isUsingMetalRenderer }) { fail("full-still-metal") }
    sample("full-after-" + releaseArm)
    withExtendedLifetime((keeper, hidden)) {}
}
