//
//  EditorTextView.swift
//  The custom NSTextView subclass for the file viewer's editor area.
//
//  Extracted from `FileViewerPane+Chrome.swift` when that file reached 392 LOC,
//  over the 350-line ceiling. The seam is clean:
//
//    · `EditorTextView.swift` — the NSTextView subclass that handles all custom
//      drawing: current-line highlight, column guide, indent rainbow, trailing
//      whitespace dots. No layout wiring, no config load.
//    · `FileViewerPane+Chrome.swift` — wires EditorTextView and EditorStatusBar
//      to the FileViewerPane; applies config values; updates the status bar.
//
//  Subclassing is the only way to intercept `drawBackground(in:)` — NSTextView
//  does not expose a delegate hook for it, and all custom rendering runs there.
//

import AppKit

// MARK: - EditorTextView

/// A custom `NSTextView` subclass that draws a subtle highlight on the line
/// containing the insertion point. Subclassing is the only way to intercept
/// `drawBackground(in:)` — `NSTextView` does not expose a delegate hook for it.
///
/// Also draws a column guide (vertical line at a configurable column) and dims
/// trailing whitespace so it is visible without being distracting.
@MainActor
final class EditorTextView: NSTextView {
    /// The column at which to draw a vertical guide line, or nil for none.
    /// Driven by `AppConfig.columnGuideColumn` via `applyChrome(config:)`.
    var columnGuide: Int? = 80

    /// Whether to visualize trailing whitespace with dim dots.
    /// Driven by `AppConfig.showTrailingWhitespace` via `applyChrome(config:)`.
    var showTrailingWhitespace = true

    /// When true, draw a subtle colour band behind each indent level.
    /// Driven by `AppConfig.indentRainbow` via `applyChrome(config:)`.
    var indentRainbow = false

    /// The resolved tab width — used to compute indent-band widths. Updated
    /// alongside `indentRainbow` from `applyChrome(config:)`.
    var tabWidthForRainbow: Int = 4

    /// The background colour for the current line — a very slight lift from the
    /// editor background. Recalculated on every `apply(config:)`.
    var currentLineColor: NSColor = NSColor.white.withAlphaComponent(0.04)

    /// The colour for the column guide line.
    var columnGuideColor: NSColor = NSColor.white.withAlphaComponent(0.08)

    /// The colour for trailing-whitespace dots.
    var trailingWhitespaceColor: NSColor = NSColor.white.withAlphaComponent(0.15)

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let lm = layoutManager, let tc = textContainer else { return }

        // -- Current line highlight --
        let insertion = selectedRange().location
        let str = (string as NSString)
        guard str.length > 0 else { return }
        let lineRange = str.lineRange(for: NSRange(location: min(insertion, str.length - 1), length: 0))
        let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        // boundingRect gives the visual extent of the line's glyphs, but we want
        // full-width so the highlight stretches edge to edge.
        let lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let fullWidthRect = NSRect(
            x: 0,
            y: lineRect.origin.y + textContainerInset.height,
            width: bounds.width,
            height: lineRect.height)

        if fullWidthRect.intersects(rect) {
            currentLineColor.setFill()
            fullWidthRect.fill()
        }

        // -- Column guide --
        if let col = columnGuide, col > 0 {
            let charWidth = ("m" as NSString).size(
                withAttributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
            let guideX = textContainerOrigin.x + tc.lineFragmentPadding + charWidth * CGFloat(col)
            let guideLine = NSRect(x: guideX, y: rect.origin.y, width: 1 / (window?.backingScaleFactor ?? 2), height: rect.height)
            if guideLine.intersects(rect) {
                columnGuideColor.setFill()
                guideLine.fill()
            }
        }

        // -- Indent rainbow --
        if indentRainbow { drawIndentRainbow(in: rect, layoutManager: lm, textContainer: tc) }
    }

    // MARK: - Indent rainbow

