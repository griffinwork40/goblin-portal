//
//  GoblinPortalTerminalView+SearchOverlay.swift
//  Search-highlight overlay geometry management — extracted here to keep
//  GoblinPortalTerminalView.swift under the 350-LOC ceiling.
//
//  WHY SEPARATE. `GoblinPortalTerminalView.swift` held the search overlay inline at 347 LOC,
//  3 lines from the ceiling, and was the next planned addition point. The geometry-management
//  methods form a self-contained concern: deriving cell size from bounds and grid dimensions,
//  keeping the overlay frame in sync after scrolls and resizes, and lazily creating the overlay
//  on the first search. `searchStateDidChange` stays in the class because it overrides a Swift
//  `open` method (`MacTerminalView.searchStateDidChange`), and Swift disallows overriding a
//  non-dynamic Swift class method from an extension. The stored properties that anchor this
//  concern (`searchOverlay`, `lastSearchTerm`, `lastSearchOptions`) likewise stay in the class,
//  as Swift extensions cannot carry stored properties. `layout()` is the one `override` here;
//  it works because `NSView.layout()` (Obj-C, dynamically dispatched) has no intermediate Swift
//  class override in `MacTerminalView` — the original method is the direct parent.
//

import AppKit
import SwiftTerm

extension GoblinPortalTerminalView {

    // MARK: - Cell geometry

    /// Cell size derived from view bounds and grid dimensions.
    /// `cellDimension` on `MacTerminalView` is internal, so we compute it.
    var terminalCellSize: CGSize {
        let terminal = getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return .zero }
        return CGSize(
            width: bounds.width / CGFloat(terminal.cols),
            height: bounds.height / CGFloat(terminal.rows)
        )
    }

    // MARK: - Overlay geometry

    /// Update the overlay geometry after a scroll or resize.  The overlay is
    /// a sibling view drawn independently, so it must be told when the
    /// viewport moves.  Called by `searchStateDidChange` (on every search-term change),
    /// by `draw(_:)` (on every terminal redraw), and by `layout()`.
    func updateSearchOverlayGeometry() {
        guard let overlay = searchOverlay, !overlay.matches.isEmpty else { return }
        let terminal = getTerminal()
        overlay.scrollOffset = terminal.buffer.yDisp
        overlay.visibleRows = terminal.rows
        overlay.cellSize = terminalCellSize
        if !lastSearchTerm.isEmpty {
            let summary = searchMatchSummary(lastSearchTerm, options: lastSearchOptions)
            overlay.activeMatchIndex = summary.index > 0 ? summary.index - 1 : -1
        }
        overlay.frame = bounds
        overlay.needsDisplay = true
    }

    /// `NSView.layout()` from Obj-C — overridable here because `MacTerminalView` does not
    /// interpose its own `layout()`, so this extension overrides the Obj-C declaration directly.
    /// Drives overlay re-sync after any resize or font change, and resyncs the smooth-scroll
    /// cell height for the same events (smooth-scroll state is in `+SmoothScroll.swift` but
    /// the height read belongs with the geometry pass that already runs here).
    override func layout() {
        super.layout()
        updateSearchOverlayGeometry()
        // Resync the smooth-scroll cell height: a resize or font change moves it, and
        // SwiftTerm's own `cellDimension` is internal, so derive it the same way.
        smoothScroll.cellHeight = terminalCellSize.height
    }

    // MARK: - Overlay lifecycle

    func ensureSearchOverlay() -> SearchHighlightOverlay {
        if let existing = searchOverlay { return existing }
        let overlay = SearchHighlightOverlay(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        searchOverlay = overlay
        return overlay
    }
}
