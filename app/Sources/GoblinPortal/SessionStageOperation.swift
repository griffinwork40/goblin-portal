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
//  A FAILED READ IS REPORTED, NOT SWALLOWED. If `git status` cannot be read (git will not
//  launch, the index is unreadable, the repository has gone), nothing is staged and the
//  call returns `.failure`, which the panel's `performOperation` shows as an alert like
//  every other Source Control operation. The first cut returned success here, so the
//  click did nothing and said nothing; a refusal the user cannot see looks like the
//  action being broken. A read that succeeds and leaves nothing to stage stays silent.
//

import Foundation

enum SessionStageOperation {
    /// Shown, after `performOperation`'s "git stage session changes failed:" line, when
    /// the fresh status read fails. Says both halves: why, and that the index is untouched.
    static let statusReadFailedMessage = "Could not read git status, so nothing was staged."

    /// Read `repository`'s status now, choose with `SessionStagePolicy.pathsToStage`
    /// against that read, and stage the result with ONE `GitOperations.stage(paths:in:)`.
    ///
    /// Blocks on up to two subprocesses: call it off the main thread (the panel's
    /// `performOperation` runs it on a global queue). `sessionPaths` and `sessionRoot` are
    /// values captured on the main actor at click time (`sessionHighlightScope`); the
    /// repository's root is the panel root the policy compares against.
    ///
    /// Neither a failed read nor a read that leaves nothing to stage spawns `git add`.
    /// A failed read returns `.failure` with `statusReadFailedMessage`, so the user sees an
    /// alert instead of a click that silently does nothing; a successful read with nothing
    /// eligible returns success (the caller's success path only re-polls).
    static func stageFromFreshRead(
        sessionPaths: Set<String>,
        sessionRoot: String?,
        in repository: GitRepository
    ) -> Result<Void, GitOperationError> {
        guard let fresh = GitStatusReader.snapshot(of: repository) else {
            return .failure(GitOperationError(message: statusReadFailedMessage))
        }
        let paths = SessionStagePolicy.pathsToStage(
            sessionPaths: sessionPaths, sessionRoot: sessionRoot,
            snapshot: fresh, panelRoot: repository.root.path)
        guard !paths.isEmpty else { return .success(()) }
        return GitOperations.stage(paths: paths, in: repository)
    }
}
