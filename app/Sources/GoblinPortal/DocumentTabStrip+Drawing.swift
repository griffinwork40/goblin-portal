//
//  DocumentTabStrip+Drawing.swift
//  Every mark the strip puts on screen: the rail, each tab, the unsaved/status dot,
//  the ×, the "+" and the overflow chevron.
//
//  Its own file because painting is the strip's largest concern and the one that
//  changes for purely visual reasons, while the layout arithmetic next door in
//  `DocumentTabStrip.swift` must not change casually — hit-testing reads the same
//  rects (see that file's "MARK: - Geometry" note). Separating them is what keeps a
//  colour tweak out of the file where a wrong number closes the tab beside the one
//  you clicked. Nothing here computes a position: every rect comes from `layout`,
//  `tabRect`, `closeRect`, `newButtonRect` or `overflowButtonRect`, so there stays
//  exactly one definition of where a thing is.
//
//  This file only READS strip state — `item(_:)`, `activeIndex`, the four hover
//  flags, the two content colours. The writers are `reload`/`apply` in the core file
//  and the hover tracking in `DocumentTabStrip+Mouse.swift`; drawing never writes,
//  which is why those properties are `private(set)` wherever a single writer exists.
//

import AppKit

extension DocumentTabStrip {
    // MARK: - Drawing

    /// Perceptual darkness of the terminal background, used to decide which way to
    /// push the rail and the inactive text. Falls back to "dark" because a nil
    /// theme means SwiftTerm's defaults, whose background is black
    /// (`Colors.swift:37` defaultBackground).
    private var contentIsDark: Bool {
        guard let rgb = contentBackground.usingColorSpace(.deviceRGB) else { return true }
        return rgb.brightnessComponent < 0.5
    }

    private var railBackground: NSColor {
        let toward: NSColor = contentIsDark ? .white : .black
        // Small fraction on purpose: the rail should read as a shade of the
        // terminal, not as a separate piece of system chrome bolted on top.
        return contentBackground.blended(withFraction: 0.07, of: toward) ?? contentBackground
    }

    private var hoverBackground: NSColor {
        let toward: NSColor = contentIsDark ? .white : .black
        return contentBackground.blended(withFraction: 0.13, of: toward) ?? contentBackground
    }

    override func draw(_ dirtyRect: NSRect) {
        railBackground.setFill()
        bounds.fill()

        // Resolve once per paint and pass it down: recomputing `layout` per tab would
        // be correct but would re-derive the window N times for no reason, and it is
        // the same value that hit-testing will use.
        let layout = self.layout
        for index in layout.visible {
            drawTab(index, layout)
        }
        if let overflow = overflowButtonRect(layout) {
            drawOverflowButton(in: overflow)
        }
        drawNewButton(layout)

        // Hairline under the *inactive* stretch only. Running it under the active
        // tab too would draw a line between the tab and its own content, which is
        // precisely the seam this design removes.
        contentForeground.withAlphaComponent(0.12).setFill()
        let hairline = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        // `?? .zero` covers the active tab having been windowed out; `slices` treats
        // an empty exclusion as "no exclusion", so the hairline simply runs the full
        // width — correct, because in that state no tab on screen owns the content.
        let active = tabRect(activeIndex, layout) ?? .zero
        for slice in hairline.slices(excluding: active) {
            slice.fill()
        }
    }

    private func drawTab(_ index: Int, _ layout: Layout) {
        guard let rect = tabRect(index, layout) else { return }
        let isActive = index == activeIndex

        if isActive {
            contentBackground.setFill()
            rect.fill()

            // 2px accent line at the very bottom of the active tab — the same
            // "you are here" signal Ghostty and VS Code use. Drawn after the fill
            // so it sits on top, and bounded horizontally to the tab rect so it
            // never bleeds into a neighbour or the rail gap. The colour is
            // `contentAccent` (the theme's cursor colour, or the system accent),
            // chosen because the cursor is already the most salient per-theme
            // colour — visually coherent with the caret the eye tracks in the
            // terminal below. Height is 2pt; at 1pt it disappears on non-Retina.
            let accentLine = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2)
            contentAccent.setFill()
            accentLine.fill()
        } else if hoveredTab == index {
            hoverBackground.setFill()
            rect.fill()
        }

        // Separator between adjacent inactive tabs. Skipped next to the active tab
        // because the active tab's own fill already provides the edge.
        if !isActive && index != activeIndex + 1 && index > 0 {
            contentForeground.withAlphaComponent(0.10).setFill()
            NSRect(x: rect.minX, y: 6, width: 1, height: rect.height - 12).fill()
        }

        // 0.72 for inactive, not the 0.55 this shipped with until 2026-08-03. At 0.55 the
        // composite of the theme foreground over `railBackground` measured APCA Lc 37.3
        // under umber, 33.0 under afk-dark and 32.1 under tokyo-night — below APCA's Lc 45
        // floor for text readable at ANY size, which made these 11pt labels the least
        // legible text in the app. It failed for every palette, so it was the strip's
        // constant at fault and not any theme. 0.72 clears 45 for all three (umber 53.9)
        // while leaving a 23-27 Lc gap to the active label, which is what tells you which
        // document you are looking at. `check-theme-contrast.sh` now measures all four
        // numbers and greps this file to confirm they are still the shipped ones.
        let textAlpha: CGFloat = isActive ? 0.95 : 0.72
        var textLeft = rect.minX + Self.horizontalPadding

