//
//  GitStatus.swift
//  The porcelain-v2 grammar, and the value type the sidebar decorates from.
//
//  Pure and view-free on purpose — `Foundation` only, no AppKit, no SwiftTerm, and no
//  `Process`. That is not tidiness: it is what lets `Scripts/check-git-status.sh`
//  compile this one file directly with `swiftc` and run a truth table over it, the same
//  trick `ShellDirectory.swift` plays for `check-cwd-follow.sh` and `KeyBindings.swift`
//  for `check-keybindings.sh`. In a repo with no test target and no CI (AFK.md,
//  "Checks"), a concern that cannot be compiled alone cannot be gated alone, so the
//  dependency-free boundary IS the testability. The spawn lives next door in
//  `GitStatusReader.swift` precisely so this half stays a total function over bytes.
//
//  WHY SHELL OUT AT ALL, rather than a Swift git binding. Every candidate fails the
//  worktree bar this repo lives inside: SwiftGit2's newest tag is 0.6.0 (2019-04-15) and
//  no fork adds worktrees, SwiftGitX has no worktree API, and swift-libgit2 is a raw C
//  interop shim. Independently disqualifying: a C binding cannot be compiled by a
//  single-file `swiftc` harness, which would forfeit the only verification surface this
//  repo has. Measured cost of the subprocess is ~6.6ms on this checkout and ~92ms on a
//  60k-file repo, and it scales with tree size rather than dirty-file count
//  (`.afk/research/git-sidebar-external-mechanism-2026-07-31.md` §7).
//
//  WHY `-z` IS NOT OPTIONAL. Without it git applies C-octal quoting to any path with a
//  space or a non-ASCII byte, and whether it does so at all depends on the user's
//  `core.quotePath`. With `-z` the records are NUL-terminated and paths are emitted as
//  raw bytes unconditionally, so a filename containing a quote, a newline, or an emoji
//  arrives intact and config-independent. The cost is the one sharp edge this whole file
//  exists to get right: see `parse(porcelain:)` on the two-path rename record.
//

import Foundation

/// What a file's decoration should say, reduced to the cases a file tree can draw.
///
/// Deliberately smaller than git's full XY cross-product: the sidebar shows one glyph
/// per row, so the parser's job is to collapse `<X><Y>` into the single most
/// decoration-relevant answer rather than to preserve every distinction. Callers that
/// need "is this staged" read `GitFileEntry.isStaged`, which survives the collapse.
///
/// The letters match VS Code's `Resource.getStatusLetter` so a user arriving from it
/// reads the sidebar without relearning anything.
enum GitFileStatus: Equatable {
    case conflicted
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case ignored

    /// The single character VS Code puts in the badge column.
    var letter: String {
        switch self {
        case .conflicted: return "!"
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .ignored: return "I"
        }
    }

    // The two members that answer *only* for a directory roll-up — `rollupPrecedence`
    // and `propagatesToParent` — live in `GitStatus+Rollup.swift` beside the function
    // that is their sole caller. See that file's header.
}

/// One changed path, as git spelled it.
struct GitFileEntry: Equatable {
    /// Repo-relative, forward-slashed, exactly as git emitted it. Not a `URL`: joining
    /// happens once at the point of use against a known repo root, and keeping the raw
    /// spelling here is what makes the parser's output comparable to git's own bytes.
    let path: String
    let status: GitFileStatus
    /// The index differs from HEAD — the change is staged, in whole or in part.
    let isStaged: Bool
    /// Where a rename or copy came from, repo-relative. Nil for every other record.
    let originalPath: String?
}

