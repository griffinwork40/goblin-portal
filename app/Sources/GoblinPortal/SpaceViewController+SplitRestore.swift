//
//  SpaceViewController+SplitRestore.swift
//  Restoring split pane arrangements from a persisted snapshot.
//
//  Its own file because restoration is a distinct concern from split creation
//  (+Splits.swift) and presentation (+SplitPresentation.swift). It reads a
//  `SplitSnapshot`, constructs the same view hierarchy `makeSplit` would, and
//  applies saved divider ratios -- driven from data instead of user events.
//
//  Called from `SpaceWindowController.openFirstDocument()` after geometry is
//  settled, so `SplitContainerView.layout()` has real bounds to clamp against.
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

        splitPeers[ObjectIdentifier(primary)] = SplitEntry(
            document: peer, direction: outerDir)
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

        let subSplit = SplitEntry.SubSplit(
            document: newPeer, container: nested, direction: subDir)
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
            self.persistSplitState(for: self.root)
        }
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