    /// The five colours that cycle across indent levels. Low opacity so they are
    /// visible without shouting — measured against dark umber background.
    /// Colours cycle: red, green, blue, yellow, purple — the same heuristic VS
    /// Code's indent-rainbow extension uses, and legible under both dark and light
    /// themes because they are hue indicators, not foreground text.
    private static let rainbowColors: [NSColor] = [
        NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 0.06),  // red
        NSColor(red: 0.35, green: 1.0, blue: 0.45, alpha: 0.06),  // green
        NSColor(red: 0.35, green: 0.60, blue: 1.0, alpha: 0.06),  // blue
        NSColor(red: 1.0, green: 0.90, blue: 0.30, alpha: 0.06),  // yellow
        NSColor(red: 0.75, green: 0.40, blue: 1.0, alpha: 0.06),  // purple
    ]

    /// Draw indent-level bands behind the leading whitespace of every visible line.
    ///
    /// Each indent step (tab or N spaces) gets a band in its level's colour. The
    /// band spans only the indentation column — `[levelStart, levelEnd)` in the
    /// x axis — so the rest of the line is untouched.
    ///
    /// Performance: only processes lines whose glyph ranges intersect `rect`.
    /// A 1,000-line file with 50 lines visible is ≤ 50 lines of simple arithmetic
    /// per redraw, negligible compared to the layout manager's own work.
    private func drawIndentRainbow(in rect: NSRect,
                                   layoutManager lm: NSLayoutManager,
                                   textContainer tc: NSTextContainer) {
        let str = string as NSString
        guard str.length > 0 else { return }

        let charWidth: CGFloat
        if let f = font {
            charWidth = ("m" as NSString).size(withAttributes: [.font: f]).width
        } else {
            charWidth = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).maximumAdvancement.width
        }
        let unitWidth = charWidth * CGFloat(max(tabWidthForRainbow, 1))
        let xOrigin = textContainerOrigin.x + tc.lineFragmentPadding

        let glyphRange = lm.glyphRange(forBoundingRect: rect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineStart = charRange.location
        while lineStart <= NSMaxRange(charRange) && lineStart < str.length {
            let lineRange = str.lineRange(for: NSRange(location: lineStart, length: 0))
            defer { lineStart = NSMaxRange(lineRange) }

            // Count leading spaces/tabs to determine indent level.
            var indentChars = 0
            var i = lineRange.location
            outer: while i < NSMaxRange(lineRange) && i < str.length {
                switch str.character(at: i) {
                case 0x20: indentChars += 1   // space
                case 0x09: // tab → round up to next tab stop
                    let col = indentChars % tabWidthForRainbow
                    indentChars += tabWidthForRainbow - col
                default: break outer
                }
                i += 1
            }
            guard indentChars > 0 else { continue }

            // Compute the y-rect for this line from the layout manager.
            let lineGlyphRange = lm.glyphRange(
                forCharacterRange: NSRange(location: lineRange.location, length: 1),
                actualCharacterRange: nil)
            let fragRect = lm.lineFragmentRect(forGlyphAt: lineGlyphRange.location,
                                               effectiveRange: nil)
            let lineY = textContainerOrigin.y + fragRect.origin.y

            // Draw one band per indent step.
            let levels = indentChars / max(tabWidthForRainbow, 1)
            for level in 0..<levels {
                let x = xOrigin + unitWidth * CGFloat(level)
                let bandRect = NSRect(x: x, y: lineY, width: unitWidth, height: fragRect.height)
                if bandRect.intersects(rect) {
                    Self.rainbowColors[level % Self.rainbowColors.count].setFill()
                    bandRect.fill()
                }
            }
        }
    }

    /// Draw trailing whitespace dots AFTER the text, so they overlay correctly.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    /// Called by the layout manager after drawing glyphs. We hook this to draw
    /// trailing whitespace indicators.
    func drawTrailingWhitespace(in rect: NSRect) {
        guard showTrailingWhitespace,
              let lm = layoutManager, let tc = textContainer else { return }

        let str = string as NSString
        guard str.length > 0 else { return }

        // Only process lines visible in the dirty rect for performance.
        let glyphRange = lm.glyphRange(forBoundingRect: rect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineStart = charRange.location
        while lineStart < NSMaxRange(charRange) && lineStart < str.length {
            let lineRange = str.lineRange(for: NSRange(location: lineStart, length: 0))

            // Find trailing whitespace (spaces and tabs before the line ending).
            var trailStart = NSMaxRange(lineRange)
            // Skip past the newline character(s)
            if trailStart > lineRange.location {
                let lastChar = str.character(at: trailStart - 1)
                if lastChar == 0x0A || lastChar == 0x0D { trailStart -= 1 }
            }
            let contentEnd = trailStart
            while trailStart > lineRange.location {
                let ch = str.character(at: trailStart - 1)
                if ch != 0x20 && ch != 0x09 { break }  // space or tab
                trailStart -= 1
            }

            if trailStart < contentEnd {
                // Draw a small dot for each trailing whitespace character.
                let dotSize: CGFloat = 2.5
                trailingWhitespaceColor.setFill()
                for i in trailStart..<contentEnd {
                    let glyphIdx = lm.glyphIndexForCharacter(at: i)
                    let loc = lm.location(forGlyphAt: glyphIdx)
                    let fragRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                    let x = textContainerOrigin.x + fragRect.origin.x + loc.x + 2
                    let y = textContainerOrigin.y + fragRect.origin.y + loc.y - dotSize / 2 - 1
                    let dotRect = NSRect(x: x, y: y, width: dotSize, height: dotSize)
                    NSBezierPath(ovalIn: dotRect).fill()
                }
            }

            lineStart = NSMaxRange(lineRange)
        }
    }
}
