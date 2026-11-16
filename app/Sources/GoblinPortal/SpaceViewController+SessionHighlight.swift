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
//  Also the two session commands of the Source Control menu (#298): Clear Session
//  Highlights (`resetSessionHighlights(_:)`) and Stage Session Changes
//  (`stageSessionChanges()`). They live here, not on the panel, because the store is
//  private to this file; the panel only ever receives the finished path list.
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
    /// loop, which runs once this fanout (this call, then the panel's update, badge
    /// and switcher) returns to `gitStatusDidChange()`: that method calls
    /// `notifySourceControlOfChange()` before its loop. The repository's root is passed so a
    /// change of repository starts a new session (#298): the paths are repo-relative,
    /// and the policy decides what a change means (`SessionHighlightPolicy.swift`).
    func updateSessionHighlight(snapshot: GitStatusSnapshot, repository: GitRepository?) {
        highlightBox.store.accumulate(
            entryKeys: Set(snapshot.entries.keys), repositoryRoot: repository?.root.path)
        let effective = highlightBox.store.effectivePaths
        fileTree.sessionTouchedPaths = effective
        // The Source Control panel draws the same marker on its rows. They read this set
        // when the outline next makes them, after the `reloadData` that
        // `updateSourceControl` runs AFTER this call, so the panel and the tree show the
        // same tick's session (gated pixel-for-pixel by check-session-marker.sh).
        sourceControlPanel.sessionTouchedPaths = effective
    }

    /// Clear session highlights: Source Control > Clear Session Highlights (#298).
    ///
    /// `gitStatusDidChange()` re-enters the single fanout (`notifySourceControlOfChange`
    /// → `updateSourceControl` → `updateSessionHighlight`) with the poller's CACHED
    /// snapshot — its last read, not a fresh one — so the emptied store takes that
    /// snapshot as its new baseline in this same turn. Deliberately not "the next
    /// snapshot": the poller fans out only when a read CHANGED
    /// (`FileTreeViewController+Git.swift`, `guard changed else { return }`), so the next
    /// delivered snapshot already contains the first file changed after the clear, and
    /// baselining it would hide exactly that file. The limit: a file that became dirty
    /// after the last read and before the clear is not in that baseline, so it is treated
    /// as changed since the clear and marked.
    @objc func resetSessionHighlights(_ sender: Any?) {
        highlightBox.store.reset()
        fileTree.sessionTouchedPaths = []
        sourceControlPanel.sessionTouchedPaths = []
        // Repaint so highlights disappear without waiting for the next 2s tick.
        fileTree.gitStatusDidChange()
    }

    /// The session's paths and the root they are relative to — the narrow read the
    /// stage command needs. Exposed as values rather than widening the private box, so
    /// nothing outside this file can mutate the store.
    var sessionHighlightScope: (paths: Set<String>, root: String?) {
        (highlightBox.store.effectivePaths, highlightBox.store.repositoryRoot)
    }

    /// What Stage Session Changes would stage according to the panel's CACHED snapshot,
    /// decided by the pure `SessionStagePolicy` (gated by `check-session-stage.sh`). Read
    /// only by menu validation (`AppDelegate+Validation.swift`) to grey the item out, and
    /// only a hint: that snapshot is the poller's last delivery, up to a read interval old,
    /// so the action never stages from it (see `stageSessionChanges()`). No second copy is
    /// stored: a second copy would break the poller's one-snapshot invariant
    /// (`FileTreeViewController+Git.swift:11`).
    func sessionPathsToStage() -> [String] {
        let scope = sessionHighlightScope
        let panel = sourceControlPanel
        return SessionStagePolicy.pathsToStage(
            sessionPaths: scope.paths, sessionRoot: scope.root,
            snapshot: panel.snapshot, panelRoot: panel.repository?.root.path)
    }

    /// Source Control > Stage Session Changes (#298): one `git add` over the session's
    /// files that are safe to stage. Captures only values here, on the main actor (the
    /// session's paths and root); the panel's `performOperation` captures its repository.
    /// The decision is made in the background by `SessionStageOperation`, from a status
    /// read taken immediately before the add, because the cached snapshot validation uses
    /// may predate a partial `git add -p` that a stale "unstaged" would let `git add`
    /// overwrite. A few milliseconds between that read and the add remain unguarded.
    /// No session, or a session from another repository, is a silent no-op here (no
    /// subprocess, no alert); the background policy re-checks the root anyway.
    func stageSessionChanges() {
        let scope = sessionHighlightScope
        guard !scope.paths.isEmpty, let root = scope.root,
              root == sourceControlPanel.repository?.root.path else { return }
        sourceControlPanel.stageSessionChanges(sessionPaths: scope.paths, sessionRoot: root)
    }
}
