//
//  SessionStagePolicy.swift
//  Which of the session's files "Stage Session Changes" may hand to `git add` (#298).
//
//  Foundation-only on purpose, like `SessionHighlightPolicy.swift` beside it: it is the
//  one piece of T5.5 that can damage a user's index, so it has to be compilable alone by
//  `Scripts/check-session-stage.sh`, which runs a truth table, mutants and real-`git`
//  cases over it. The AppKit action (`SpaceViewController+SessionHighlight.swift`) only
//  gathers the inputs and dispatches the result.
//
//  WHY A SEPARATE FILE FROM `SessionHighlightPolicy.swift`. That file answers "which paths
//  did this session see dirty?" and needs nothing but sets of strings. This one answers
//  "which of those is it SAFE to stage right now?", which needs the porcelain model
//  (`GitFileEntry`, `GitStatusSnapshot` in `GitStatus.swift`). Keeping them apart keeps
//  `check-session-highlight.sh` compiling one file, and keeps the write-side rules in one
//  place a reader can hold whole.
//
//  The index has no undo. Every rule below errs toward NOT staging: a skipped file costs
//  the user one click on its row; a wrongly staged one can destroy hunk-level work.
//

import Foundation

enum SessionStagePolicy {
    /// The repo-relative paths to pass to ONE `git add -- <paths>`, sorted, or empty.
    ///
    /// - `sessionPaths`: `SessionHighlightStore.effectivePaths` (accumulated minus baseline).
    /// - `sessionRoot`: `SessionHighlightStore.repositoryRoot`, the root those paths are
    ///   relative to.
    /// - `snapshot`, `panelRoot`: the Source Control panel's latest snapshot and its
    ///   repository's root (`SourceControlViewController.snapshot` / `.repository`), read at
    ///   click time — never a second stored copy (`FileTreeViewController+Git.swift:11`).
    static func pathsToStage(
        sessionPaths: Set<String>,
        sessionRoot: String?,
        snapshot: GitStatusSnapshot,
        panelRoot: String?
    ) -> [String] {
        // Paths are repo-relative (#298, the false positive fixed in #310): a session
        // gathered in repo A says nothing about repo B's `README.md`. A mismatch, or either
        // side having no repository at all, stages nothing.
        guard let sessionRoot, let panelRoot, sessionRoot == panelRoot else { return [] }

        var result: [String] = []
        for path in sessionPaths {
            // A session path git no longer reports (committed, or reverted) has nothing
            // to stage. A rename's ORIGINAL path is never looked up through
            // `entry.originalPath`: an unstaged rename arrives as two entries of its own
            // (old path deleted, new path untracked) and both are judged below; a staged
            // rename is keyed by its new path only and is already in the index.
            guard let entry = snapshot.entries[path] else { continue }
            // Partially staged: the index already holds a hunk-level choice and the
            // worktree differs again. `git add` would overwrite that choice wholesale.
            if entry.isStaged && entry.hasWorkingTreeChange { continue }
            // Conflicted: `git add` is how git records "resolved", so staging a file
            // that still holds conflict markers would mark it done.
            if entry.status == .conflicted { continue }
            // Ignored files only appear under `--ignored`, which the reader never passes
            // (`GitStatusReader.snapshot(of:)`); refused anyway so a flag flip cannot
            // start force-adding them.
            if entry.status == .ignored { continue }
            // Candidates: untracked, or carrying an unstaged worktree change (modified,
            // deleted, type-changed). Staged-only entries have nothing left to add.
            if entry.status == .untracked || entry.hasWorkingTreeChange {
                result.append(path)
            }
        }
        return result.sorted()
    }
}
