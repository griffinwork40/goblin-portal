//
//  SplitContainerView.swift
//  Manual frame-based split pane container: 1 or 2 child views separated by a
//  draggable 1px divider.
//
//  Its own file because this is a pure layout concern — it knows nothing about
//  documents, terminals, or the tab strip. SpaceDocument, SpaceViewController, and
//  DocumentAreaViewController are deliberately opaque to it: this view distributes
//  frames and tracks a divider drag, and that is the entirety of its job.
//
//  WHY NOT NSSplitView: NSSplitView expects Auto Layout. The terminal view ships with
//  autoresizingMask = [.width, .height] (TerminalPane.swift:89) and the whole app
//  deliberately avoids mixing a constraint-based parent with it —
//  DocumentAreaViewController.swift:21-25 documents that decision in full.
//
//  WHY NOT Auto Layout here: same reason. Mixing NSLayoutConstraint into a hierarchy
//  that has autoresizingMask children produces the layout ambiguity the doc comment
//  above warns against, and it is undebuggable in a project with no test target.
//

import AppKit

/// An NSView that holds 1 or 2 child views with a draggable 1px divider between them.
///
/// All layout is manual and frame-based. Autoresizing is disabled on the divider
/// (it is positioned by `layout()`) and on the children (the container sizes them
/// explicitly so they track the divider position). The container itself should have
/// autoresizingMask = [.width, .height] set by its owner.
@MainActor
final class SplitContainerView: NSView {

    // MARK: - Public types

    enum Direction { case horizontal, vertical }

    // MARK: - State

    private(set) var primaryView: NSView?
    private(set) var splitView: NSView?
    private(set) var direction: Direction = .horizontal

    /// Fraction of the container given to the primary pane, 0…1. Clamped so
    /// each pane has at least minPaneSize points. Updated by dragging the divider.
    private var dividerRatio: CGFloat = 0.5

    /// 1px divider view, coloured to hint at the split without drawing a heavy chrome.
    private let dividerView = NSView()

    /// Called when a mouse-down event lands inside one of the child panes — reports
    /// which child received the click so the owner can update focus-dependent state
    /// (e.g. split-pane dimming). Fired BEFORE the event reaches the child, so the
    /// owner can update alpha before the pane renders the caret blink.
    ///
    /// Not part of the layout concern this view owns, but there is no clean place to
    /// intercept a click that lands on a child without sitting at this level: NSView
    /// event routing delivers mouseDown to the deepest hit-tested descendant, and the
    /// child pane (SwiftTerm or GhosttyKit) does not report upward. A closure here
    /// costs nothing when nil (the unsplit case and any owner that does not set it).
    var didReceiveClickInChild: ((_ child: NSView) -> Void)?

    /// Drag bookkeeping — nil when no drag is in progress.
    private var dragStartPoint: NSPoint?

    /// Minimum size each pane must stay at, so the divider cannot be dragged to
    /// collapse a pane entirely. 100pt matches a typical terminal column minimum.
    private static let minPaneSize: CGFloat = 100

    /// How close the cursor must be to the divider to start a drag (±3pt either side).
    private static let dividerHitSlop: CGFloat = 3

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Divider auto-layout off: layout() positions it every frame.
        dividerView.autoresizingMask = []
        dividerView.wantsLayer = true
        // 20% opaque neutral grey — visible against any terminal theme without
        // drawing attention away from the content. Matches the "theme foreground at
        // 20% opacity" guidance in the design doc; using a fixed neutral grey means
        // no theme dependency and no color lookup in this layout-only view.
        dividerView.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        addSubview(dividerView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — created programmatically")
    }

    // MARK: - API

    /// Replace the primary child (unsplit mode). The existing split view, if any,
    /// is NOT removed — call `removeSplit()` first if you want to collapse it.
    func setPrimary(_ view: NSView) {
        primaryView?.removeFromSuperview()
        primaryView = view
        // Disable autoresizing — this container owns all frame distribution in layout()
        // and the terminal view's autoresizingMask ([.width, .height] from TerminalPane.swift:89)
        // would fight with explicit frames in split mode. layout() corrects after every
        // container resize, so autoresizing buys nothing and costs consistency.
        view.autoresizingMask = []
        addSubview(view)
        needsLayout = true
        layout()
    }

