// Harness for check-render-parity.sh: copied to main.swift and compiled with
// check-render-parity-{capture,cases,metrics}.swift against Goblin Portal's own objects.
// The verdict is this process's EXIT CODE: 0 every case passed, 1 a real failure, 2
// environmental (ENV=<why> on stdout; see environmental() in the capture file).
//
// Tolerances are not guesses. Each is a measured value from this harness on an M-series 2x
// panel (2026-10-05) plus a margin that stays well short of the defect it guards, and each is
// stated where it is asserted. "differing" = some channel moved by more than 8 (the audit's
// diff.py threshold); "fringe" = a differing pixel on a colour edge in both images (see
// nonFringeDiffs). Core Text and Metal rasterize glyph coverage independently, and Metal's
// ink is consistently 4-6% heavier (audit P1), so EXACT equality is only demanded where both
// renderers draw the cell with the same code: box drawing and block elements.
import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, _ detail: String) {
    print("  \(ok ? "ok  " : "FAIL") \(what): \(detail)")
    if !ok { failures += 1 }
}

/// Per-row CT-vs-Metal comparison under the given tolerances.
struct RowTolerance {
    var maxNonFringe = 0          // differing pixels allowed off an edge
    var maxBBoxError = 1          // ink bounding box, any edge, in pixels
    var inkRatio = 0.95...1.15    // Metal ink / Core Text ink
    var exact = false             // demand 0 differing pixels outright
}

