//
//  GitStatus+Rollup.swift
//  How a *directory* row gets a decoration it has no git record of its own for.
//
//  Its own file because this is one whole concern that happened to be spread across two
//  types: the rule for which child status wins (`GitFileStatus.rollupPrecedence`), the
//  rule for which ones climb at all (`.propagatesToParent`), and the walk that applies
//  both (`GitStatus.rollUp`). Nothing else in the parser reads any of the three, and
//  nothing here is reachable from a file row — `GitStatusSnapshot.entries` answers
//  those directly. Splitting by *what the code does* rather than by line count is the
//  house rule (AFK.md, "Conventions"), and "a folder's decoration" is the thing.
//
//  Foundation-only on purpose, exactly like `GitStatus.swift`: it is compiled standalone
//  by `check-git-status.sh`, whose fixtures already assert the roll-up ("immediate
//  parent inherits", "grandparent inherits too", "deleted does NOT roll up"). Adding an
//  `NSColor` here would break that gate as surely as adding one to the parser.
//
//  Extracted 2026-08-02 when `GitStatusSnapshot` gained `hasUpstream` and the parser
//  crossed the 350-line ceiling. The ceiling is what forced the question; the seam is
//  why the answer was obvious.
//

import Foundation

extension GitFileStatus {
    /// Which status wins when a directory rolls up several children, lower first.
    ///
    /// A conflict outranks everything because it is the one state where continuing to
    /// work without noticing actively destroys information. Untracked and ignored sort
    /// last so that a folder holding one edited file and forty new ones still reads as
    /// edited, which is the question a user is usually asking of a parent row.
    var rollupPrecedence: Int {
        switch self {
        case .conflicted: return 0
        case .added: return 1
        case .modified: return 2
        case .typeChanged: return 3
        case .renamed: return 4
        case .copied: return 5
        case .deleted: return 6
        case .untracked: return 7
        case .ignored: return 8
        }
    }

    /// Whether this status propagates from a file up to its ancestor directories.
    ///
    /// Deleted does not, matching VS Code (`DELETED`/`INDEX_DELETED` are excluded from
    /// its folder rollup). The reason is that a deleted file's row is itself gone from
    /// the tree, so tinting the surviving parent "deleted" would claim the *directory*
    /// was removed — the one reading a user would act on and the one that is wrong.
    var propagatesToParent: Bool { self != .deleted }
}

extension GitStatus {
    /// Every ancestor directory of every changed path, carrying the highest-precedence
    /// status among its descendants.
    ///
    /// Built eagerly and completely on each snapshot rather than patched incrementally.
    /// That is a decision, not an oversight: all five of VS Code's separately
    /// root-caused stale-decoration bugs came from clever incremental invalidation
    /// (`.afk/research/git-sidebar-decision-2026-07-31.md` §5), and this map is small —
    /// bounded by changed paths times their depth, not by repo size.
    ///
    /// `internal` rather than `private` only because it now lives across a file boundary
    /// from its caller; it is still called exactly once, at the end of `parse`.
    static func rollUp(_ entries: [String: GitFileEntry]) -> [String: GitFileStatus] {
        var directories: [String: GitFileStatus] = [:]
        for entry in entries.values where entry.status.propagatesToParent {
            var components = entry.path.split(separator: "/")
            components.removeLast()  // the file itself is in `entries`, not here
            var prefix = ""
            for component in components {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                if let existing = directories[prefix],
                    existing.rollupPrecedence <= entry.status.rollupPrecedence
                {
                    continue
                }
                directories[prefix] = entry.status
            }
        }
        return directories
    }
}
