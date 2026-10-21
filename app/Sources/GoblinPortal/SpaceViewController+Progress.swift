// SpaceViewController+Progress.swift
// Routes OSC 9;4 progress changes from documents up to the Dock tile.
//
// Why a separate file
// -------------------
// SpaceViewController.swift is at the 350-line ceiling.  Progress is a new,
// orthogonal concern that fits cleanly as a one-method extension.
//
// How it fits the existing funnel
// --------------------------------
// documentDidChangeStatus already calls syncDocumentChrome, which rebuilds the
// tab strip items and calls syncDockAttention.  We extend syncDocumentChrome's
// downstream by calling dockProgressDidChange() from the same place — one call
// site, no extra notification.
//
// The call is added to syncDocumentChrome in SpaceViewController.swift via a
// hook method here.  SpaceViewController.syncDocumentChrome() calls
// syncDockProgress() (defined below) after the strip reload, mirroring the
// existing syncDockAttention() call.
//
import AppKit

@MainActor
extension SpaceViewController {

    /// Recompute progress across all documents and update the Dock tile.
    /// Called from syncDocumentChrome() in SpaceViewController.swift, after the
    /// strip reload, mirroring the existing syncDockAttention() call.
    func syncDockProgress() {
        (NSApp.delegate as? AppDelegate)?.updateDockProgress()
    }

    // MARK: - Progress item for the tab strip

    /// Aggregate the progress of a primary document and its split peers for
    /// display in the tab strip item.  A single tab may host up to 4 panes
    /// (via splits); the tab's progress bar reflects all of them.
    func progressAggregation(for document: SpaceDocument) -> ProgressAggregation {
        let peers = [document] + allSplitDocuments(for: document)
        let states = peers.compactMap { ($0 as? TerminalPane)?.progressPolicy.state }
        return ProgressAggregation.of(states)
    }
}
