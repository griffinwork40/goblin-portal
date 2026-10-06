// Capture half of check-render-parity.sh: build a REAL TerminalPane, feed it a fixed byte
// stream, and return the pixels one renderer drew. Compiled beside the harness (main.swift)
// and check-render-parity-metrics.swift, @testable-linked against Goblin Portal's own objects.
//
// Why each choice, all measured in the 2026-10-05 audit's P1 probe
// (.afk/research/rendering-audit-2026-10-05.md):
//   * TerminalPane(config:) rather than a bare TerminalView, so apply(config:) runs exactly as
//     in the app: xterm palette strategy, the default theme, the selection pair,
//     applyRenderer, setFontSize, applyTypography. A gate on a bare view would test a
//     configuration nobody runs.
//   * Core Text is captured by calling view.draw(bounds) into an sRGB bitmap context at 2x.
//     That runs GoblinPortalTerminalView.draw and SwiftTerm's Core Text path, and nothing
//     else. Screen capture would need a permission this machine does not grant, and it
//     would add window-server colour management that Metal's capture does not see.
//   * Metal is captured from SwiftTerm's own MTKView: framebufferOnly=false, a forwarding
//     delegate remembers the drawable the renderer encoded into, and a blit copies its
//     texture to shared memory after waitUntilCompleted. No re-render, no second path.
//   * No shell is started. The subject is the renderer; a pty would add a second thing that
//     can fail for reasons the gate is not about (check-metal-renderer.sh, same posture).
//   * The cursor is hidden by the payload header: under Core Text it is a separate subview
//     (CaretView) that draw(_:) never paints, under Metal it is a quad in the same frame,
//     so leaving it on would be a guaranteed and meaningless difference.
import AppKit
import Metal
import MetalKit
@testable import SwiftTerm
@testable import GoblinPortal

enum RendererKind: String { case coreText = "coretext", metal = "metal" }

/// Environmental failure: print the reason the shell half greps for, exit 2. Never a verdict.
func environmental(_ why: String) -> Never { print("ENV=\(why)"); exit(2) }

let gridCols = 80, gridRows = 14

@MainActor
func pump(_ s: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }

/// Forwards to SwiftTerm's own MTKView delegate and remembers the drawable it encoded into.
final class DrawableProxy: NSObject, MTKViewDelegate {
    let inner: MTKViewDelegate
    var captured: CAMetalDrawable?
    init(_ i: MTKViewDelegate) { inner = i }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { inner.mtkView(view, drawableSizeWillChange: size) }
    func draw(in view: MTKView) {
        inner.draw(in: view)
        captured = view.currentDrawable   // the same drawable, cached by MTKView until draw ends
    }
}

