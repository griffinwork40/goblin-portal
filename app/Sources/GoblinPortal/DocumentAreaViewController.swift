//
//  DocumentAreaViewController.swift
//  The right-hand region of a Space: document tab strip on top, active document below.
//
//  Its own file because this is a second view controller, not a helper — it owns a
//  view hierarchy, a manual layout pass, and the strip's visibility rule, none of
//  which is about managing a document list. It was nested and `private` inside
//  `SpaceViewController.swift` only because it had nowhere else to live; the 350-LOC
//  ceiling supplied the reason to give it one (AFK.md, "Conventions"). The dependency
//  runs one way — the container drives this, this knows nothing about
//  `SpaceViewController` or `SpaceDocument` — so adding a document kind still never
//  reaches here.
//

import AppKit

// MARK: - Document area

/// The right-hand region: tab strip on top, active document filling the rest.
///
/// Laid out manually in `viewDidLayout` rather than with Auto Layout. The document
/// view is a SwiftTerm view that already ships with `autoresizingMask =
/// [.width, .height]` (`TerminalPane.swift:49`) and is sized by frame everywhere
/// else in this app; mixing a constraint-based parent into that is how a terminal
/// ends up one row short.
@MainActor
// Internal rather than `private`: it was `private` as a nested type, and moving it
// to its own file makes that unrepresentable — `SpaceViewController` holds one as a
// stored property, and a file-scoped `private` type cannot be named from another
// file. Internal is the narrowest level that compiles. Nothing outside
// `SpaceViewController` constructs one, and it is not `public`.
final class DocumentAreaViewController: NSViewController {
    let strip = DocumentTabStrip(frame: .zero)
    // SplitContainerView rather than a plain NSView: it holds 1 or 2 child views
    // with a draggable divider, using the same manual frame-based layout this file
    // already uses — no Auto Layout, no NSSplitView (see the header comment above).
    let container = SplitContainerView()

    private var isStripVisible = false

    // MARK: - Terminal padding

    /// Inset applied to the terminal container so content has breathing room from the
    /// window edges. The gap is filled by `paddingBackdrop`, coloured to match the
    /// terminal background for a seamless appearance (no visible border or letterbox).
    ///
    /// Zero by default and set to zero again when a non-terminal document is presented
    /// (`setTerminalPadding(_:backgroundColor:)` called with (0,0) from
    /// `SpaceViewController.selectDocument`), so `FileViewerPane` is never affected.
    ///
    /// Stored as (x:y:) rather than NSEdgeInsets because terminal padding is always
    /// symmetric — applying different insets to the leading vs trailing side would
    /// shift the terminal off-centre with no user-visible benefit.
    private var terminalPadding: (x: CGFloat, y: CGFloat) = (0, 0)

    /// A view behind the container that fills the full document area. When padding is
    /// active, the portion not covered by the container shows this view's background,
    /// which is set to the terminal's own background colour — making the inset
    /// invisible to the eye (the terminal "floats" in a same-colour void).
    ///
    /// Using a separate backdrop rather than colouring the root view directly keeps
    /// the backdrop out of the responder chain and avoids fighting the sidebar
    /// material's bleed-through, which sits behind this file's root NSView.
    private let paddingBackdrop: NSView = {
        let v = NSView()
        v.wantsLayer = true
        return v
    }()

    /// Update the terminal padding and backdrop colour for the newly-active document.
    ///
    /// Call this from `SpaceViewController.selectDocument(at:)` whenever the active
    /// document changes. For non-terminal documents pass `(0, 0)` so no inset is
    /// applied. The backdrop colour should match the terminal's resolved background
    /// (`config.effectiveBackground`) so the inset area is seamless.
    func setTerminalPadding(_ padding: (x: CGFloat, y: CGFloat), backgroundColor: NSColor) {
        terminalPadding = padding
        paddingBackdrop.layer?.backgroundColor = backgroundColor.cgColor
        // Re-run layout immediately so the new inset takes effect on this frame
        // rather than waiting for the next resize — the same reasoning as the
        // `container.layout()` call at the end of `viewDidLayout`.
        view.needsLayout = true
        viewDidLayout()
    }

    override func loadView() {
        let root = NSView()
        // Backdrop first so it sits below the container in Z-order.
        root.addSubview(paddingBackdrop)
        root.addSubview(container)
        view = root
    }

    /// Hidden at a single document, matching Ghostty and Terminal.app: with one
    /// terminal open this app should still just look like a terminal, and the strip
    /// costs 30pt of rows that the primary surface would rather have. ⌘T brings it
    /// back the moment there is anything to switch between.
    func setStripVisible(_ visible: Bool) {
        guard visible != isStripVisible else { return }
        isStripVisible = visible
        if visible {
            view.addSubview(strip)
        } else {
            strip.removeFromSuperview()
        }
        view.needsLayout = true
        viewDidLayout()
    }

    /// Present a single document view, with no split. Delegates to the container's
    /// split-aware API so it stays the single authority on what is displayed.
    func present(documentView: NSView) {
        if container.isSplit { container.removeSplit() }
        container.setPrimary(documentView)
    }

    /// Present a two-pane split: primary on the left (or bottom for vertical).
    ///
    /// Called from SpaceViewController.selectDocument(at:) when the selected tab has
    /// a split peer. Clears any existing split first so switching between two split
    /// tabs does not leave a stale peer in the container.
    func presentSplit(
        primaryView: NSView, splitView: NSView,
        direction: SplitContainerView.Direction
    ) {
        if container.isSplit { container.removeSplit() }
        container.setPrimary(primaryView)
        container.addSplit(splitView, direction: direction)
    }

    /// Collapse the split, returning to single-pane display.
    ///
    /// Called from closeSplitPane(), teardownSplit(for:), and terminateSplitPeer(_:)
    /// in +Splits.swift. The container's removeSplit() removes the peer view from the
    /// hierarchy — that is the single owner of the removeFromSuperview call.
    func dismissSplit() {
        container.removeSplit()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let stripHeight = isStripVisible ? DocumentTabStrip.height : 0
        // Non-flipped coordinates: the strip is at the TOP, so it takes the high y.
        strip.frame = NSRect(
            x: 0, y: bounds.height - stripHeight, width: bounds.width, height: stripHeight)

        // The backdrop always fills the full area below the strip — it is the
        // base layer that shows the terminal background colour through the inset.
        let contentArea = NSRect(
            x: 0, y: 0, width: bounds.width, height: bounds.height - stripHeight)
        paddingBackdrop.frame = contentArea

        // Apply terminal padding as frame insets on the container. When padding is
        // zero (non-terminal documents, or padding disabled) the container fills the
        // full content area, exactly as before. The backdrop behind it is invisible
        // because the document view covers it entirely.
        let px = terminalPadding.x, py = terminalPadding.y
        container.frame = contentArea.insetBy(dx: px, dy: py)

        // Children are distributed by SplitContainerView.layout(). Call it
        // immediately rather than deferring via needsLayout so terminal rows/cols
        // are correct on the same pass that resized the container — deferred layout
        // would leave the terminal with a stale frame until the next run loop tick.
        container.layout()
    }
}
