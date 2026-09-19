//
//  SpaceViewController+SplitRestore.swift
//  The whole persistence concern for split panes: snapshotting, restoring, and
//  the ratio-capture discipline that keeps off-screen tabs correct.
//
//  Three sub-concerns live here:
//  1. Restore: replaying a `SplitSnapshot` into the view hierarchy at launch.
//  2. Snapshot: building a `SplitSnapshot` from the live `SplitEntry` state.
//  3. Ratio capture: keeping `outerDividerRatio` and `SubSplit.storedRatio` in
//     sync on every drag-end and tab-switch, so an off-screen tab's ratios
//     survive `presentSplitEntry`'s `addSplit` (which resets `dividerRatio`
//     to 0.5).
//
//  Called from `SpaceWindowController.openFirstDocument()` (restore),
//  `+Splits.swift` (persist on every create/close/terminate), and
//  `SpaceViewController.selectDocument(at:)` / `applyDocumentOrder` (ratio
//  capture on tab switch).
//

import AppKit

extension SpaceViewController {

    /// Replay a saved split snapshot onto the active document (tab 0).
    ///
    /// Preconditions: the Space has exactly one document (the restored terminal),
    /// and `layoutSubtreeIfNeeded()` has been called so the container has non-zero
    /// bounds. Both are guaranteed by the call site in `openFirstDocument()`.
    ///
    /// Fail-soft: any parsing failure, missing CWD, or unexpected state silently
    /// skips the restoration, leaving the Space with one fresh terminal.
    func restoreSplit(from snapshot: SplitSnapshot) {
        guard let primary = documents.first, primary is ShellHosting else { return }
        guard let outerDir = SplitContainerView.Direction(
            persistedName: snapshot.outerDirection
        ) else { return }

        // Build the outer peer, using the saved CWD if it still exists.
        let peerDir = validatedDirectory(snapshot.peerCwd)
        let frame = documentArea.container.bounds
        let peer = TerminalPane(
            config: config, frame: frame, workingDirectory: peerDir)
        (peer as? any SpaceDocumentReporting)?.documentDelegate = self

        var entry = SplitEntry(document: peer, direction: outerDir)
        // Mirror the saved ratio into the entry so that splitSnapshot reads the
        // correct value even for a tab that is not currently displayed (Item 1).
        entry.outerDividerRatio = CGFloat(snapshot.outerRatio)
        splitPeers[ObjectIdentifier(primary)] = entry
        peer.start()

        documentArea.presentSplit(
            primaryView: primary.documentView,
            splitView: peer.documentView,
            direction: outerDir)

        // Apply the saved outer divider ratio.
        documentArea.container.applyDividerRatio(CGFloat(snapshot.outerRatio))
        installClickCallback(primary: primary)
        installDividerDragCallback()

        // Restore sub-splits, if any.
        if let subSnap = snapshot.primarySubSplit {
            restoreSubSplit(subSnap, primary: primary, side: .primary)
        }
        if let subSnap = snapshot.peerSubSplit {
            restoreSubSplit(subSnap, primary: primary, side: .peer)
        }

        updateSplitDimming(for: primary)
    }

    // MARK: - Sub-split restoration

    private enum RestoreSide { case primary, peer }

    private func restoreSubSplit(
        _ subSnap: SubSplitSnapshot, primary: SpaceDocument, side: RestoreSide
    ) {
        guard var entry = splitPeers[ObjectIdentifier(primary)] else { return }
        guard let subDir = SplitContainerView.Direction(
            persistedName: subSnap.direction
        ) else { return }

        // The document whose pane will be sub-split.
        let focusedDoc: SpaceDocument = (side == .peer) ? entry.document : primary
        let focusedView = focusedDoc.documentView
        let peerDir = validatedDirectory(subSnap.cwd)
        let newPeer = TerminalPane(
            config: config, frame: focusedView.bounds, workingDirectory: peerDir)
        (newPeer as? any SpaceDocumentReporting)?.documentDelegate = self

        let nested = SplitContainerView(frame: focusedView.frame)
        nested.autoresizingMask = []

        let parentContainer = focusedView.superview as? SplitContainerView
            ?? documentArea.container
        parentContainer.replaceChild(focusedView, with: nested)
        nested.setPrimary(focusedView)
        nested.addSplit(newPeer.documentView, direction: subDir)
        nested.applyDividerRatio(CGFloat(subSnap.ratio))

        var subSplit = SplitEntry.SubSplit(
            document: newPeer, container: nested, direction: subDir)
        // Mirror the saved ratio so splitSnapshot reads the correct value
        // even when this tab is off-screen (same discipline as outerDividerRatio).
        subSplit.storedRatio = CGFloat(subSnap.ratio)
        switch side {
        case .primary: entry.primarySubSplit = subSplit
        case .peer:    entry.peerSubSplit = subSplit
        }
        splitPeers[ObjectIdentifier(primary)] = entry

        newPeer.start()

        // Install click and drag callbacks on the nested container.
        let capturedPrimary = primary
        nested.didReceiveClickInChild = { [weak self] _ in
            guard let self else { return }
            self.updateSplitDimming(for: capturedPrimary)
        }
        nested.onDividerDragEnd = { [weak self] in
            guard let self else { return }
            self.snapshotSubSplitRatio(container: nested, primary: capturedPrimary)
            self.persistSplitState(for: self.root)
        }
    }

