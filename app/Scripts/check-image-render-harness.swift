// Harness for check-image-render.sh: copied to main.swift and compiled with
// check-image-render-payloads.swift plus check-render-parity-{capture,metrics}.swift (reused
// unchanged: a real TerminalPane, offscreen 2x window, render(payload, with:) = view.feed).
// The verdict is this process's EXIT CODE: 0 pass, 1 an assertion failed, 2 environmental.
//
// ABSOLUTE, not parity: each case says where the image MUST be and what colour, per renderer.
// Tolerances, with why:
//   * edges: a 1px band on each side of the expected rect is unconstrained (NSImage draw vs
//     texture sampling may land a stripe edge on either side of a device-pixel boundary).
//   * colour: every pixel strictly inside must be within 10 per channel of `paint`. Core Text
//     measured EXACT (230,60,20). Metal measured (226,53,20) for all three protocols (2026-10-21,
//     M-series 2x): a uniform ~3% shift, G -7, consistent with the image texture being sampled
//     without the sRGB colour match NSImage.draw applies -- a colour-management divergence, NOT a
//     painting bug (geometry is pixel-exact). Recorded in the PR; 10 admits it and is still 20x
//     below a channel swap (|230-20| = 210) and far below a premultiply or gamma-2.2 slip.
//   * absence: no pixel in a 6px ring outside the 1px band may carry ink (> 8 from bg, the
//     parity gate's own threshold): an image drawn one cell off, or twice, lands there.
import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, _ detail: String) {
    print("  \(ok ? "ok  " : "FAIL") \(what) \(detail)")
    if !ok { failures += 1 }
}

func near(_ img: Img, _ x: Int, _ y: Int, _ c: (r: Int, g: Int, b: Int), tol: Int) -> Bool {
    abs(img.chan(x, y, 0) - c.r) <= tol && abs(img.chan(x, y, 1) - c.g) <= tol && abs(img.chan(x, y, 2) - c.b) <= tol
}

/// Inside: every pixel of `r` shrunk by `edge` within `tol` of `c`. Outside: no ink in the
/// ring between `r` grown by `edge` and `r` grown by `edge + ring`.
func solid(_ img: Img, _ g: Grid, _ r: Region, _ c: (r: Int, g: Int, b: Int), edge: Int = 1, ring: Int = 6,
           tol: Int = 10) -> (ok: Bool, detail: String) {
    var bad = 0, firstBad = ""
    for y in (r.y0 + edge)..<(r.y1 - edge) { for x in (r.x0 + edge)..<(r.x1 - edge) where !near(img, x, y, c, tol: tol) {
        if bad == 0 { firstBad = "(\(x),\(y))=\(img.chan(x, y, 0)),\(img.chan(x, y, 1)),\(img.chan(x, y, 2))" }
        bad += 1
    } }
    let inner = Region(x0: r.x0 - edge, y0: r.y0 - edge, x1: r.x1 + edge, y1: r.y1 + edge)
    let outer = Region(x0: max(0, inner.x0 - ring), y0: max(0, inner.y0 - ring),
                       x1: min(img.w, inner.x1 + ring), y1: min(img.h, inner.y1 + ring))
    var leak = 0
    var leakBox: Region?
    for y in outer.y0..<outer.y1 { for x in outer.x0..<outer.x1
        where !(x >= inner.x0 && x < inner.x1 && y >= inner.y0 && y < inner.y1) && img.inkAt(x, y, bg: g.bg) > inkThreshold {
        leak += 1
        leakBox = leakBox.map { Region(x0: min($0.x0, x), y0: min($0.y0, y), x1: max($0.x1, x + 1), y1: max($0.y1, y + 1)) }
            ?? Region(x0: x, y0: y, x1: x + 1, y1: y + 1)
    } }
    let all = ink(img, bg: g.bg, in: Region(x0: 0, y0: 0, x1: gridCols * g.cellW, y1: gridRows * g.cellH)).bbox
    return (bad == 0 && leak == 0,
            "want \(r) rgb(\(c.r),\(c.g),\(c.b)); inside off-colour \(bad) px \(firstBad); ring ink \(leak) px "
            + "\(leakBox?.description ?? ""); all ink \(all?.description ?? "none")")
}

