//
//  SpaceViewController+SplitPresentation.swift
//  The display half of split panes: dimming, click callbacks, and restoring
//  the nested view hierarchy when switching tabs.
//
//  Extracted from SpaceViewController+Splits.swift at the 350-LOC ceiling.
//  The model half (creating, closing, focus movement) stays there; this file
//  owns the visual concern of how a split entry maps to the view hierarchy.
//

import AppKit

extension SpaceViewController {

    // MARK: - Presentation (restoring nested splits on tab switch)

    /// Present a SplitEntry's full view hierarchy (outer + any nested containers).
    func presentSplitEntry(_ entry: SplitEntry, primary: SpaceDocument) {
        // Build the primary side: either the doc's own view or a nested container.
        // Clear any existing split first so re-presenting on tab switch works --
        // addSplit guards `splitView == nil` and silently no-ops otherwise.
        let primaryView: NSView
        if let sub = entry.primarySubSplit {
            if sub.container.isSplit { sub.container.removeSplit() }
            sub.container.setPrimary(primary.documentView)
            sub.container.addSplit(sub.document.documentView, direction: sub.direction)
            primaryView = sub.container
        } else {
            primaryView = primary.documentView
        }

        // Build the peer side.
        let peerView: NSView
        if let sub = entry.peerSubSplit {
            if sub.container.isSplit { sub.container.removeSplit() }
            sub.container.setPrimary(entry.document.documentView)
            sub.container.addSplit(sub.document.documentView, direction: sub.direction)
            peerView = sub.container
        } else {
            peerView = entry.document.documentView
        }

        documentArea.presentSplit(
            primaryView: primaryView, splitView: peerView, direction: entry.direction)
        installClickCallback(primary: primary)
    }

    // MARK: - Dimming

    /// Resolve which leaf pane currently holds focus and update opacity accordingly.
    ///
    /// Called after any event that might change focus: split creation, keyboard
    /// navigation (⌘⇧H/J/K/L), config reload (⌘R), tab switches, and clicks.
    func updateSplitDimming(for primary: SpaceDocument) {
        guard let entry = splitPeers[ObjectIdentifier(primary)] else { return }
        let opacity = CGFloat(config.unfocusedPaneOpacity)
        let fr = view.window?.firstResponder
        let leaves = gatherLeaves(primary: primary, entry: entry)
        let focusedView = leaves.first(where: { isDescendant(fr, of: $0.view) })?.view

        if leaves.count <= 2 {
            // Simple 2-pane: use the container's built-in setFocusedChild dimming.
            documentArea.container.setFocusedChild(focusedView, opacity: opacity)
        } else {
            // 3-4 panes: dim each leaf individually. Clear the container-level
            // dimming first so it does not stack with per-leaf alphas.
            documentArea.container.setFocusedChild(nil, opacity: 1.0)
            for leaf in leaves {
                let alpha: CGFloat = (leaf.view === focusedView) ? 1.0 : opacity
                if opacity < 1.0 {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.15
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        leaf.view.animator().alphaValue = alpha
                    }
                } else {
                    leaf.view.alphaValue = 1.0
                }
            }
        }
    }

    /// Install the click callback on the outer container and any nested containers.
    ///
    /// Each callback re-runs `updateSplitDimming` so a mouse click on an unfocused
    /// pane immediately dims the other panes -- before firstResponder changes.
    func installClickCallback(primary: SpaceDocument) {
        let capturedPrimary = primary
        let handler: (NSView) -> Void = { [weak self] _ in
            guard let self else { return }
            self.updateSplitDimming(for: capturedPrimary)
        }
        documentArea.container.didReceiveClickInChild = handler
        if let entry = splitPeers[ObjectIdentifier(primary)] {
            entry.primarySubSplit?.container.didReceiveClickInChild = handler
            entry.peerSubSplit?.container.didReceiveClickInChild = handler
        }
    }
}