    /// Add a split peer alongside the primary. Calling this twice is a no-op if
    /// already split — v1 supports exactly one split.
    func addSplit(_ view: NSView, direction: Direction) {
        guard splitView == nil else { return }
        self.direction = direction
        splitView = view
        view.autoresizingMask = []  // container owns the frame, not autoresizing
        addSubview(view)
        dividerRatio = 0.5
        needsLayout = true
        layout()
    }

    /// Remove the split peer and its view from the hierarchy. Returns the removed
    /// view (still valid, just detached). Returns nil if not currently split.
    @discardableResult
    func removeSplit() -> NSView? {
        guard let peer = splitView else { return nil }
        splitView = nil
        peer.removeFromSuperview()
        needsLayout = true
        layout()
        window?.invalidateCursorRects(for: self)  // clear the resize cursor
        return peer
    }

    var isSplit: Bool { splitView != nil }

    /// Replace a child (primary or split) with a different view. Used when a leaf
    /// is itself being split: its slot becomes a nested SplitContainerView holding
    /// the original leaf plus a new peer. Returns false if `old` is not a child.
    @discardableResult
    func replaceChild(_ old: NSView, with replacement: NSView) -> Bool {
        replacement.autoresizingMask = []
        if primaryView === old {
            old.removeFromSuperview()
            primaryView = replacement
            addSubview(replacement)
            needsLayout = true
            layout()
            return true
        }
        if splitView === old {
            old.removeFromSuperview()
            splitView = replacement
            addSubview(replacement)
            needsLayout = true
            layout()
            return true
        }
        return false
    }

    /// Update pane dimming so the focused child is fully opaque and the other is
    /// drawn at `opacity`.
    ///
    /// WHY alphaValue: it is the AppKit idiomatic way to fade an entire view subtree
    /// without modifying any child. The value propagates through the layer hierarchy
    /// automatically — no per-pane knowledge needed, and both engine backends (SwiftTerm
    /// and GhosttyKit) are opaque to this view, so this is the only approach that works
    /// without naming either.
    ///
    /// WHY NSAnimationContext: a 150ms ease-in-out makes the transition readable without
    /// drawing attention to itself — the same duration Core Animation uses for implicit
    /// property animations. Skipped when `opacity == 1.0` (no dimming configured) to
    /// keep the common case free of animation overhead entirely.
    ///
    /// Only has effect when split (`splitView != nil`). When unsplit, the primary is
    /// always 1.0 and `focusedChild` is ignored. When split but `focusedChild` is nil
    /// (no pane has focus yet), both are treated as unfocused and both dim — the less
    /// surprising reset compared to an arbitrary "primary wins".
    func setFocusedChild(_ focusedChild: NSView?, opacity: CGFloat) {
        guard let primary = primaryView else { return }
        guard let peer = splitView else {
            // Unsplit — ensure the primary is always fully visible.
            primary.alphaValue = 1.0
            return
        }

        let primaryAlpha: CGFloat
        let peerAlpha: CGFloat
        if let focused = focusedChild {
            primaryAlpha = (focused === primary) ? 1.0 : opacity
            peerAlpha    = (focused === peer)    ? 1.0 : opacity
        } else {
            // No identified focus — dim both rather than guessing which one wins.
            primaryAlpha = opacity
            peerAlpha    = opacity
        }

        if opacity < 1.0 {
            // 150ms ease: perceptible enough to feel intentional, fast enough not to
            // feel like a system-level repaint is racing the keypress.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                primary.animator().alphaValue = primaryAlpha
                peer.animator().alphaValue    = peerAlpha
            }
        } else {
            // opacity == 1.0: no dimming configured — skip animation entirely so
            // there is zero visual difference from a pre-feature build.
            primary.alphaValue = 1.0
            peer.alphaValue    = 1.0
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let b = bounds
        guard let primary = primaryView else { return }

        if let peer = splitView {
            // Clamp the ratio so both panes keep at least minPaneSize.
            let available = direction == .horizontal ? b.width : b.height
            let minRatio = Self.minPaneSize / max(available, 1)
            let maxRatio = max(1 - minRatio, minRatio)  // floor: window too narrow to fit both
            let ratio = min(max(dividerRatio, minRatio), maxRatio)

            switch direction {
            case .horizontal:
                // Non-flipped coordinates: x=0 is LEFT. Primary is on the left.
                let leftWidth = (b.width * ratio).rounded(.down)
                let rightX = leftWidth + 1  // 1pt divider
                let rightWidth = max(b.width - rightX, 0)  // floor at 0 for very narrow windows
                primary.frame = NSRect(x: 0, y: 0, width: leftWidth, height: b.height)
                dividerView.frame = NSRect(x: leftWidth, y: 0, width: 1, height: b.height)
                peer.frame = NSRect(x: rightX, y: 0, width: rightWidth, height: b.height)

            case .vertical:
                // Non-flipped: y=0 is BOTTOM. Primary is on the bottom (near the tab
                // strip at the top — so the "primary" document is below the peer).
                // This matches the plan doc's "primary gets bottom half" note.
                let bottomHeight = (b.height * ratio).rounded(.down)
                let topY = bottomHeight + 1
                let topHeight = max(b.height - topY, 0)
                primary.frame = NSRect(x: 0, y: 0, width: b.width, height: bottomHeight)
                dividerView.frame = NSRect(x: 0, y: bottomHeight, width: b.width, height: 1)
                peer.frame = NSRect(x: 0, y: topY, width: b.width, height: topHeight)
            }

            dividerView.isHidden = false
        } else {
            // Unsplit: primary fills the whole container.
            primary.frame = b
            dividerView.isHidden = true
        }
    }

