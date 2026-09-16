//
//  GitStatus+Phrasing.swift
//  A whole `GitFileEntry` said in words, for the two channels that have room for a
//  sentence: the row tooltip and VoiceOver.
//
//  **Foundation-only, and that is the entire reason this is not in
//  `GitStatus+Presentation.swift`.** These two properties touch nothing but `String`,
//  `Bool` and `String?` — no `NSColor`, no view — yet living beside `decorationColour`
//  put them behind that file's `import AppKit`, and this repo's only mechanical gate
//  (`check-git-status.sh`) compiles single Foundation-only files standalone with
//  `swiftc`. Deterministic string logic that could be gated but is not is the one kind
//  of untested code this project has no excuse for, so it lives where the gate reaches.
//
//  The division of labour is therefore: `GitStatus.swift` owns the model,
//  `GitStatus+Rollup.swift` owns what a folder inherits, this file owns what a row says,
//  and `GitStatus+Presentation.swift` owns the only thing that genuinely needs AppKit —
//  what a row looks like.
//

import Foundation

extension GitFileStatus {
    /// What VoiceOver says instead of the badge letter.
    ///
    /// The letter and the colour are both glance affordances, and neither survives being
    /// read aloud: "M" is not a word and a tint is not announced at all. Without this the
    /// entire feature is invisible to a screen reader — which would make colour the *only*
    /// channel carrying the status, and colour alone is also what a colour-blind user does
    /// not get. That is the same reasoning that keeps the letter badge on by default rather
    /// than following Zed's colour-only look.
    ///
    /// Lower-case by contract: `GitFileEntry.tooltip` capitalises the first character of
    /// the assembled sentence, so a value starting upper-case here would produce a
    /// double-capitalised tooltip. `check-git-status.sh` pins that.
    var accessibilityDescription: String {
        switch self {
        case .conflicted: return "conflicted"
        case .added: return "added"
        case .modified: return "modified"
        case .deleted: return "deleted"
        case .renamed: return "renamed"
        case .copied: return "copied"
        case .typeChanged: return "type changed"
        case .untracked: return "untracked"
        case .ignored: return "ignored"
        }
    }
}

extension GitFileEntry {
    /// The row's status in words — the two facts a one-letter badge structurally cannot
    /// carry, joined to the one it can.
    ///
    /// `GitFileStatus.accessibilityDescription` answers for the *status*; this answers
    /// for the whole *entry*, which is where `isStaged` and `originalPath` live. Both
    /// were parsed from the day the feature landed and neither reached a user: the badge
    /// column holds one character, and a rename source is a path. So they surface here
    /// instead, rather than being encoded into more glyph vocabulary a reader would have
    /// to learn.
    ///
    /// Staged-ness is deliberately a *qualifier*, not a separate status. The parser
    /// already collapses X and Y to the more urgent of the two (`ordinaryEntry`, which
    /// prefers the worktree change because it is the one not yet recorded), so
    /// "modified, staged" is the honest reading of `XY = MM`: the worktree edit is what
    /// you see, and the index also holds one.
    var statusPhrase: String {
        var phrase = status.accessibilityDescription
        // Appended rather than prefixed: a screen-reader listener hears the noun they were
        // scanning for first, and the qualifier only matters once they have it.
        if isStaged { phrase += ", staged" }
        // Only a rename/copy *record* carries an origin, so this is nil for every other
        // record and costs nothing to ask. It is **not** "nil for every status except
        // renamed and copied" — `ordinaryEntry` collapses XY to the worktree side when
        // both moved, so `git mv A B && echo x >> B` arrives as `XY = RM`: status
        // `.modified`, still carrying `A`. "Modified, staged, from A" is the honest
        // reading of that row, and the badge showing `M` rather than `R` is the same
        // collapse being consistent.
        if let originalPath { phrase += ", from \(originalPath)" }
        return phrase
    }

    /// The same sentence, capitalised for a tooltip.
    ///
    /// Tooltips are read as prose and VoiceOver labels are read as a continuation of the
    /// filename, so only the case differs — one string, two presentations, rather than two
    /// strings that can drift. Only the first character is touched: `localizedCapitalized`
    /// would title-case the path in `from Sources/Umber/Old.swift` and misreport a filename.
    var tooltip: String {
        statusPhrase.prefix(1).uppercased() + statusPhrase.dropFirst()
    }
}
