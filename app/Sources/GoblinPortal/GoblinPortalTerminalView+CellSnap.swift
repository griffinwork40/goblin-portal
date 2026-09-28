//
//  GoblinPortalTerminalView+CellSnap.swift
//  Keeping the cell grid pixel-aligned to the display the view is ACTUALLY on.
//
//  THE BUG THIS OWNS (2026-09-28, "tmux shifts everything on my external monitor").
//  SwiftTerm snaps the cell width to the pixel grid exactly once, when the font is
//  set: `computeFontDimensions()` does `ceil(width * scale) / scale` with
//  `scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor`
//  (`Apple/AppleTerminalView.swift:272-276`, `Mac/MacTerminalView.swift:771-774`).
//  Nothing re-snaps it when the view later lands on a display with a different
//  scale — the vendored view has no `viewDidChangeBackingProperties` at all. The
//  fonts are applied while the pane is still detached, so on a Mac whose MAIN
//  display is a 2x Retina panel every terminal is snapped for 2x, including one
//  that then opens on a 1x external monitor.
//
//  That alone would be harmless, but the two glyph paths disagree about a
//  fractional cell. Text is placed at `cellWidth * column`
//  (`Apple/Metal/MetalTerminalRenderer.swift:1222`), while box-drawing glyphs, and
//  non-antialiased block glyphs, step by `round(cellWidthPx)` (`:895`, `:946`, `:994`).
//  Core Text rounds box-drawing the same way (`Apple/AppleTerminalView.swift:1236`) but
//  places block glyphs fractionally (`:1191`), so switching `renderer` does not fix the
//  tmux border, only the half-block art. Measured for the system monospaced face at 18pt: raw advance
//  11.127pt, snapped at 2x to 11.5pt, drawn on a 1x monitor as 11.5px text steps
//  against 12px box steps — +0.5px per column, so tmux's `│` pane border at column
//  104 lands ~52px (≈4.5 columns) to the right of the pane text it separates, and
//  half-block art drifts the same way. At 14pt the 2x snap is exactly 9.0 and
//  nothing drifts, which is why it took a zoom, a 1x screen and a wide (full
//  screen) window together to see it.
//
//  THE FIX. Re-apply the font whenever the view is in a window whose backing scale
//  differs from the one the current snap was computed for. Re-assigning `font` is
//  the same `resetFont()` path a ⌘+ zoom takes, so it recomputes the cell size AND
//  resizes the grid and the pty (a real SIGWINCH, so tmux redraws). After it,
//  `cellWidth * scale` is a whole number and the two glyph paths agree exactly.
//  The snap scale is RECORDED rather than re-snapping on every attach, because a
//  document tab switch detaches and re-attaches this view, and `resetFont()` ends
//  in `terminal.softReset()` (`Apple/AppleTerminalView.swift:2245-2250`) — cheap,
//  but not something to do on every ⌘1..⌘9 when the scale did not change.
//
//  A subclass hook rather than a vendor patch, for the same reason the rest of this
//  subclass exists: `patches/swiftterm/` is a deliberate, auditable surface, and
//  this needs nothing SwiftTerm does not already expose publicly.
//

import AppKit
import SwiftTerm

extension GoblinPortalTerminalView {
    private static var cellSnapScaleKey: UInt8 = 0

    /// The backing scale the current cell size was snapped for, or nil when unknown.
    private var cellSnapScale: CGFloat? {
        get { objc_getAssociatedObject(self, &Self.cellSnapScaleKey) as? CGFloat }
        set { objc_setAssociatedObject(self, &Self.cellSnapScaleKey, newValue,
                                       .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Call after anything that makes SwiftTerm run `resetFont()` (setting `font`
    /// or `lineSpacing`). Mirrors the fallback chain of SwiftTerm's own
    /// `backingScaleFactor()`, so it records the scale that snap actually used —
    /// including the detached case, where that is the MAIN screen's, not ours.
    func noteCellGridSnapped() {
        cellSnapScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    /// Re-snap the grid if this view is now drawing at a different scale than the
    /// one its cell size was snapped for. Idempotent; a no-op while detached.
    func resnapCellGridIfNeeded() {
        guard let scale = window?.backingScaleFactor, scale != cellSnapScale else { return }
        let current = font
        font = current            // → resetFont() → computeFontDimensions() at `scale`
        cellSnapScale = scale
        if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
            FileHandle.standardError.write(
                "[diag] cell grid re-snapped for backing scale \(scale): caret \(caretFrame.size)\n"
                    .data(using: .utf8)!)
        }
    }

    // Moving a window between a 2x and a 1x display (including entering full screen
    // on another display) changes the backing scale without changing the frame, so
    // no resize path fires — this is the only notification that it happened.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resnapCellGridIfNeeded()
    }

    // Covers a pane whose font was applied while detached (snapped for the main
    // screen) and then attached to a window on a different-scale display.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resnapCellGridIfNeeded()
    }
}
