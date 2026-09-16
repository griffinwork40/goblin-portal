//
//  SpaceViewController+Splits.swift
//  The model half of split panes: creating and closing a split, tracking per-tab
//  split peer documents, and wiring the container to show/hide the split view.
//
//  v2 scope: up to TWO levels of split per tab (4 panes / quarters). The outer
//  split divides the tab into two halves; either half may itself be split into two
//  sub-panes inside a nested SplitContainerView. The nesting is compositional --
//  each SplitContainerView still holds exactly 2 children and handles its own
//  divider drag independently. Depth is capped at 2 (max 4 panes per tab).
//
//  ⌘⇧\ splits the focused pane horizontally; ⌘⇧- splits it vertically. ⌘W when
//  split collapses the focused sub-pane first, then the outer split. The tab strip
//  stays 1:1 with documents[] -- split peers never appear as tabs.
//

import AppKit

extension SpaceViewController {

    // MARK: - Split creation

    @objc func splitHorizontal(_ sender: Any?) { makeSplit(direction: .horizontal) }
    @objc func splitVertical(_ sender: Any?) { makeSplit(direction: .vertical) }

    /// Split the focused pane in the given direction.
    ///
    /// Three cases:
    /// 1. No split yet: create the outer split (primary + peer).
    /// 2. Outer split exists, focused pane has no sub-split: create a sub-split
    ///    inside the focused half, nesting a new SplitContainerView.
    /// 3. Depth 2 already reached on the focused pane: no-op.
    private func makeSplit(direction: SplitContainerView.Direction) {
        guard let primary = activeDocument, primary is ShellHosting else { return }

        if !hasSplit(for: primary) {
            // Case 1: no split yet -- create the outer split.
            makeOuterSplit(primary: primary, direction: direction)
        } else if let entry = splitPeers[ObjectIdentifier(primary)] {
            // Case 2/3: outer split exists -- try to sub-split the focused pane.
            makeSubSplit(primary: primary, entry: entry, direction: direction)
        }
    }

    /// Case 1: Create the initial outer split for a tab.
    private func makeOuterSplit(primary: SpaceDocument, direction: SplitContainerView.Direction) {
        let peerDirectory = (primary as? ShellHosting)?.currentDirectory ?? root
        let frame = documentArea.container.bounds
        let peer: SpaceDocument = TerminalPane(
            config: config, frame: frame, workingDirectory: peerDirectory)
        (peer as? any SpaceDocumentReporting)?.documentDelegate = self

        splitPeers[ObjectIdentifier(primary)] = SplitEntry(
            document: peer, direction: direction)
        (peer as? TerminalPane)?.start()

        documentArea.presentSplit(
            primaryView: primary.documentView,
            splitView: peer.documentView,
            direction: direction)

        installClickCallback(primary: primary)
        updateSplitDimming(for: primary)
    }

    /// Case 2: Sub-split the focused pane inside an existing outer split.
    private func makeSubSplit(
        primary: SpaceDocument, entry: SplitEntry,
        direction: SplitContainerView.Direction
    ) {
        let fr = view.window?.firstResponder
        let peerHasFocus = isDescendant(fr, of: entry.document.documentView)

        // Check depth: is the focused half already sub-split?
        if peerHasFocus && entry.peerSubSplit != nil { return }
        if !peerHasFocus && entry.primarySubSplit != nil { return }

        // The focused document is the one whose pane will be split.
        let focusedDoc: SpaceDocument = peerHasFocus ? entry.document : primary
        let focusedView = focusedDoc.documentView
        let peerDirectory = (focusedDoc as? ShellHosting)?.currentDirectory ?? root
        let newPeer = TerminalPane(
            config: config, frame: focusedView.bounds, workingDirectory: peerDirectory)
        (newPeer as? any SpaceDocumentReporting)?.documentDelegate = self

        // Create a nested SplitContainerView to hold the original pane + new peer.
        let nested = SplitContainerView(frame: focusedView.frame)
        nested.autoresizingMask = []

        // Find the parent container that holds focusedView and swap it.
        let parentContainer = focusedView.superview as? SplitContainerView ?? documentArea.container
        parentContainer.replaceChild(focusedView, with: nested)
        nested.setPrimary(focusedView)
        nested.addSplit(newPeer.documentView, direction: direction)

        // Register in splitPeers before starting the shell.
        let subSplit = SplitEntry.SubSplit(
            document: newPeer, container: nested, direction: direction)
        var updated = entry
        if peerHasFocus { updated.peerSubSplit = subSplit }
        else { updated.primarySubSplit = subSplit }
        splitPeers[ObjectIdentifier(primary)] = updated

        newPeer.start()

        // Install click callbacks on the nested container too.
        let capturedPrimary = primary
        nested.didReceiveClickInChild = { [weak self] _ in
            guard let self else { return }
            self.updateSplitDimming(for: capturedPrimary)
        }

        updateSplitDimming(for: primary)
    }

    // MARK: - Split closing

