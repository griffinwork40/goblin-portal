//
//  SpaceViewController+SplitFocus.swift
//  Focus movement between split panes (⌘⇧H/J/K/L), the spatial leaf-gathering
//  that drives it, and menu validation for split/focus items.
//
//  Extracted from SpaceViewController+Splits.swift at the 350-LOC ceiling.
//  `validateUserInterfaceItem` was moved here from `SpaceViewController.swift`
//  when that file hit the ceiling: it only validates split and focus selectors,
//  so it belongs with the split-focus concern rather than in the container.
//  This is the focus concern; the model (create/close) stays in +Splits.swift
//  and the display (dimming/presentation) stays in +SplitPresentation.swift.
//

import AppKit

extension SpaceViewController {

    // MARK: - Focus movement (tmux-inspired ⌘⇧H/J/K/L)

    @objc func moveFocusLeft(_ sender: Any?) { moveFocus(toward: .left) }
    @objc func moveFocusRight(_ sender: Any?) { moveFocus(toward: .right) }
    @objc func moveFocusUp(_ sender: Any?) { moveFocus(toward: .up) }
    @objc func moveFocusDown(_ sender: Any?) { moveFocus(toward: .down) }

    private enum FocusDirection { case left, right, up, down }

    /// Move keyboard focus between panes. Works for 2, 3, or 4 panes.
    ///
    /// Strategy: collect all leaf panes with their bounding rects in the outer
    /// container's coordinate space, find the focused one, then pick the nearest
    /// neighbour in the requested direction.
    private func moveFocus(toward direction: FocusDirection) {
        guard let primary = activeDocument,
              let entry = splitPeers[ObjectIdentifier(primary)] else { return }

        let leaves = gatherLeaves(primary: primary, entry: entry)
        guard leaves.count > 1 else { return }

        let fr = view.window?.firstResponder
        guard let focusedIdx = leaves.firstIndex(where: { isDescendant(fr, of: $0.view) })
        else { return }

        let focused = leaves[focusedIdx]
        if let target = bestNeighbour(of: focused, in: leaves, toward: direction) {
            target.document.documentDidBecomeActive()
            updateSplitDimming(for: primary)
        }
    }

    /// Pick the nearest leaf in the given direction based on bounding-rect geometry.
    /// Falls back to any other pane when no pane exists in that exact direction (wrap).
    private func bestNeighbour(
        of focused: LeafPane, in leaves: [LeafPane], toward dir: FocusDirection
    ) -> LeafPane? {
        let fc = NSPoint(x: focused.rect.midX, y: focused.rect.midY)
        var best: LeafPane?
        var bestDist = CGFloat.greatestFiniteMagnitude

        for leaf in leaves where leaf.view !== focused.view {
            let lc = NSPoint(x: leaf.rect.midX, y: leaf.rect.midY)
            let valid: Bool
            switch dir {
            case .left:  valid = lc.x < fc.x
            case .right: valid = lc.x > fc.x
            case .down:  valid = lc.y < fc.y  // non-flipped: lower y = below
            case .up:    valid = lc.y > fc.y
            }
            guard valid else { continue }
            let dist = hypot(lc.x - fc.x, lc.y - fc.y)
            if dist < bestDist { bestDist = dist; best = leaf }
        }
        return best
    }

    // MARK: - Leaf gathering

    struct LeafPane {
        let document: SpaceDocument
        let view: NSView
        let rect: NSRect  // in the outer container's coordinate space
    }

    /// Collect all leaf panes with their rects in the outer container's coordinate space.
    /// Used by focus movement and dimming to enumerate the visible panes.
    func gatherLeaves(primary: SpaceDocument, entry: SplitEntry) -> [LeafPane] {
        let coord = documentArea.container
        var leaves: [LeafPane] = []

        func addLeaf(_ doc: SpaceDocument) {
            let v = doc.documentView
            let r = v.convert(v.bounds, to: coord)
            leaves.append(LeafPane(document: doc, view: v, rect: r))
        }

        // Primary side
        addLeaf(primary)
        if let sub = entry.primarySubSplit { addLeaf(sub.document) }
        // Peer side
        addLeaf(entry.document)
        if let sub = entry.peerSubSplit { addLeaf(sub.document) }
        return leaves
    }

    // MARK: - Menu validation

    /// Gate split/focus menu items — without this, AppKit auto-enables every item whose
    /// @objc selector is answered, even when the action would silently no-op.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(splitHorizontal(_:)), #selector(splitVertical(_:)):
            guard let doc = activeDocument, doc is ShellHosting else { return false }
            return canSplitFocusedPane(for: doc)
        case #selector(moveFocusLeft(_:)), #selector(moveFocusRight(_:)),
             #selector(moveFocusUp(_:)), #selector(moveFocusDown(_:)):
            return activeDocument.map { hasSplit(for: $0) } ?? false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
