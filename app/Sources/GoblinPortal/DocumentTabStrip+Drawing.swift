//
//  DocumentTabStrip+Drawing.swift
//  The strip's draw pass: the rail, each tab (as a pill or a rectangle), the
//  hairline, and dispatch to the affordance helpers in `+Affordances.swift`.
//
//  The pill-tab rework (2026-09) changed the active tab and the hover state from
//  sharp rectangles to rounded pills (8pt corner radius). Three drawing-layer
//  consequences had to be addressed simultaneously:
//
//  1. **Accent line clipping.** The 2px accent line at the active tab's bottom was
//     a plain `NSRect.fill()`. With a pill, the line must be clipped to the pill
//     path or it bleeds past the rounded bottom corners into the rail.
//
//  2. **Hairline seam exclusion.** The old `slices(excluding:)` carved the hairline
//     around the active tab's *rectangular* bounds. A pill's bottom corners leave
//     gaps. The fix: clip the hairline drawing to the inverse of the pill path
//     using even-odd winding, so the hairline is excluded exactly where the pill
//     is — corners included.
//
//  3. **Tab separators.** The 1px separator between inactive tabs sat at `rect.minX`,
//     which falls inside the void left by an adjacent pill's rounded corner. With
//     pills the shape itself creates the visual boundary, so separators are removed
//     entirely — matching Safari, iTerm2's Tahoe style, and every other pill-tab UI.
//
//  The affordance drawings (dots, close glyph, buttons) moved to
//  `DocumentTabStrip+Affordances.swift` in the same commit — they are self-contained
//  helpers that paint INTO rects this file hands them, with no position logic of
//  their own. See that file's header for the split rationale.
//

import AppKit

extension DocumentTabStrip {
    // MARK: - Drawing

    /// The corner radius for pill-shaped tab fills (active and hover).
    ///
    /// 8pt is chosen to read as a deliberate pill on a 30pt strip without collapsing
    /// into a lozenge at the 56pt `minTabWidth` floor: at 56×30 the flat zone is
    /// 40×14pt, which still reads as a tab rather than a capsule. For reference,
    /// macOS 26 system tabs use 16–20pt on a taller bar; iTerm2's PSMTahoeTabStyle
    /// uses a similar 36pt bar with proportionally larger radii. 8pt on 30pt is the
    /// equivalent proportion.
    ///
    /// The radius is applied to ALL four corners, not just the top two. A tab with
    /// rounded top corners and square bottom corners looks like a tombstone; full
    /// rounding makes it a proper pill and is what every reference implementation
    /// (Safari, Terminal.app, iTerm2 Tahoe) ships.
    static let tabCornerRadius: CGFloat = 8

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

    var hoverBackground: NSColor {
        let toward: NSColor = contentIsDark ? .white : .black
        return contentBackground.blended(withFraction: 0.13, of: toward) ?? contentBackground
    }

    override func draw(_ dirtyRect: NSRect) {
        railBackground.setFill()
        bounds.fill()

        let layout = self.layout
        for index in layout.visible {
            drawTab(index, layout)
        }
        if let overflow = overflowButtonRect(layout) {
            drawOverflowButton(in: overflow)
        }
        drawNewButton(layout)

        // Hairline under the strip, excluded under the active tab's pill path.
        //
        // The old code used `NSRect.slices(excluding:)` which carved around the
        // tab's rectangular bounds. A pill's bottom corners leave gaps that the
        // rect-based exclusion cannot follow. The fix: draw the hairline full-width,
        // then clip it to the INVERSE of the active tab's pill path using even-odd
        // winding. The hairline is excluded exactly where the pill is — rounded
        // corners included — so the seam-removal contract ("no line between the
        // active tab and its content") holds for the pill shape.
        contentForeground.withAlphaComponent(0.12).setFill()
        let hairline = NSRect(x: 0, y: 0, width: bounds.width, height: 1)

        if let activeRect = tabRect(activeIndex, layout) {
            NSGraphicsContext.saveGraphicsState()
            let pill = NSBezierPath(
                roundedRect: activeRect, xRadius: Self.tabCornerRadius,
                yRadius: Self.tabCornerRadius)
            let clip = NSBezierPath(rect: bounds)
            clip.append(pill)
            clip.windingRule = .evenOdd
            clip.addClip()
            hairline.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // No active tab on screen (windowed out) — hairline runs full width.
            hairline.fill()
        }
    }

    private func drawTab(_ index: Int, _ layout: Layout) {
        guard let rect = tabRect(index, layout) else { return }
        let isActive = index == activeIndex
        let cr = Self.tabCornerRadius

        if isActive {
            // Pill fill: the active tab merges with the terminal content below.
            let pill = NSBezierPath(roundedRect: rect, xRadius: cr, yRadius: cr)
            contentBackground.setFill()
            pill.fill()

            // 2px accent line at the bottom of the pill, clipped to the pill path
            // so it follows the rounded corners instead of bleeding into the rail.
            // The colour is `contentAccent` (the theme's cursor colour, or the
            // system accent) — see `Config+Chrome.swift:effectiveAccent`.
            NSGraphicsContext.saveGraphicsState()
            pill.addClip()
            let accentLine = NSRect(
                x: rect.minX, y: rect.minY, width: rect.width, height: 2)
            contentAccent.setFill()
            accentLine.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if hoveredTab == index {
            // Hover pill: same radius, lighter fill.
            let pill = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 3), xRadius: cr - 1,
                yRadius: cr - 1)
            hoverBackground.setFill()
            pill.fill()
        }

        // Separators between inactive tabs are REMOVED with pill tabs. The pill
        // shape itself creates natural visual gaps between tabs — adding a 1px line
        // inside the gap left by adjacent rounded corners looks like a floating
        // artifact rather than a boundary. This matches Safari, iTerm2 Tahoe, and
        // Terminal.app on macOS 26, none of which draw separators between pill tabs.

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
        // point the × takes over — Safari's and VS Code's arrangement.
        //
        // Status joins the SAME box on the SAME rule. Two dots on one tab is a row
        // of indicator lights, and at the 56pt floor there is no room for a second
        // reserved slot. When a tab is both edited and asking for attention, status
        // wins the box.
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
}