        if let symbol = NSImage(systemSymbolName: item(index).symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
            symbol.isTemplate = true
            let side: CGFloat = 12
            let symbolRect = NSRect(
                x: textLeft, y: (rect.height - side) / 2, width: side, height: side)
            // Template images render black when drawn directly; tint by filling
            // source-atop over the just-drawn glyph.
            NSGraphicsContext.saveGraphicsState()
            symbol.draw(in: symbolRect)
            contentForeground.withAlphaComponent(textAlpha).set()
            symbolRect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
            textLeft = symbolRect.maxX + 5
        }

        // Reserve the close box so a long title never draws underneath the ×.
        let textRight = closeRect(rect).minX - 4
        if textRight > textLeft {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributed = NSAttributedString(
                string: item(index).title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: isActive ? .medium : .regular),
                    .foregroundColor: contentForeground.withAlphaComponent(textAlpha),
                    .paragraphStyle: paragraph,
                ]
            )
            let textHeight = attributed.size().height
            attributed.draw(
                in: NSRect(
                    x: textLeft, y: (rect.height - textHeight) / 2,
                    width: textRight - textLeft, height: textHeight))
        }

        // The × is drawn only for the active tab or the hovered one. Showing it on
        // every tab turns a quiet rail into a row of buttons.
        //
        // An edited tab shows a dot in that same box until you hover it, at which
        // point the × takes over — Safari's and VS Code's arrangement. Sharing the
        // box rather than adding a second affordance is deliberate: the dot has to
        // be visible on *inactive* tabs (that is the whole point of an unsaved
        // marker) and the close box is the only slot already reserved on those.
        //
        // Status joins the SAME box on the SAME rule rather than getting a slot of its
        // own. Two dots on one tab is a row of indicator lights, and at the 56pt floor
        // there is no room for a second reserved slot at all: `minTabWidth`'s own
        // derivation above accounts for exactly one 15pt close box inside 48pt of fixed
        // furniture, so a second box would push the floor to ~71pt and undo the
        // compression PR #5 added. When a tab is both edited and asking for attention,
        // status wins the box: unsaved work is still there in a minute, whereas a
        // prompt waiting for input is blocking.
        let statusDot = item(index).status.dotColour(
            fallback: contentForeground, isActive: isActive)
        if let statusDot, hoveredTab != index {
            drawStatusDot(in: closeRect(rect), colour: statusDot, isActive: isActive)
        } else if item(index).isEdited && hoveredTab != index {
            drawEditedDot(in: closeRect(rect))
        } else if isActive || hoveredTab == index {
            drawCloseGlyph(in: closeRect(rect), emphasised: hoveredClose == index)
        }
    }

    private func drawEditedDot(in box: NSRect) {
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
    /// tabs you are not reading. Inactive tabs also draw their title at 0.55 alpha, so
    /// without the halo a coloured dot on a dim tab is the quietest thing in the strip
    /// rather than the loudest.
    ///
    /// Survives PR #5's compression unchanged, and that is a property of `box`, not
    /// luck: both the dot and the halo are measured from `closeRect`, whose 15pt side
    /// is fixed furniture that `minTabWidth`'s derivation reserves in full at the 56pt
    /// floor — the title is what gets elided there, never this box. So the 7pt dot
    /// inside a 12pt halo reads identically on a 56pt tab and a 210pt one; the tab
    /// around it is narrower, which if anything raises the marker's share of the ink.
    private func drawStatusDot(in box: NSRect, colour: NSColor, isActive: Bool) {
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

    private func drawCloseGlyph(in box: NSRect, emphasised: Bool) {
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

    private func drawNewButton(_ layout: Layout) {
        let rect = newButtonRect(layout)
        if isHoveringNewButton {
            hoverBackground.setFill()
            rect.fill()
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
    private func drawOverflowButton(in rect: NSRect) {
        if isHoveringOverflowButton {
            hoverBackground.setFill()
            rect.fill()
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

private extension NSRect {
    /// The parts of `self` left over once `excluded` is removed horizontally.
    /// Used to draw the strip's baseline everywhere except under the active tab.
    func slices(excluding excluded: NSRect) -> [NSRect] {
        guard !excluded.isEmpty, excluded.maxX > minX, excluded.minX < maxX else { return [self] }
        var result: [NSRect] = []
        if excluded.minX > minX {
            result.append(NSRect(x: minX, y: minY, width: excluded.minX - minX, height: height))
        }
        if excluded.maxX < maxX {
            result.append(NSRect(x: excluded.maxX, y: minY, width: maxX - excluded.maxX, height: height))
        }
        return result
    }
}
