//
//  SpaceViewController+SessionHighlight.swift
//  Session-scoped file-highlight tracking for the sidebar file tree.
//
//  Owns the `SessionHighlightStore` that accumulates which repo-relative paths
//  have been dirty since the tree entered its current repository (#298).
//  Fed from `updateSourceControl(snapshot:repository:)` — the single fanout
//  point — so the poller's "one snapshot, no derived stores" invariant stays
//  intact.
//
//  Why its own file: `SpaceViewController.swift` is at 350/350 LOC and cannot
//  absorb any new code. The associated-object pattern is the same as
//  `SpaceViewController+SourceControl.swift` uses for the SCM panel.
//

import AppKit
import ObjectiveC

// MARK: - Associated-object storage

/// A reference wrapper so `SessionHighlightStore` (a value type) can be stored
/// as an Objective-C associated object. Mutations happen in place through the
/// box, avoiding a copy-on-every-tick allocation.
///
/// The same role `NSNumber` plays for the `Bool` flag in
/// `FileTreeViewController+SourceControl.swift`, but for a struct.
@MainActor
private final class SessionHighlightBox {
    var store = SessionHighlightStore()
}

nonisolated(unsafe) private var sessionHighlightBoxKey: UInt8 = 0

// MARK: - SpaceViewController extension

extension SpaceViewController {

    /// The session-highlight box, created lazily on first access.
    ///
    /// Stored via `objc_setAssociatedObject` because Swift extensions cannot add
    /// stored properties, and `SpaceViewController.swift` is at 350/350 LOC.
    private var highlightBox: SessionHighlightBox {
        if let existing = objc_getAssociatedObject(self, &sessionHighlightBoxKey)
            as? SessionHighlightBox
        {
            return existing
        }
        let box = SessionHighlightBox()
        objc_setAssociatedObject(
            self, &sessionHighlightBoxKey, box,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return box
    }

    /// Accumulate the current snapshot's dirty paths and push the effective set
    /// to the file tree for rendering.
    ///
    /// Called from `updateSourceControl(snapshot:repository:)` on every 2s
    /// git-status tick. The tree reads `sessionTouchedPaths` during its repaint
    /// loop, which runs immediately after this returns (the call order in
    /// `gitStatusDidChange()` guarantees it). The repository's root is passed so a
    /// change of repository starts a new session (#298): the paths are repo-relative,
    /// and the policy decides what a change means (`SessionHighlightPolicy.swift`).
    func updateSessionHighlight(snapshot: GitStatusSnapshot, repository: GitRepository?) {
        highlightBox.store.accumulate(
            entryKeys: Set(snapshot.entries.keys), repositoryRoot: repository?.root.path)
        fileTree.sessionTouchedPaths = highlightBox.store.effectivePaths
    }

    /// Clear session highlights. Callable from a menu action or programmatically.
    @objc func resetSessionHighlights(_ sender: Any?) {
        highlightBox.store.reset()
        fileTree.sessionTouchedPaths = []
        // Repaint so highlights disappear without waiting for the next 2s tick.
        fileTree.gitStatusDidChange()
    }
}