/// Everything one `git status --porcelain=v2 -z --branch` call answered.
struct GitStatusSnapshot: Equatable {
    /// The branch name, or nil when HEAD is detached or the repo has no commits yet.
    let branch: String?
    let isDetached: Bool
    /// Commits ahead of / behind the upstream, or **nil when git did not report them**.
    ///
    /// Nil is not an error and not zero. `# branch.ab` is absent from the output
    /// entirely on a branch that was never pushed — which is the normal state of every
    /// branch an agent workflow creates, including the one this file was written on. A
    /// caller that renders nil as "0/0" tells the user they are in sync with something
    /// that does not exist.
    ///
    /// Nil is **not** a synonym for "no upstream" either — see `hasUpstream`.
    let ahead: Int?
    let behind: Int?
    /// Whether `# branch.upstream` was present, i.e. whether an upstream is configured
    /// at all.
    ///
    /// Tracked separately from `ahead`/`behind` because git emits the two header lines
    /// under *different* conditions: `# branch.upstream` "If upstream is set", but
    /// `# branch.ab` only "If upstream is set **and the commit is present**"
    /// (`git-status(1)`, porcelain v2 header table, verified against git 2.53.0). A
    /// branch whose remote was deleted and then pruned keeps its upstream config while
    /// reporting no ahead/behind, so a caller reading `ahead == nil` as "no upstream"
    /// mislabels precisely that state — and mislabels it in the direction that matters,
    /// since `git push` there still resolves a destination without `-u`.
    let hasUpstream: Bool
    /// Changed paths keyed by their repo-relative spelling.
    let entries: [String: GitFileEntry]
    /// Ancestor directories that contain a change, keyed the same way, rolled up once
    /// here so the outline view never walks children to answer a parent's decoration.
    /// (`FileNode.children` is nil for an unexpanded directory, so a tree walk could
    /// not answer it anyway — `FileNode.swift:97`.)
    let directories: [String: GitFileStatus]

    static let empty = GitStatusSnapshot(
        branch: nil, isDetached: false, ahead: nil, behind: nil, hasUpstream: false,
        entries: [:], directories: [:])

    /// The decoration for one repo-relative path, file or directory, or nil for clean.
    func status(forRelativePath path: String) -> GitFileStatus? {
        entries[path]?.status ?? directories[path]
    }
}

/// Turning `git status --porcelain=v2 -z` bytes into a snapshot.
///
/// A namespace, not a type: there is no state to hold. Also deliberately not
/// `@MainActor`, unlike almost every type in this app and for the same reason
/// `ShellDirectory` opts out — this is a pure function over bytes, safe to call from
/// the background queue the reader spawns git on, and annotating it would force
/// isolation onto a caller with no reason to want it.
enum GitStatus {
    /// Parse porcelain v2 NUL-delimited output. Never fails: unparseable records are
    /// skipped rather than thrown, because a snapshot missing one row degrades a
    /// decoration while a thrown error would blank the whole sidebar.
    ///
    /// THE RENAME RECORD IS WHY THIS IS NOT A ONE-LINER. In non-`-z` output a `2`
    /// record separates its new and original paths with a literal TAB. Under `-z` that
    /// TAB becomes a **NUL**, so a single logical record occupies **two**
    /// NUL-delimited tokens:
    ///
    ///     2 R. N... 100644 100644 100644 <h> <h> R100 renamed-to.txt\0renamed-from.txt\0
    ///
    /// New path first, original second. A parser that splits the blob on NUL and treats
    /// every piece as one record therefore reads `renamed-from.txt` as a record of its
    /// own, fails to recognise its leading character, and — this is the damaging part —
    /// stays desynchronised for nothing, because each subsequent record is still
    /// self-describing. So the bug does not cascade loudly; it silently drops one path
    /// and invents another. Verified against git 2.53.0 rather than assumed, and it is
    /// the case `check-git-status.sh` watches most closely.
    static func parse(porcelain bytes: [UInt8]) -> GitStatusSnapshot {
        var branch: String?
        var isDetached = false
        var ahead: Int?
        var behind: Int?
        var hasUpstream = false
        var entries: [String: GitFileEntry] = [:]

        // Split on NUL over BYTES, not over a decoded String. Decoding the whole blob
        // first would let one filename with invalid UTF-8 corrupt the record boundaries
        // around it; per-record lossy decoding confines the damage to that row, where
        // the worst outcome is a decoration that fails to match a tree node.
        let records = bytes.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }

        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let kind = record.first else { continue }

