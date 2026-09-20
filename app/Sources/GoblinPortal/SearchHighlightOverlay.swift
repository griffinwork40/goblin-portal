//
//  SearchHighlightOverlay.swift
//  Draws translucent rectangles at every search match position in the terminal.
//
//  A transparent NSView layered above GoblinPortalTerminalView.  It receives
//  match positions (buffer-absolute row/col/size tuples from SwiftTerm's
//  `findAllMatchPositions`) and the terminal's scroll offset + cell dimensions,
//  then paints a rounded rect at each visible match.  The current (selected)
//  match is drawn with a brighter, outlined treatment so it stands out from
//  the rest.
//
//  Deliberately separate from the terminal view's own draw pass: patching
//  SwiftTerm's `buildAttributedString` to inject a second highlight colour
//  would be correct but fragile (it touches the hot path, the patch touches
//  a file already carrying three local patches, and re-vendoring would be
//  expensive).  An overlay view is zero vendor cost and composites at the
//  window-server level, which is fast enough for 1000 rects on every
//  modern Mac.
//
//  Hit testing is disabled (`hitTest` returns nil) so clicks pass through
//  to the terminal view underneath.

import AppKit

@MainActor
final class SearchHighlightOverlay: NSView {
    // MARK: - Match data

    /// Buffer-absolute match positions: (row, col, size).
    /// Set by the terminal view's `searchStateDidChange` override.
    var matches: [(row: Int, col: Int, size: Int)] = [] {
        didSet { needsDisplay = true }
    }

    /// Zero-based index of the currently selected (active) match in the
    /// `matches` array, so it can be drawn differently from the rest.
    /// Negative or out-of-range means no active match.
    var activeMatchIndex: Int = -1 {
        didSet { needsDisplay = true }
    }

    // MARK: - Geometry inputs (set by the owning TerminalPane)

    /// Pixel size of one terminal cell.
    var cellSize: CGSize = .zero

    /// The first buffer-absolute row currently visible at the top of the
    /// viewport (= `terminal.displayBuffer.yDisp`).
    var scrollOffset: Int = 0

    /// Number of visible rows in the terminal viewport.
    var visibleRows: Int = 0

    // MARK: - Appearance

    /// Fill colour for non-active matches.
    private let matchFill = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 0.30)

    /// Fill colour for the active (current) match.
    private let activeFill = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.0, alpha: 0.50)

    /// Border colour for the active match.
    private let activeBorder = NSColor(calibratedRed: 1.0, green: 0.65, blue: 0.0, alpha: 0.85)

    /// Corner radius for highlight rects.
    private let cornerRadius: CGFloat = 2.0

    // MARK: - NSView overrides

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard cellSize.width > 0, cellSize.height > 0 else { return }

        let lastVisibleRow = scrollOffset + visibleRows - 1

        for (i, match) in matches.enumerated() {
            // Skip matches entirely outside the viewport.
            guard match.row >= scrollOffset, match.row <= lastVisibleRow else { continue }

            let rect = rectForMatch(match)
            guard dirtyRect.intersects(rect) else { continue }

            let isActive = (i == activeMatchIndex)

            if isActive {
                activeFill.setFill()
                let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
                path.fill()
                activeBorder.setStroke()
                path.lineWidth = 1.0
                path.stroke()
            } else {
                matchFill.setFill()
                NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            }
        }
    }

    // MARK: - Coordinate mapping

    /// Convert a buffer-absolute match to a view-local rect.
    ///
    /// The terminal view (and this overlay's parent) uses AppKit's default
    /// coordinate system: origin at bottom-left, Y increasing upward.
    /// `calcLineOffset` in SwiftTerm (`AppleTerminalView.swift:1262`) maps
    /// row N to `cellHeight * (N - yDisp + 1)` from the bottom, and the
    /// line origin is `frame.height - lineOffset`.  We replicate that math.
    private func rectForMatch(_ match: (row: Int, col: Int, size: Int)) -> NSRect {
        let viewportRow = match.row - scrollOffset
        // Y from bottom: row 0 of viewport is at the TOP of the view.
        let lineOffset = cellSize.height * CGFloat(viewportRow + 1)
        let y = bounds.height - lineOffset

        let x = cellSize.width * CGFloat(match.col)
        let w = cellSize.width * CGFloat(match.size)

        return NSRect(x: x, y: y, width: w, height: cellSize.height)
    }
}