func cells(_ g: Grid, row: Int, col: Int, rows: Int, cols: Int) -> Region {
    Region(x0: col * g.cellW, y0: row * g.cellH, x1: (col + cols) * g.cellW, y1: (row + rows) * g.cellH)
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    let r = Renderer()
    let only = ProcessInfo.processInfo.environment["IMAGE_RENDER_ONLY"]
    for kind in [RendererKind.coreText, .metal] where only == nil || only == kind.rawValue {
        let k = kind.rawValue
        // C1 OSC 1337 inline=1 width=4;height=2 cells -> exactly that cell rectangle.
        do {
            let (img, g) = r.render(at(imgRow, imgCol) + osc1337(), with: kind)
            let s = solid(img, g, cells(g, row: imgRow, col: imgCol, rows: 2, cols: 4), paint)
            check(s.ok, "osc1337-\(k)", s.detail)
        }
        // C2 sixel, 40 x 24 px auto-sized: at 2x it is 40 x 24 DEVICE px from the cell origin.
        // (40 x 24 is deliberately sub-cell to verify sub-cell placement; C2b covers a full-cell span.)
        do {
            let (img, g) = r.render(at(imgRow, imgCol) + sixel(w: 40, bands: 4), with: kind)
            let o = cells(g, row: imgRow, col: imgCol, rows: 1, cols: 1)
            let s = solid(img, g, Region(x0: o.x0, y0: o.y0, x1: o.x0 + 40, y1: o.y0 + 24), paint)
            check(s.ok, "sixel-\(k)", s.detail)
        }
        // C2b cell-aligned sixel: 4 x 2 cells wide/tall, sized from the actual cell dimensions
        // captured in C1's render. sixelBands = ceil(2*cellH / 6) ensures the sixel height is a
        // multiple of 6 (sixel's band unit). If 2*cellH is not a multiple of 6 the image overshoots
        // by up to 5 device px; we assert only over the 2*cellH px the image must cover (not the
        // overshoot), so the ring check is not tripped by the harmless extra band.
        do {
            let (_, g0) = r.render(at(imgRow, imgCol) + osc1337(), with: kind)
            let sixelW = 4 * g0.cellW
            let sixelBands = (2 * g0.cellH + 5) / 6   // ceil(2*cellH / 6)
            let (img, g) = r.render(at(imgRow, imgCol) + sixel(w: sixelW, bands: sixelBands), with: kind)
            let o = cells(g, row: imgRow, col: imgCol, rows: 1, cols: 1)
            // Assert over sixelBands*6 px (the actual painted extent), not 2*cellH: if 2*cellH
            // is not a multiple of 6 the image overshoots by up to 5 device px and those extra
            // pixels would appear in the ring. The overshoot is harmless; we just assert what
            // the renderer actually painted rather than the ideal cell boundary.
            let assertH = sixelBands * 6
            let s = solid(img, g, Region(x0: o.x0, y0: o.y0, x1: o.x0 + sixelW, y1: o.y0 + assertH), paint)
            check(s.ok, "sixel-cell-aligned-\(k)", s.detail)
        }
        // C3 kitty APC G a=T c=4 r=2 -> the 4 x 2 cell rectangle.
        do {
            let (img, g) = r.render(at(imgRow, imgCol) + kitty(), with: kind)
            let s = solid(img, g, cells(g, row: imgRow, col: imgCol, rows: 2, cols: 4), paint)
            check(s.ok, "kitty-\(k)", s.detail)
        }
        // C4 alt buffer: drawn under ?1049h it must paint (positive half, so the negative half
        // is not vacuous) and after ?1049l the normal screen must carry no ink at all.
        do {
            let enter = "\(imgESC)[?1049h" + at(imgRow, imgCol) + osc1337()
            let (inAlt, g) = r.render(enter, with: kind)
            let s = solid(inAlt, g, cells(g, row: imgRow, col: imgCol, rows: 2, cols: 4), paint)
            let (left, g2) = r.render(enter + "\(imgESC)[?1049l", with: kind)
            let any = ink(left, bg: g2.bg, in: Region(x0: 0, y0: 0, x1: gridCols * g2.cellW, y1: gridRows * g2.cellH)).bbox
            check(s.ok && any == nil, "altbuffer-\(k)",
                  "in alt: \(s.ok ? "painted" : "NOT painted: " + s.detail); after ?1049l ink \(any?.description ?? "none") (want none)")
        }
        // C5 cursor advance: insertImage linefeeds once per stripe and restores x
        // (AppleTerminalView.swift insertImage), so text after a 2-row image lands at
        // (imgRow + 2, imgCol) -- and the image is still there.
        // ESC[4C moves the cursor right 4 cols (past the image's column span) *relatively*,
        // so the row is still determined by the image's own cursor advance: if the image
        // fails to advance 2 rows the marker will land on the wrong row and the probe fails.
        do {
            let cursorRight4 = "\(imgESC)[4C"
            let (img, g) = r.render(at(imgRow, imgCol) + osc1337() + cursorRight4 + marker, with: kind)
            let m = cells(g, row: imgRow + 2, col: imgCol + 4, rows: 1, cols: 1)
            var ok = true, bad = 0
            for y in (m.y0 + 2)..<(m.y1 - 2) { for x in (m.x0 + 2)..<(m.x1 - 2) where !near(img, x, y, markerRGB, tol: 6) { bad += 1 } }
            ok = bad == 0
            // ring: 0 because the marker lands at col imgCol+4, immediately right of the image's
            // 4-col span; a 6px ring would reach the marker's ink and trip a false leak alarm.
            // The cursor-advance assertion is carried by the row probe (bad == 0), not the ring.
            let s = solid(img, g, cells(g, row: imgRow, col: imgCol, rows: 2, cols: 4), paint, ring: 0)
            check(ok && s.ok, "cursor-advance-\(k)",
                  "marker cell \(m): \(bad) off-colour px (want 0); image \(s.ok ? "intact" : s.detail)")
        }
        // C6 control: inline=0 is a download, never a draw -- nothing may be painted.
        do {
            let (img, g) = r.render(at(imgRow, imgCol) + osc1337(inline: 0), with: kind)
            let any = ink(img, bg: g.bg, in: Region(x0: 0, y0: 0, x1: gridCols * g.cellW, y1: gridRows * g.cellH)).bbox
            check(any == nil, "inline0-control-\(k)", "ink \(any?.description ?? "none") (want none)")
        }
    }
    print(failures == 0 ? "ALL-OK" : "\(failures) case(s) FAILED")
    exit(failures == 0 ? 0 : 1)
}
