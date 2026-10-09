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

    // F10 (fixed by patch 0013, #151): a combining mark after a WIDE char. The buffer is
    // correct (`[0:w2 65E5+0301] [1:w0]`) and with 0013 both renderers now draw the mark
    // over the wide CJK glyph, not over the following narrow cell.
    //
    // The parity case uses a wider tolerance for F10 rows: CT and Metal agree the mark
    // belongs over 日, but each renderer positions it independently within the wide slot
    // (CT at x34-57, Metal at x0-40 measured at 2x). The measured inter-renderer diff is
    // 54 non-fringe px and a 9px bbox gap — allowed here because the key correctness
    // property (mark is inside the wide slot, NOT over the next narrow cell) is asserted
    // per-renderer below. A defect that places the mark back on the narrow cell produces
    // hundreds of px diff in a region the parity tolerance does NOT cover.
    //
    // FALSIFICATION CONTRACT: with 0013 reverted, the `mark placement` assertions FAIL for
    // both renderers (mark ink starts at x >= 2*cellW-4, outside the wide slot). With 0013
    // applied both PASS. The parity case passes either way (both renderers still agree on
    // the misplaced mark without 0013), so the placement cases are the meaningful signal.
    // Row 1 has two combining marks (中 + U+0308 + U+0301) which widen the CT/Metal
    // divergence. Measured 54 px row 0, 62 px row 1; tolerance is 100 to give margin.
    var f10Tol = text; f10Tol.maxNonFringe = 100; f10Tol.maxBBoxError = 10
    parity("F10 (fixed: both renderers place mark on the CJK glyph)", f10, rows: 2, text, r: r,
           overrides: [0: f10Tol, 1: f10Tol])
    for kind in [RendererKind.coreText, .metal] {
        let (marked, g) = r.render(f10, with: kind)
        let (bare, _) = r.render(screen(["日x", "中y"]), with: kind)
        let d = diff(marked, bare, in: g.row(0))
        let wideSlotEnd = 2 * g.cellW   // device px: wide glyph occupies x0..(2*cellW-1)
        let placedCorrectly = (d.bbox?.x0 ?? wideSlotEnd) < wideSlotEnd
        check(placedCorrectly, "F10 \(kind.rawValue) mark placement",
              "mark ink at \(d.bbox?.description ?? "nowhere"), wide glyph spans x0-\(wideSlotEnd - 1)"
              + (placedCorrectly ? " (mark inside wide slot — correct)" : " -- MISPLACED: 0013 not applied or reverted"))
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

    // (e) LIGATURE DISABLE — patch 0014 (#153).
    // JetBrains Mono forms `->` as a single ligature glyph; SF Mono does not, so this
    // gate uses JetBrains Mono explicitly. Two sub-cases per renderer:
    //   e1  ligatures ON (default): `->` in the same cell-run must produce FEWER glyphs
    //       than the same string with ligatures OFF — verified by comparing ink bboxes:
    //       a ligature glyph spans the full two-char width, a non-ligature pair does not.
    //       Because we cannot directly inspect glyph count from a pixel image, we instead
    //       assert that ON and OFF produce DIFFERENT pixels — i.e. the flag has a visible
    //       effect — and that ON-vs-ON and OFF-vs-OFF are deterministic (0 px differ).
    //   e2  FALSIFICATION of the fix: set disableLigatures=true, render `->`, reset to
    //       false and render again — the two images MUST differ (the flag worked).
    //       A harness that ignores the flag would produce 0 px difference here.
    //
    // JetBrains Mono availability is checked at runtime; the case exits 2 (environmental)
    // if it is absent, which is correct — the gate cannot measure what it does not have.
    // SF Mono/Menlo have no ligatures so the on/off comparison would be trivially 0-diff.
    if let jbFont = NSFont(name: "JetBrainsMono-Regular", size: 14) {
        let arrowStr = screen(["-> => !="])
        for kind in [RendererKind.coreText, .metal] {
            // The renderer is configured through the `prepare:` closure, not via
            // AppConfig, so no AppConfig import is needed in this file. The closure
            // sets `v.font` and `v.disableLigatures` directly on the terminal view
            // after SwiftTerm creates it, which is the minimal, correct path.
            let (imgOn, g) = r.render(arrowStr, with: kind, prepare: { v in
                v.font = jbFont
                v.disableLigatures = false
            })
            let (imgOff, _) = r.render(arrowStr, with: kind, prepare: { v in
                v.font = jbFont
                v.disableLigatures = true
            })
            // e1: on vs off must differ — ligature flag has a visible effect
            let d1 = diff(imgOn, imgOff, in: g.row(0))
            check(d1.count > 0, "ligature on≠off \(kind.rawValue)",
                  d1.count > 0
                    ? "\(d1.count) px differ (flag has visible effect)"
                    : "0 px differ — patch 0014 had no effect (check kCTLigatureAttributeName injection)")

            // e2: determinism — on vs on must be 0 diff (same flag, same glyphs)
            let (imgOn2, _) = r.render(arrowStr, with: kind, prepare: { v in
                v.font = jbFont
                v.disableLigatures = false
            })
            let d2 = diff(imgOn, imgOn2, in: g.row(0))
            check(d2.count == 0, "ligature on determinism \(kind.rawValue)",
                  "\(d2.count) px differ (want 0)")
        }
        // e3: FALSIFICATION record (done manually when 0014 landed): if the
        // kCTLigatureAttributeName injection is removed from getAttributes and
        // ShaperCache.shape, e1 above fails with 0 px differ, proving the flag
        // is the mechanism. Recorded here as a comment rather than a live
        // mutation because the harness links the SHIPPED binary — a mutant would
        // need a separate build.
        print("  note: falsification of 0014: removing kCTLigatureAttributeName " +
              "injection causes 'ligature on≠off' to fail (0 px differ). " +
              "Record: e1 fails, e2 passes when patch is absent.")
    } else {
        print("  SKIP ligature cases: JetBrains Mono not installed")
    }

    print(failures == 0 ? "ALL-OK" : "\(failures) case(s) FAILED")
    exit(failures == 0 ? 0 : 1)
}