    // MARK: - Tab-switch ratio capture

    /// Save the outgoing tab's live divider ratios (outer + sub-splits) before
    /// the container is repurposed for the incoming tab. Called from
    /// `selectDocument(at:)` and `applyDocumentOrder`.
    func snapshotOutgoingDividerRatio() {
        guard let outgoing = activeDocument else { return }
        let key = ObjectIdentifier(outgoing)
        guard splitPeers[key] != nil else { return }
        splitPeers[key]!.outerDividerRatio =
            documentArea.container.currentDividerRatio
        // Sub-split containers are live only while this tab is displayed;
        // `presentSplitEntry` resets them to 0.5 via `addSplit`. Capture now.
        if let sub = splitPeers[key]!.primarySubSplit {
            splitPeers[key]!.primarySubSplit!.storedRatio =
                sub.container.currentDividerRatio
        }
        if let sub = splitPeers[key]!.peerSubSplit {
            splitPeers[key]!.peerSubSplit!.storedRatio =
                sub.container.currentDividerRatio
        }
    }

    /// Update the stored ratio on whichever sub-split owns `container`.
    /// Called from the nested `onDividerDragEnd` callback.
    func snapshotSubSplitRatio(
        container: SplitContainerView, primary: SpaceDocument
    ) {
        let key = ObjectIdentifier(primary)
        guard splitPeers[key] != nil else { return }
        if splitPeers[key]!.primarySubSplit?.container === container {
            splitPeers[key]!.primarySubSplit!.storedRatio =
                container.currentDividerRatio
        } else if splitPeers[key]!.peerSubSplit?.container === container {
            splitPeers[key]!.peerSubSplit!.storedRatio =
                container.currentDividerRatio
        }
    }

    // MARK: - Snapshot

    /// Build a snapshot of the active document's split state, or nil if unsplit.
    /// Called from `persistSplitState()` to serialize the current arrangement.
    func splitSnapshot(for primary: SpaceDocument) -> SplitSnapshot? {
        guard let entry = splitPeers[ObjectIdentifier(primary)] else { return nil }
        // Read the per-entry stored ratio rather than the live container. The container
        // holds only the currently-displayed tab's ratio; off-screen tabs would silently
        // read whatever the active tab has, losing their divider position on persist.
        let outerRatio = entry.outerDividerRatio

        let primarySub: SubSplitSnapshot? = entry.primarySubSplit.map {
            SubSplitSnapshot(
                direction: $0.direction.persistedName,
                ratio: Double($0.storedRatio),
                cwd: ($0.document as? ShellHosting)?.currentDirectory?.path)
        }
        let peerSub: SubSplitSnapshot? = entry.peerSubSplit.map {
            SubSplitSnapshot(
                direction: $0.direction.persistedName,
                ratio: Double($0.storedRatio),
                cwd: ($0.document as? ShellHosting)?.currentDirectory?.path)
        }

        return SplitSnapshot(
            outerDirection: entry.direction.persistedName,
            outerRatio: Double(outerRatio),
            peerCwd: (entry.document as? ShellHosting)?.currentDirectory?.path,
            primarySubSplit: primarySub,
            peerSubSplit: peerSub)
    }

    // MARK: - Persist

    /// Write the current split state for this Space's root to UserDefaults.
    /// Called from `SpaceWindowController` on every split change.
    func persistSplitState(for root: URL) {
        // Tab 0 only -- restore creates one tab per Space, so only the first
        // tab's split is worth saving. If it is unsplit, clear the stored state.
        guard let primary = documents.first,
              let snapshot = splitSnapshot(for: primary) else {
            SplitStateStore.removeSnapshots(for: root)
            return
        }
        SplitStateStore.setSnapshots([snapshot], for: root)
    }

    // MARK: - CWD validation

    /// Return the saved CWD as a URL if it still exists and is usable, otherwise
    /// fall back to the Space root. Mirrors the check-on-read discipline from
    /// `Defaults.swift:182-189`.
    private func validatedDirectory(_ path: String?) -> URL {
        guard let path, FileManager.default.isUsableSpaceRoot(atPath: path) else {
            return root
        }
        return URL(fileURLWithPath: path)
    }
}
