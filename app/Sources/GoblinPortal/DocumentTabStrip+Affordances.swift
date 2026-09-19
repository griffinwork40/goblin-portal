//
//  DocumentTabStrip+Affordances.swift
//  The small affordances inside and beside each tab: the unsaved dot, the status
//  dot, the close glyph (×), the new-tab button (+), and the overflow chevron.
//
//  Extracted from `DocumentTabStrip+Drawing.swift` when the pill-tab rework
//  pushed the drawing file toward the 350-LOC ceiling. These are self-contained
//  drawing helpers that only READ strip state — they paint glyphs into rects
//  handed to them and never compute positions. The positioning (which rect a dot
//  occupies, where the × goes) is still decided by `drawTab` in the drawing file;
//  these just paint what goes inside that rect. That split — caller decides WHERE,
//  helper decides WHAT — is what keeps the two files from needing to agree on
//  geometry independently.
//

import AppKit

extension DocumentTabStrip {

    func drawEditedDot(in box: NSRect) {
        let side: CGFloat = 7
        let dot = NSRect(
            x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        contentForeground.withAlphaComponent(0.75).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    /// The status dot: same geometry as the unsaved dot so the two never disagree about
    /// where that affordance lives, but coloured, and given a soft halo on inactive tabs.
    ///
    /// The halo is on the INACTIVE tab, not the active one. That is the whole design
    /// argument: you are already looking at the active document, so a marker there is
    /// telling you something you can see — the signal is worth its ink precisely on the
    /// tabs you are not reading. Inactive tabs also draw their title at 0.72 alpha, so
    /// without the halo a coloured dot on a dim tab is the quietest thing in the strip
    /// rather than the loudest.
    ///
    /// Survives PR #5's compression unchanged, and that is a property of `box`, not
    /// luck: both the dot and the halo are measured from `closeRect`, whose 15pt side
    /// is fixed furniture that `minTabWidth`'s derivation reserves in full at the 56pt
    /// floor — the title is what gets elided there, never this box. So the 7pt dot
    /// inside a 12pt halo reads identically on a 56pt tab and a 210pt one; the tab
    /// around it is narrower, which if anything raises the marker's share of the ink.
    func drawStatusDot(in box: NSRect, colour: NSColor, isActive: Bool) {
        if !isActive {
            colour.withAlphaComponent(0.22).setFill()
            NSBezierPath(ovalIn: box.insetBy(dx: 1.5, dy: 1.5)).fill()
        }
        let side: CGFloat = 7
        let dot = NSRect(
            x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        // Full opacity on both, unlike the title. A status the eye has to hunt for is a
        // status that does not work.
        colour.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    func drawCloseGlyph(in box: NSRect, emphasised: Bool) {
        if emphasised {
            contentForeground.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        }
        let inset = box.insetBy(dx: 4.5, dy: 4.5)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset.minX, y: inset.minY))
        path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        path.move(to: NSPoint(x: inset.minX, y: inset.maxY))
        path.line(to: NSPoint(x: inset.maxX, y: inset.minY))
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        contentForeground.withAlphaComponent(emphasised ? 0.95 : 0.6).setStroke()
        path.stroke()
    }

    func drawNewButton(_ layout: Layout) {
        let rect = newButtonRect(layout)
        if isHoveringNewButton {
            hoverBackground.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 3), xRadius: 5, yRadius: 5).fill()
        }
        let arm: CGFloat = 4.5
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre.x - arm, y: centre.y))
        path.line(to: NSPoint(x: centre.x + arm, y: centre.y))
        path.move(to: NSPoint(x: centre.x, y: centre.y - arm))
        path.line(to: NSPoint(x: centre.x, y: centre.y + arm))
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        contentForeground.withAlphaComponent(isHoveringNewButton ? 0.95 : 0.55).setStroke()
        path.stroke()
    }

    /// A downward chevron, matching the disclosure shape AppKit uses for
    /// "there is more here than fits" (NSPopUpButton's pull-down arrow). Drawn as a
    /// path rather than an SF Symbol for the same reason the × is: the symbol would
    /// need the tint-by-sourceAtop dance in `drawTab` for two strokes.
    func drawOverflowButton(in rect: NSRect) {
        if isHoveringOverflowButton {
            hoverBackground.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 3), xRadius: 5, yRadius: 5).fill()
        }
        let halfWidth: CGFloat = 4
        let halfHeight: CGFloat = 2.5
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre.x - halfWidth, y: centre.y + halfHeight))
        path.line(to: NSPoint(x: centre.x, y: centre.y - halfHeight))
        path.line(to: NSPoint(x: centre.x + halfWidth, y: centre.y + halfHeight))
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        contentForeground.withAlphaComponent(isHoveringOverflowButton ? 0.95 : 0.55).setStroke()
        path.stroke()
    }
}