/// What a capture needs to know about the grid it drew, in device pixels.
struct Grid {
    let cellW: Int
    let cellH: Int
    let bg: (Int, Int, Int)
    func cell(col: Int, row: Int, width: Int = 1) -> Region {
        Region(x0: col * cellW, y0: row * cellH, x1: (col + width) * cellW, y1: (row + 1) * cellH)
    }
    func row(_ r: Int) -> Region { Region(x0: 0, y0: r * cellH, x1: gridCols * cellW, y1: (r + 1) * cellH) }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Render a CGImage into an RGBA8 sRGB buffer, optionally over an opaque background (the
/// Core Text layer content is transparent where nothing was drawn; the window server would
/// composite it over the layer's background colour, so the capture does the same).
func toImg(_ cg: CGImage, w: Int, h: Int, under bg: (Int, Int, Int)? = nil) -> Img {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let bg {
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [CGFloat(bg.0) / 255, CGFloat(bg.1) / 255,
                                                                    CGFloat(bg.2) / 255, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Img(w: w, h: h, px: px)
}

@MainActor
final class Renderer {
    let window: NSWindow
    let container: NSView

    init() {
        guard MTLCreateSystemDefaultDevice() != nil else { environmental("no-metal-device") }
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == 2 }) else {
            environmental("no-2x-screen (every pixel bound in this gate assumes 2x)")
        }
        // On a real screen (a Metal layer on no screen may never get a drawable), but fully
        // transparent and click-through: nothing visible, no focus taken.
        let rect = NSRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10, width: 900, height: 400)
        window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.colorSpace = NSColorSpace.sRGB
        container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        window.contentView = container
        window.orderFrontRegardless()
        pump(0.1)
    }

    /// A FRESH pane per call: the Metal glyph atlas and row cache are per renderer instance,
    /// so a fresh pane is what makes the determinism case mean "same input, same pixels"
    /// rather than "the cache returned what it returned last time".
    func render(_ payload: String, with kind: RendererKind, prepare: ((TerminalView) -> Void)? = nil) -> (Img, Grid) {
        var cfg = AppConfig.defaults()
        cfg.font = AppConfig.preferredMonoFont(family: nil, size: 14).font
        cfg.renderer = kind == .metal ? .metal : .coreText
        cfg.fontThicken = false
        cfg.smoothScrolling = false
        let pane = TerminalPane(config: cfg, frame: container.bounds,
                                workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let view = pane.view
        container.addSubview(pane.clipView)
        defer { pane.clipView.removeFromSuperview() }
        pump(0.2)
        pane.apply(config: cfg)          // again, now that the view is in a 2x window (renderer + font snap)
        pane.setFontSize(14, persist: false)
        view.resize(cols: gridCols, rows: gridRows)
        pane.clipView.frame = NSRect(origin: .zero, size: view.getOptimalFrameSize().size)
        view.frame = pane.clipView.bounds
        pump(0.2)
        let t = view.getTerminal()
        if t.cols != gridCols || t.rows != gridRows { view.resize(cols: gridCols, rows: gridRows); pump(0.1) }
        if view.window?.backingScaleFactor != 2 { environmental("scale-not-2") }
        if kind == .metal && !view.isUsingMetalRenderer { environmental("metal-unavailable (setUseMetal fell back)") }
        if kind == .coreText && view.isUsingMetalRenderer { environmental("metal-on-for-coretext") }

        var proxy: DrawableProxy?
        if kind == .metal {
            guard let m = view.subviews.compactMap({ $0 as? MTKView }).first, let d = m.delegate else {
                environmental("no-mtkview")
            }
            m.framebufferOnly = false
            proxy = DrawableProxy(d)
            m.delegate = proxy
        }
        view.feed(text: payload)
        prepare?(view)
        pump(0.3)

        let w = Int(view.bounds.width * 2), h = Int(view.bounds.height * 2)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (view.nativeBackgroundColor.usingColorSpace(.sRGB) ?? view.nativeBackgroundColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        let bg = (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        let grid = Grid(cellW: Int((view.cellDimension.width * 2).rounded()),
                        cellH: Int((view.cellDimension.height * 2).rounded()), bg: bg)
        let img = kind == .metal ? captureMetal(view, proxy!, w: w, h: h) : captureCoreText(view, w: w, h: h, bg: bg)
        if img.w < gridCols * grid.cellW || img.h < gridRows * grid.cellH {
            environmental("capture \(img.w)x\(img.h) smaller than the \(gridCols)x\(gridRows) grid")
        }
        return (img, grid)
    }

    private func captureCoreText(_ view: TerminalView, w: Int, h: Int, bg: (Int, Int, Int)) -> Img {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { environmental("ct-context") }
        ctx.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: view.isFlipped)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { environmental("ct-image") }
        return toImg(cg, w: w, h: h, under: bg)
    }

    private func captureMetal(_ view: TerminalView, _ proxy: DrawableProxy, w: Int, h: Int) -> Img {
        guard let m = view.subviews.compactMap({ $0 as? MTKView }).first, let device = m.device else { environmental("no-mtk") }
        // Two synchronous frames; capture the second, because the first may race the
        // display-link pacer's own draw (patch 0010) for the same drawable.
        for _ in 0..<2 { pump(0.1); m.draw() }
        pump(0.2)
        guard let tex = proxy.captured?.texture else { environmental("no-drawable") }
        let tw = tex.width, th = tex.height
        guard let buf = device.makeBuffer(length: tw * th * 4, options: .storageModeShared),
              let q = device.makeCommandQueue(), let cb = q.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { environmental("blit-setup") }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: tw, height: th, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: tw * 4, destinationBytesPerImage: tw * th * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if cb.status != .completed { environmental("blit-failed \(String(describing: cb.error))") }
        let data = Data(bytes: buf.contents(), count: tw * th * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: tw, height: th, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tw * 4,
                               space: sRGB,
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                        | CGImageAlphaInfo.noneSkipFirst.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { environmental("metal-image") }
        if tw != w || th != h { environmental("drawable \(tw)x\(th) vs view \(w)x\(h)") }
        return toImg(cg, w: tw, h: th)
    }
}
