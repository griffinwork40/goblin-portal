//
//  SessionStageOperation.swift
//  Stage Session Changes' background half: read status, decide, add (#298).
//
//  Foundation-only and not `@MainActor`, like `GitStatusReader.swift` and
//  `GitOperations.swift` whose calls it sequences, so `Scripts/check-session-stage.sh`
//  compiles it standalone and drives the shipped sequence against a real repository.
//
//  WHY A SEPARATE FILE FROM `SessionStagePolicy.swift`. That file is a pure function over
//  values and its header promises no process; this one spawns two (`git status`, then
//  `git add`). Keeping them apart keeps the policy's truth table free of subprocesses and
//  keeps this file's single claim — decide from a read taken just now — readable whole.
//
//  WHY A FRESH READ AND NOT THE PANEL'S SNAPSHOT. The panel's snapshot is the poller's
//  last delivery, up to a read interval old (FSEvents with a 1 s rate floor and a 2 s
//  backstop, stopped while the window is not key; `GitStatusWatch.swift`). A session file
//  partially staged after that read (`git add -p`, or the agent in the terminal staging
//  hunks) still reads "unstaged" there, so the policy's partial-staging skip would not
//  fire and `git add` would overwrite the hunk-level staging; the index has no undo. The
//  same staleness could let a file that has just become conflicted through. Deciding from
//  a read taken in the same background operation, immediately before the add, closes all
//  but a residual window of a few milliseconds between the two subprocesses — a hunk
//  staged inside that window can still be overwritten. Git offers no compare-and-swap on
//  the index for `add`, so that window is narrowed, not closed.
//
//  The fresh snapshot is used once and dropped: the poller's snapshot stays the only
//  stored copy (`FileTreeViewController+Git.swift:11`).
//

import Foundation

enum SessionStageOperation {
    /// Read `repository`'s status now, choose with `SessionStagePolicy.pathsToStage`
    /// against that read, and stage the result with ONE `GitOperations.stage(paths:in:)`.
    ///
    /// Blocks on up to two subprocesses: call it off the main thread (the panel's
    /// `performOperation` runs it on a global queue). `sessionPaths` and `sessionRoot` are
    /// values captured on the main actor at click time (`sessionHighlightScope`); the
    /// repository's root is the panel root the policy compares against.
    ///
    /// A failed read, or a read that leaves nothing to stage, stages nothing and reports
    /// success without spawning `git add`: refusing to write is always safe here, and the
    /// caller's success path only re-polls.
    static func stageFromFreshRead(
        sessionPaths: Set<String>,
        sessionRoot: String?,
        in repository: GitRepository
    ) -> Result<Void, GitOperationError> {
        guard let fresh = GitStatusReader.snapshot(of: repository) else { return .success(()) }
        let paths = SessionStagePolicy.pathsToStage(
            sessionPaths: sessionPaths, sessionRoot: sessionRoot,
            snapshot: fresh, panelRoot: repository.root.path)
        guard !paths.isEmpty else { return .success(()) }
        return GitOperations.stage(paths: paths, in: repository)
    }
}