@MainActor
func parity(_ name: String, _ payload: String, rows: Int, _ tol: RowTolerance, r: Renderer,
            overrides: [Int: RowTolerance] = [:]) {
    let (ct, g) = r.render(payload, with: .coreText)
    let (mt, _) = r.render(payload, with: .metal)
    var worst = (diff: 0, nonFringe: 0, bbox: 0, lo: 9.0, hi: 0.0)
    var bad: [String] = []
    for row in 0..<rows {
        let t = overrides[row] ?? tol
        let reg = g.row(row)
        let d = diff(ct, mt, in: reg)
        let nf = nonFringeDiffs(ct, mt, in: reg)
        let ic = ink(ct, bg: g.bg, in: reg), im = ink(mt, bg: g.bg, in: reg)
        let be = bboxEdgeError(ic.bbox, im.bbox)
        let ratio = ic.total == 0 ? (im.total == 0 ? 1 : 99) : Double(im.total) / Double(ic.total)
        let s = bestShift(ct, mt, in: reg)
        worst = (max(worst.diff, d.count), max(worst.nonFringe, nf), max(worst.bbox, be),
                 min(worst.lo, ratio), max(worst.hi, ratio))
        if t.exact && d.count != 0 { bad.append("row \(row): \(d.count) px differ, want 0") }
        if nf > t.maxNonFringe { bad.append("row \(row): \(nf) non-fringe px, want <= \(t.maxNonFringe)") }
        if be > t.maxBBoxError { bad.append("row \(row): ink bbox off by \(be == Int.max ? "blank-vs-ink" : "\(be)") px") }
        if !t.inkRatio.contains(ratio) { bad.append(String(format: "row %d: ink ratio %.3f", row, ratio)) }
        if s.dx != 0 || s.dy != 0 { bad.append("row \(row): best shift (\(s.dx),\(s.dy)), want (0,0)") }
    }
    check(bad.isEmpty, "parity \(name)", bad.isEmpty
          ? String(format: "%d rows, max %d px differ (%d non-fringe), bbox <= %dpx, ink %.3f-%.3f, shift (0,0)",
                   rows, worst.diff, worst.nonFringe, worst.bbox, worst.lo, worst.hi)
          : bad.joined(separator: "; "))
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)   // never activates, never takes focus
    let r = Renderer()

    // (a) DETERMINISM. Same bytes, two fresh panes, per renderer: 0 differing pixels and a
    // max channel delta of 0. If this fails, every other number below is noise.
    for kind in [RendererKind.coreText, .metal] {
        let (a, g) = r.render(mixed, with: kind)
        let (b, _) = r.render(mixed, with: kind)
        let d = diff(a, b, in: Region(x0: 0, y0: 0, x1: gridCols * g.cellW, y1: gridRows * g.cellH))
        check(d.count == 0 && d.maxDelta == 0, "determinism \(kind.rawValue)",
              "\(d.count) px differ, max delta \(d.maxDelta) (want 0, 0)")
    }

    // (b) FALSIFICATION. One changed character (`>` -> `!` at col 38, row 0) must be SEEN, and
    // only inside its own cell. Measured 143 px Core Text / 145 px Metal. The floor of 40 is a
    // third of that: a harness that compared the wrong image, or a blank one, sees 0.
    for kind in [RendererKind.coreText, .metal] {
        let (a, g) = r.render(ascii, with: kind)
        let (b, _) = r.render(asciiOneCharChanged, with: kind)
        let d = diff(a, b, in: Region(x0: 0, y0: 0, x1: gridCols * g.cellW, y1: gridRows * g.cellH))
        let cell = g.cell(col: changedCell.col, row: changedCell.row)
        let inside = d.bbox.map { cell.contains($0) } ?? false
        check(d.count >= 40 && inside, "falsification \(kind.rawValue)",
              "\(d.count) px differ in \(d.bbox?.description ?? "nothing"), cell is \(cell) (want >= 40, all inside)")
    }

    // (c) PARITY PER CONTENT CLASS. Measured worst case in brackets.
    // Text classes: differences only on glyph edges (0 non-fringe px), best integer shift (0,0)
    // on every row (an offset glyph would shift), ink bbox within 1px on every edge [1], and
    // Metal ink 0.95-1.15x Core Text's [1.019-1.056; the systematic AA weight]. N4's emoji sat
    // at 0.62-0.69x and 8px off, so none of these bounds is anywhere near permissive enough to
    // hide a misplaced or mis-sized glyph.
    let text = RowTolerance()
    parity("ascii", ascii, rows: 4, text, r: r)
    // Box drawing and block elements are drawn by each renderer's own geometry code, not a
    // font, and measured byte-identical [0 px, max delta 1]. Demand exactly that.
    let exact = RowTolerance(maxNonFringe: 0, maxBBoxError: 0, inkRatio: 0.99...1.01, exact: true)
    parity("box drawing", box, rows: 12, exact, r: r)
    parity("block elements", blocks, rows: 5, exact, r: r)
    parity("cjk", cjk, rows: 3, text, r: r)
    // SGR: one attribute per row. Two documented exceptions, both narrower than the defect
    // class they could hide: row 3 (dim) has ink ratio 1.123 because Metal's AA weight is
    // relatively larger on a low-contrast colour; row 7 (curly underline) has 10 non-fringe px
    // because each renderer generates the waveform with its own code, which agrees in bbox and
    // ink (0.995) but not in exact phase. A missing or moved underline is hundreds of px.
    // Rows 10 (red underline), 11 (strike), and 12 (red-on-green) have no per-row override and
    // fall through to the default `text` tolerance. That tolerance bounds non-fringe count and
    // ink ratio. A missing or skipped attribute (omitting the underline, dropping the strike)
    // would be caught — the non-fringe delta would blow past `maxNonFringe`. A wrong colour is
    // NOT caught: `inkAt` measures ink against the cell background (`g.bg`), not per channel,
    // and the max-channel delta on 1-2 px strokes falls inside the fringe filter. Not falsified
    // for colour; the emoji case (d) below is the falsified check for Metal colour fidelity.
    var dim = text; dim.inkRatio = 0.95...1.18
    var curly = text; curly.maxNonFringe = 24
    parity("sgr + underlines", sgr, rows: sgrParts.count, text, r: r, overrides: [3: dim, 7: curly])

    // (d) EMOJI (N4, fixed by patch 0012). Each 2-cell slot on row 0 separately: Metal's ink
    // bbox within 1px of Core Text's on every edge [measured 1] and ink total within 3% [0.2-1.6%].
    // Without 0012: bbox off by 8px (x0-25/y3-29 vs x2-33/y1-32 for U+1F600) and ink 0.62-0.69x.
    do {
        let (ct, g) = r.render(emoji, with: .coreText)
        let (mt, _) = r.render(emoji, with: .metal)
        for col in emojiSlots {
            let slot = g.cell(col: col, row: 0, width: 2)
            let ic = ink(ct, bg: g.bg, in: slot), im = ink(mt, bg: g.bg, in: slot)
            let be = bboxEdgeError(ic.bbox, im.bbox)
            let ratio = Double(im.total) / Double(max(1, ic.total))
            check(ic.total > 0 && be <= 1 && abs(ratio - 1) <= 0.03, "emoji slot col \(col)",
                  String(format: "CT ink %@ / Metal ink %@, bbox off by %@ px, ink ratio %.3f (want <= 1, 0.97-1.03)",
                         ic.bbox?.description ?? "none", im.bbox?.description ?? "none",
                         be == Int.max ? "blank-vs-ink" : "\(be)", ratio))
        }
    }
    parity("emoji rows", emoji, rows: 3, text, r: r)

    // PINNED F10 (NOT fixed): a combining mark after a WIDE char. The buffer is right
    // (`[0:w2 65E5+0301] [1:w0]`), but BOTH renderers draw the mark over the FOLLOWING cell
    // instead of on the CJK glyph. Parity therefore passes, and says nothing about whether the
    // result is correct. The pin: the pixels the mark adds (vs. the same row without it) start
    // no further left than 4px before column 2 [measured x34, cell 2 starts at x36: the
    // acute's AA tail], i.e. nothing lands over the body of the wide glyph. A fixed F10 centres
    // the mark over the CJK glyph (~x10-26) and this case FAILS on purpose: update the pin,
    // do not loosen it.
    parity("F10 (pinned: both renderers misplace it alike)", f10, rows: 2, text, r: r)
    for kind in [RendererKind.coreText, .metal] {
        let (marked, g) = r.render(f10, with: kind)
        let (bare, _) = r.render(screen(["日x", "中y"]), with: kind)
        let d = diff(marked, bare, in: g.row(0))
        let misplaced = (d.bbox?.x0 ?? -1) >= 2 * g.cellW - 4
        check(misplaced, "PINNED F10 \(kind.rawValue)",
              "mark ink at \(d.bbox?.description ?? "nowhere"), wide glyph spans x0-\(2 * g.cellW - 1)"
              + (misplaced ? " (still misplaced, as pinned)" : " -- CHANGED: re-measure F10 and update this pin"))
    }

    // PINNED N5 (NOT fixed): Metal's `|` paints one device-pixel line into the row below
    // (Metal glyph quads are not clipped to their row; Core Text's stop at the row edge).
    // Row 1 is empty: Core Text must leave it blank, Metal draws exactly one line at its top.
    do {
        let (ct, g) = r.render(n5, with: .coreText)
        let (mt, _) = r.render(n5, with: .metal)
        let below = g.row(1)
        let ic = ink(ct, bg: g.bg, in: below), im = ink(mt, bg: g.bg, in: below)
        let oneLine = im.bbox.map { $0.y0 == below.y0 && $0.y1 == below.y0 + 1 } ?? false
        check(ic.bbox == nil && oneLine, "PINNED N5",
              "row below `|`: Core Text ink \(ic.bbox?.description ?? "none"), Metal ink \(im.bbox?.description ?? "none")"
              + (ic.bbox == nil && oneLine ? " (Metal bleeds 1px, as pinned)" : " -- CHANGED: re-measure N5 and update this pin"))
        parity("N5 row 0", n5, rows: 1, text, r: r)
    }

    print(failures == 0 ? "ALL-OK" : "\(failures) case(s) FAILED")
    exit(failures == 0 ? 0 : 1)
}