            switch kind {
            case "#":
                // `# branch.ab +1 -0` — sign-prefixed and always both fields when
                // present at all. Absent entirely without an upstream, which is why
                // ahead/behind stay nil rather than defaulting to 0.
                if let value = record.dropPrefixIfPresent("# branch.head ") {
                    // "(detached)" is git's literal sentinel, not a branch that happens
                    // to be named that: a real branch cannot contain parentheses this
                    // way, and git documents the spelling.
                    isDetached = value == "(detached)"
                    branch = isDetached ? nil : value
                } else if record.hasPrefix("# branch.upstream ") {
                    // Presence is the entire signal. The upstream's *name* is never
                    // displayed, so parsing it would be dead data — but the line's
                    // presence is the only thing that distinguishes "never pushed" from
                    // "pushed, then the remote branch was deleted and pruned", which
                    // `# branch.ab` cannot, because it is absent in both.
                    hasUpstream = true
                } else if let value = record.dropPrefixIfPresent("# branch.ab ") {
                    let parts = value.split(separator: " ")
                    for part in parts {
                        if part.hasPrefix("+") { ahead = Int(part.dropFirst()) }
                        if part.hasPrefix("-") { behind = Int(part.dropFirst()) }
                    }
                }
            case "1":
                // `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` — path is token 8, so
                // split at most 8 times and keep the remainder whole. A path may contain
                // spaces; the fixed fields never do.
                if let entry = ordinaryEntry(record, pathFieldIndex: 8) {
                    entries[entry.path] = entry
                }
            case "2":
                // `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` — one extra
                // fixed field (the similarity score) pushes the path to token 9, and the
                // original path is the NEXT record. Consuming it here is what keeps the
                // stream aligned; see this method's doc comment.
                let original = index < records.count ? records[index] : nil
                if original != nil { index += 1 }
                if let entry = ordinaryEntry(record, pathFieldIndex: 9, originalPath: original) {
                    entries[entry.path] = entry
                }
            case "u":
                // `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` — three stage
                // modes and three stage hashes instead of two of each, so the path lands
                // at token 10. Unmerged records carry exactly one path, never two.
                //
                // The XY of an unmerged record is not a change description at all (`UU`,
                // `AA`, `DU`...) — it names which side did what. Collapsing every one of
                // them to `.conflicted` is deliberate: the decoration a user needs here
                // is "stop and resolve this", and the six spellings do not change it.
                let fields = record.split(
                    separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                let path = String(fields[10])
                entries[path] = GitFileEntry(
                    path: path, status: .conflicted, isStaged: false, originalPath: nil)
            case "?", "!":
                // `? <path>` / `! <path>` — everything after the single space is path,
                // including any further spaces. `!` only ever appears when the caller
                // passed `--ignored`, which the reader does not; it is handled anyway so
                // that turning the flag on later cannot silently mis-key a record.
                let path = String(record.dropFirst(2))
                guard !path.isEmpty else { continue }
                entries[path] = GitFileEntry(
                    path: path, status: kind == "?" ? .untracked : .ignored,
                    isStaged: false, originalPath: nil)
            default:
                continue
            }
        }

        return GitStatusSnapshot(
            branch: branch, isDetached: isDetached, ahead: ahead, behind: behind,
            hasUpstream: hasUpstream, entries: entries, directories: rollUp(entries))
    }

    /// Convenience for callers holding `Data` — the reader's pipe hands back `Data`, and
    /// the gate reads fixtures off disk as `Data` too.
    static func parse(porcelain data: Data) -> GitStatusSnapshot {
        parse(porcelain: [UInt8](data))
    }

    // MARK: - Record decoding

    /// The shared shape of the `1` and `2` records, which differ only in how many fixed
    /// fields precede the path.
    private static func ordinaryEntry(
        _ record: String, pathFieldIndex: Int, originalPath: String? = nil
    ) -> GitFileEntry? {
        let fields = record.split(
            separator: " ", maxSplits: pathFieldIndex, omittingEmptySubsequences: false)
        guard fields.count == pathFieldIndex + 1 else { return nil }
        let xy = fields[1]
        guard xy.count == 2, let x = xy.first, let y = xy.last else { return nil }
        let path = String(fields[pathFieldIndex])
        guard !path.isEmpty else { return nil }

        // Y (worktree vs index) is preferred over X (index vs HEAD) when both moved,
        // because the worktree change is the one the user just made and has not yet
        // recorded — the more urgent of the two answers. `isStaged` keeps X's
        // information rather than discarding it, so a caller can still colour a staged
        // row differently.
        let effective = y == "." ? x : y
        guard let status = status(forCode: effective) else { return nil }
        return GitFileEntry(
            path: path, status: status, isStaged: x != ".", originalPath: originalPath)
    }

    /// One XY character to a status. `.` means "no change on this side" and is filtered
    /// by the caller before it arrives here.
    private static func status(forCode code: Character) -> GitFileStatus? {
        switch code {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return nil
        }
    }

    // `rollUp(_:)`, the last step of `parse`, lives in `GitStatus+Rollup.swift`.
}

extension String {
    /// Nil when the prefix is absent, so a chain of `if let` reads as a switch over
    /// record kinds without repeating `hasPrefix` and `dropFirst(n)` in lockstep — the
    /// pairing where an off-by-one silently truncates a branch name.
    fileprivate func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