    // MARK: - Divider dragging

    /// Convert an event point to our local coordinate space and check whether it
    /// falls within the hit-slop band around the divider.
    private func isNearDivider(_ point: NSPoint) -> Bool {
        guard isSplit else { return false }
        let divFrame = dividerView.frame
        switch direction {
        case .horizontal:
            return abs(point.x - divFrame.midX) <= Self.dividerHitSlop
        case .vertical:
            return abs(point.y - divFrame.midY) <= Self.dividerHitSlop
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isNearDivider(point) {
            dragStartPoint = point
        } else {
            // Not a divider drag — find which child was clicked and report it.
            // The event still travels to the child via super.mouseDown; the callback
            // fires first so the owner can update dimming before the pane draws focus.
            if let callback = didReceiveClickInChild, let child = hitChild(at: point) {
                callback(child)
            }
            super.mouseDown(with: event)
        }
    }

    /// Return the primary or split child whose frame contains `point`, or nil if
    /// neither does (e.g. the 1pt divider strip itself).
    private func hitChild(at point: NSPoint) -> NSView? {
        if let primary = primaryView, primary.frame.contains(point) { return primary }
        if let peer = splitView, peer.frame.contains(point) { return peer }
        return nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        let delta: CGFloat
        let available: CGFloat
        switch direction {
        case .horizontal:
            delta = current.x - start.x
            available = bounds.width
        case .vertical:
            delta = current.y - start.y
            available = bounds.height
        }
        guard available > 0 else { return }
        let lo = Self.minPaneSize / available
        let hi = max(1 - lo, lo)  // mirrors layout()'s guard: handles available < 2*minPaneSize
        dividerRatio = (dividerRatio + delta / available).clamped(to: lo...hi)
        dragStartPoint = current
        needsLayout = true
        layout()
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        super.mouseUp(with: event)
    }

    /// Change the cursor to a resize arrow when hovering over the divider.
    override func resetCursorRects() {
        guard isSplit else { return }
        let cursor: NSCursor = direction == .horizontal
            ? .resizeLeftRight : .resizeUpDown
        // Expand the divider frame by the slop on each side for a comfortable target.
        var hitRect = dividerView.frame
        if direction == .horizontal {
            hitRect = hitRect.insetBy(dx: -Self.dividerHitSlop, dy: 0)
        } else {
            hitRect = hitRect.insetBy(dx: 0, dy: -Self.dividerHitSlop)
        }
        addCursorRect(hitRect, cursor: cursor)
    }
}

// MARK: - Comparable clamping helper (no Foundation dependency)

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