    /// Collapse the focused sub-pane, or the outer split if no sub-split is focused.
    ///
    /// ⌘W routing: closeActiveDocument() calls this when the active tab has a split.
    /// In v2, ⌘W removes the focused leaf one level at a time -- sub-pane first,
    /// then the outer split on the next ⌘W.
    func closeSplitPane() {
        guard let primary = activeDocument,
              var entry = splitPeers[ObjectIdentifier(primary)] else { return }

        let fr = view.window?.firstResponder

        // Check if the focused responder is inside a sub-split. If so, collapse
        // that sub-split rather than the whole outer split.
        if let sub = entry.peerSubSplit,
           isDescendant(fr, of: sub.container) {
            collapseSubSplit(primary: primary, entry: &entry, side: .peer)
            splitPeers[ObjectIdentifier(primary)] = entry
            updateSplitDimming(for: primary)
            return
        }
        if let sub = entry.primarySubSplit,
           isDescendant(fr, of: sub.container) {
            collapseSubSplit(primary: primary, entry: &entry, side: .primary)
            splitPeers[ObjectIdentifier(primary)] = entry
            updateSplitDimming(for: primary)
            return
        }

        // No sub-split focused -- collapse the outer split entirely.
        // First tear down any sub-splits.
        teardownSubSplits(entry: &entry)
        splitPeers.removeValue(forKey: ObjectIdentifier(primary))
        entry.document.documentWillClose()
        documentArea.dismissSplit()
        documentArea.container.didReceiveClickInChild = nil
        documentArea.container.setFocusedChild(nil, opacity: 1.0)
        primary.documentDidBecomeActive()
    }

    private enum SubSplitSide { case primary, peer }

    /// Collapse one sub-split, promoting the surviving pane back to its parent slot.
    private func collapseSubSplit(
        primary: SpaceDocument, entry: inout SplitEntry, side: SubSplitSide
    ) {
        let sub: SplitEntry.SubSplit
        let survivingDoc: SpaceDocument

        switch side {
        case .peer:
            guard let s = entry.peerSubSplit else { return }
            sub = s
            survivingDoc = entry.document
            entry.peerSubSplit = nil
        case .primary:
            guard let s = entry.primarySubSplit else { return }
            sub = s
            survivingDoc = primary
            entry.primarySubSplit = nil
        }

        sub.document.documentWillClose()
        sub.container.removeSplit()
        sub.container.didReceiveClickInChild = nil

        // Replace the nested container with the surviving pane's view.
        // replaceChild removes the old view from the hierarchy, so no separate
        // removeFromSuperview is needed.
        let parentContainer = sub.container.superview as? SplitContainerView
            ?? documentArea.container
        parentContainer.replaceChild(sub.container, with: survivingDoc.documentView)

        survivingDoc.documentDidBecomeActive()
    }

    // MARK: - Queries

    func splitPeer(for document: SpaceDocument) -> SpaceDocument? {
        splitPeers[ObjectIdentifier(document)]?.document
    }

    func hasSplit(for document: SpaceDocument) -> Bool {
        splitPeers[ObjectIdentifier(document)] != nil
    }

    /// Whether the focused pane can accept another split (depth < 2).
    func canSplitFocusedPane(for primary: SpaceDocument) -> Bool {
        guard let entry = splitPeers[ObjectIdentifier(primary)] else { return true }
        let fr = view.window?.firstResponder
        let peerHasFocus = isDescendant(fr, of: entry.document.documentView)
        if peerHasFocus { return entry.peerSubSplit == nil }
        return entry.primarySubSplit == nil
    }

    /// All peer documents for a primary (main peer + any sub-split peers).
    func allSplitDocuments(for primary: SpaceDocument) -> [SpaceDocument] {
        splitPeers[ObjectIdentifier(primary)]?.allPeerDocuments ?? []
    }

    // Focus movement (⌘⇧H/J/K/L) and leaf gathering live in
    // SpaceViewController+SplitFocus.swift — extracted at the 350-LOC ceiling.

    // MARK: - Peer-initiated termination

    func terminateSplitPeer(_ document: SpaceDocument) {
        for primary in documents {
            guard var entry = splitPeers[ObjectIdentifier(primary)] else { continue }

            // Check sub-splits first.
            if entry.primarySubSplit?.document === document {
                collapseSubSplit(primary: primary, entry: &entry, side: .primary)
                splitPeers[ObjectIdentifier(primary)] = entry
                return
            }
            if entry.peerSubSplit?.document === document {
                collapseSubSplit(primary: primary, entry: &entry, side: .peer)
                splitPeers[ObjectIdentifier(primary)] = entry
                return
            }

            // Main peer exiting: tear down the whole split.
            guard entry.document === document else { continue }
            teardownSubSplits(entry: &entry)
            splitPeers.removeValue(forKey: ObjectIdentifier(primary))
            document.documentWillClose()
            documentArea.dismissSplit()
            documentArea.container.didReceiveClickInChild = nil
            documentArea.container.setFocusedChild(nil, opacity: 1.0)
            primary.documentDidBecomeActive()
            return
        }
    }

    // MARK: - Teardown

    func teardownSplit(for document: SpaceDocument) {
        guard var entry = splitPeers.removeValue(forKey: ObjectIdentifier(document)) else { return }
        teardownSubSplits(entry: &entry)
        entry.document.documentWillClose()
        documentArea.dismissSplit()
        documentArea.container.didReceiveClickInChild = nil
        documentArea.container.setFocusedChild(nil, opacity: 1.0)
    }

    /// Close all sub-split peers in an entry. Called before tearing down the outer split.
    ///
    /// Does NOT replaceChild -- the outer split is dismissed right after, so the
    /// nested container just needs to release its documents and be removed. Putting
    /// a zombie view into the outer container (then immediately dismissing it) was
    /// the cause of Bug #1 in the audit.
    private func teardownSubSplits(entry: inout SplitEntry) {
        if let sub = entry.primarySubSplit {
            sub.container.removeSplit()
            sub.document.documentWillClose()
            sub.container.didReceiveClickInChild = nil
            sub.container.removeFromSuperview()
            entry.primarySubSplit = nil
        }
        if let sub = entry.peerSubSplit {
            sub.container.removeSplit()
            sub.document.documentWillClose()
            sub.container.didReceiveClickInChild = nil
            sub.container.removeFromSuperview()
            entry.peerSubSplit = nil
        }
    }

    // Presentation, dimming, and click callbacks live in
    // SpaceViewController+SplitPresentation.swift — extracted at the 350-LOC ceiling.
}
