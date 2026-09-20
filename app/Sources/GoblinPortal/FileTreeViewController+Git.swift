//
//  FileTreeViewController+Git.swift
//  Keeping the tree's git decorations current, and knowing what each row should say.
//
//  Its own file because it is one whole concern with a lifecycle of its own — a timer that
//  must start, stop and not outlive its window — and because the controller had no room:
//  the same argument, and the same shape, as `SpaceViewController+DirectoryFollow.swift`.
//  Only the single stored property lives over there, because Swift extensions cannot add
//  stored properties; everything that property *does* is here.
//
//  THE SNAPSHOT IS THE ONLY COPY, AND THAT IS THE DESIGN. Nothing is cached on `FileNode`.
//  A row's decoration is looked up from the current snapshot at draw time, every time.
//  This deliberately departs from the research's Phase 1 sketch, which proposed a
//  `gitStatus` property on each node, and it departs for the reason the research itself
//  gives two sections later: all five of VS Code's separately-filed, separately-root-caused
//  stale-decoration bugs came from a clever incremental update scheme
//  (`.afk/research/git-sidebar-decision-2026-07-31.md` §5, Risk 2). A per-node copy is
//  exactly such a scheme — a second store that has to be invalidated in step with the
//  first — and the failure mode is silent, because a decoration that is merely *stale*
//  still renders. Consulting one snapshot cannot disagree with itself.
//
//  It is also cheaper and safer here. Cheaper: applying a snapshot costs nothing, where
//  pushing one into the tree costs a walk of every loaded node. Safer: `FileNode`'s header
//  states its contract — "a URL, two flags and a directory read" — and the research
//  rejected the synthetic-outline-group layout precisely for breaking it (§4). Adding a
//  mutable status field would have chipped at the same contract, and mutating nodes at all
//  risks the identity-preservation invariant that `refresh()` depends on. Nothing here
//  touches a node.
//
//  WHY A TIMER AND NOT FSEVENTS, for now. The research recommends FSEvents as the primary
//  signal with a slow poll as a backstop, which is what VS Code does, and that remains the
//  right end state. This first cut is the poll alone, deliberately: it matches what the
//  tree already does (`FileTreeViewController.refresh()` is driven by window-became-key and
//  says in its own comment that "FSEvents is the obvious upgrade if it ever feels behind"),
//  it matches the one poller this app already ships, and it is the half that needs no
//  CoreServices callback plumbing to be correct. The cost of being wrong is latency, not
//  wrongness. Upgrading means adding a watch on BOTH `GitRepository.gitDirectory` and
//  `.commonDirectory` — they differ in a worktree, and one alone is half-blind — plus the
//  worktree itself, since untracked files never touch `.git` at all.
//

import AppKit

/// The git-status poller for one file tree.
///
/// A class rather than a few methods on the controller so the timer, the last snapshot and
/// the start/stop rules sit in one object with one owner — the same argument
/// `DirectoryFollow` makes, and these two are siblings: both poll while their window is
/// key, both stop when it is not, and neither has an event to subscribe to instead.
@MainActor
final class GitStatusFollow {
    /// Weak, and load-bearing for the same reason `DirectoryFollow.space` is: `Timer`
    /// retains its closure until invalidated, and a Space's window can close while a tick
    /// is in flight. A strong reference would keep the tree — and through it the Space —
    /// alive after the window was gone.
    private weak var tree: FileTreeViewController?

    private var timer: Timer?

    /// True while a `git` subprocess is in flight. Ticks that land during one are dropped
    /// rather than queued, which is the small version of the mitigation VS Code needed at
    /// scale: a ~50-repo workspace once fired ~400 concurrent git subprocesses and killed
    /// its own extension host, and the fix was a hard limiter
    /// (`.afk/research/git-sidebar-decision-2026-07-31.md` §5, Risk 4). One Space cannot
    /// reach 400, but a 92ms status on a large repo against a 2s timer is exactly the
    /// shape that starts overlapping, and a dropped tick costs nothing — the next one
    /// rebuilds the whole answer anyway.
    private var isReading = false

    /// Whether a completed read has been logged under `GOBLIN_PORTAL_DIAG` yet — see `finish`.
    private var hasLogged = false

    /// The repository the tree currently sits in, or nil when it is not in one.
    private(set) var repository: GitRepository?

    /// The tree root `repository` was answered for, symlink-resolved. Nil until the first
    /// read lands.
    ///
    /// Keyed on the root it was *answered for*, rather than tested with
    /// `repository.relativePath(for: newRoot) != nil`, because **containment is not
    /// identity**. A worktree or submodule is a repository nested inside another one's
    /// working tree, so "still inside the repo I knew" stays true long after the right answer
    /// has become the inner repo — and under the containment test it stayed true forever,
    /// because nothing ever asked again. This project's own layout is that shape
    /// (`.afk-worktrees/*` are repositories under the main checkout, gitignored there, so the
    /// outer repo reports nothing about their contents), and the symptom was a header naming
    /// the wrong branch over a tree whose every file drew no badge.
    ///
    /// Keyed this way the reuse still absorbs what actually costs spawns — the 2s timer
    /// re-ticking an unchanged root — and pays one `rev-parse` per genuine `cd`, ~6ms off the
    /// main thread. Asserted in `check-git-status.sh`'s NESTED REPOSITORIES cases, which pin
    /// the containment/identity split rather than trusting this comment.
    ///
    /// A path, never a `URL`: `URL` equality carries the directory marker that
    /// `resolvingSymlinksInPath()` drops on a symlink-terminated path, which is the trap
    /// `check-cwd-follow.sh` caught in `setRoot(_:)` (`FileTreeViewController.swift:211`).
    private var repositoryRootPath: String?

    /// The whole answer from the last successful `git status`. `.empty` means either "no
    /// repository" or "nothing changed" — the tree draws the same thing for both.
    private(set) var snapshot: GitStatusSnapshot = .empty

    init(tree: FileTreeViewController) {
        self.tree = tree
    }

    /// Begin polling. Idempotent — `windowDidBecomeKey` can fire more than once without an
    /// intervening resign (a sheet dismissing, a tab switch inside a key window), and two
    /// timers would double the subprocess rate for nothing.
    func start() {
        guard timer == nil else { return }

        // 2s, deliberately slower than cwd-follow's 750ms, because the work is a fork/exec
        // rather than a syscall pair: measured ~6.6ms on this checkout but ~92ms on a real
        // 60k-file repo, and cost scales with *tree size* rather than with how many files
        // are dirty (`git-sidebar-external-mechanism-2026-07-31.md` §1.16). At 2s that is
        // under 5% of one background core in the bad case and invisible in the normal one.
        // The number is reasoned, not measured — the research says so about its own
        // recommendation — so it is a knob to turn if this ever shows up in Activity
        // Monitor, and dropping to refresh-on-focus-only is the escape hatch.
        let interval: TimeInterval = 2.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            // Same reasoning as `DirectoryFollow.start()`: a run-loop timer scheduled from
            // the main thread always fires on it, so the isolation is real and
            // `assumeIsolated` states that rather than hopping through a `Task`.
            MainActor.assumeIsolated { self.tick() }
        }

        // Poll immediately rather than waiting out the first interval. A window that has
        // just become key is exactly when its decorations are most likely to be stale —
        // the agent in the terminal beside the tree has been committing while you were
        // elsewhere — and a visible 2s lag on activation reads as lag, not as polling.
        tick()
    }

    /// Stop polling and release the timer.
    ///
    /// Called on resign-key, not on close, reusing `DirectoryFollow`'s rule verbatim: a
    /// background Space cannot be looked at, so decorating it is pure cost. An in-flight
    /// read is not cancelled — it will land, find `timer == nil` irrelevant, and update a
    /// snapshot nobody is looking at, which is cheaper than teaching the spawn to abort.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Read right now, outside the timer's rhythm — for the moments when waiting up to 2s
    /// would be visibly wrong, such as the tree being repointed at a different project.
    func pollNow() {
        tick()
    }

    private func tick() {
        guard let tree else { return stop() }
        guard !isReading else { return }
        isReading = true

        let rootURL = tree.root.url
        // Re-use the repository we already found only for the very same root we found it
        // for. The test this replaces asked "is the root still *inside* that repo?", which
        // stays true when the root moves into a nested one — see `repositoryRootPath`.
        let rootPath = rootURL.resolvingSymlinksInPath().path
        let known = repositoryRootPath == rootPath ? repository : nil

        // Off the main thread, because this is a fork/exec and up to ~92ms of it. On the
        // main thread that is a dropped frame every 2s on a large repo — the exact stutter
        // this app exists not to have. `GitRepository` and `GitStatusSnapshot` are
        // internal structs of `URL`/`String`/`Int`/enum members, so Swift infers their
        // `Sendable` conformance and neither needs an annotation (AFK.md, "Conventions").
        DispatchQueue.global(qos: .utility).async {
            let found = known ?? GitStatusReader.discoverRepository(at: rootURL)
            let read = found.flatMap { GitStatusReader.snapshot(of: $0) }
            Task { @MainActor in
                self.finish(rootPath: rootPath, repository: found, snapshot: read)
            }
        }
    }

    /// Land a completed read and redraw only if something actually changed.
    ///
    /// The whole snapshot is replaced rather than merged — see this file's header on why
    /// incremental invalidation is refused. `GitStatusSnapshot` is `Equatable` precisely so
    /// this comparison is possible: the common case is "a 2s tick found nothing new", and
    /// it must cost no AppKit work at all.
    private func finish(
        rootPath: String, repository found: GitRepository?, snapshot read: GitStatusSnapshot?
    ) {
        isReading = false
        let next = read ?? .empty
        let changed = found != repository || next != snapshot
        repository = found
        // The root this read was ISSUED for, not whatever the tree shows by the time it
        // lands. Those differ when `setRoot(_:)` moves the tree mid-read, and recording the
        // issued-for root is what makes that case correct itself: the next tick compares the
        // tree's new root against this one, finds them different, and re-discovers instead
        // of trusting an answer computed for somewhere else.
        repositoryRootPath = rootPath
        snapshot = next

        // `GOBLIN_PORTAL_DIAG=1` dumps the resolved git state to stderr, matching what
        // `TerminalPane` does for font and theme. This layer needs it more than either of
        // them: the parser is gated by `check-git-status.sh`, but everything between the
        // snapshot and a pixel — did a repository get found at all, is this the repository
        // you meant, did the tint simply fail to draw — is not reachable by any check
        // script in this repo (`git-sidebar-decision-2026-07-31.md` §5, Risk 5). Without a
        // line here, "no decorations appeared" has three indistinguishable causes.
        //
        // Logged on the first completed read even when nothing changed, and only on changes
        // after that. The first read is the one that says "this directory is not a
        // repository", which is both a completely normal answer and the single most likely
        // explanation for absent decorations — behind the `changed` guard it was the one
        // case that stayed silent, which is precisely backwards.
        if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil, changed || !hasLogged {
            hasLogged = true
            let root = found?.root.path ?? "<no repository>"
            FileHandle.standardError.write(Data("""
                [goblin-portal] git: root=\(root) \
                branch=\(branchSummary ?? "-") \
                files=\(next.entries.count) dirs=\(next.directories.count)

                """.utf8))
        }

        guard changed else { return }
        tree?.gitStatusDidChange()
    }

    /// The decoration for one file or directory, or nil when it is clean or outside a repo.
    ///
    /// Two dictionary lookups behind one string operation, called once per *visible* row —
    /// around forty — not once per file in the tree.
    func status(for url: URL) -> GitFileStatus? {
        guard let relative = repository?.relativePath(for: url), !relative.isEmpty else {
            return nil
        }
        return snapshot.status(forRelativePath: relative)
    }

    /// The full entry for one *file*, or nil for a clean path, a directory, or a path
    /// outside the repo.
    ///
    /// Separate from `status(for:)` rather than replacing it because the two answer for
    /// different things. A directory's decoration is a roll-up
    /// (`GitStatusSnapshot.directories`) synthesised from its children, so it has a status
    /// but no entry — there is no single `isStaged` or `originalPath` for "this folder
    /// contains changes". Only `entries` can answer those, so only files get a sentence.
    func entry(for url: URL) -> GitFileEntry? {
        guard let relative = repository?.relativePath(for: url), !relative.isEmpty else {
            return nil
        }
        return snapshot.entries[relative]
    }

    /// The branch line for the sidebar header, or nil when there is nothing to say.
    ///
    /// Ahead/behind are omitted entirely when they are nil, which is not the same as zero:
    /// `# branch.ab` is absent from git's output on a branch with no upstream, and
    /// rendering that as "0/0" would tell the user they are in sync with something that
    /// does not exist. Every branch an agent workflow creates starts in that state.
    var branchSummary: String? {
        guard repository != nil else { return nil }
        if snapshot.isDetached { return "detached HEAD" }
        guard let branch = snapshot.branch else { return nil }
        var summary = branch
        if let ahead = snapshot.ahead, ahead > 0 { summary += "  ↑\(ahead)" }
        if let behind = snapshot.behind, behind > 0 { summary += "  ↓\(behind)" }
        // Nil is not zero, and until this line the header rendered them identically — a
        // branch in sync with its upstream and a branch with no upstream at all both drew
        // a bare name. The model keeps them apart; the one caller threw that away.
        //
        // Gated on `hasUpstream`, never on `ahead == nil`: git omits `# branch.ab` both
        // when no upstream exists AND when one exists whose commit is absent (a remote
        // branch deleted and pruned), so the nil test called that second state "no
        // upstream" while `git push` there still resolved a destination without `-u` —
        // wrong on exactly the criterion the word is justified by. See `hasUpstream`.
        //
        // The *absence* earns the word, not the in-sync case: it changes what the next
        // command does, whereas "in sync" is the quiet default a reader already infers
        // from bare arrows being absent. Marking the common-but-uninformative state
        // instead would put a mark on nearly every row of this user's workflow, which is
        // the noise failure the decorations were careful to avoid.
        if !snapshot.hasUpstream { summary += "  no upstream" }
        return summary
    }
}

// MARK: - The tree's side

extension FileTreeViewController {
    /// Start decorating, creating the follower on first use.
    ///
    /// Lazily created rather than built in `init`, matching `startDirectoryFollow()`: a
    /// Space that is never made key never needs one.
    func startGitFollow() {
        if gitFollow == nil { gitFollow = GitStatusFollow(tree: self) }
        gitFollow?.start()
    }

    /// Stop decorating. Safe to call when never started.
    func stopGitFollow() {
        gitFollow?.stop()
    }

    /// Read git again immediately — called when the tree is repointed at a new directory,
    /// where waiting out the 2s tick would show the old project's decorations against the
    /// new project's files. That is worse than showing none, because it is *wrong* rather
    /// than merely late.
    func gitFollowPollNow() {
        gitFollow?.pollNow()
    }

    /// The decoration for a row, asked per row at draw time.
    func gitStatus(for node: FileNode) -> GitFileStatus? {
        gitFollow?.status(for: node.url)
    }

    /// The row's full entry, for the channels that can hold more than a letter.
    /// Nil for directories by construction — see `GitStatusFollow.entry(for:)`.
    func gitEntry(for node: FileNode) -> GitFileEntry? {
        gitFollow?.entry(for: node.url)
    }

    /// A new snapshot landed: repaint the rows that exist and update the header.
    ///
    /// Deliberately **not** `reloadData()`. That discards the user's expanded rows —
    /// `refresh()` has to snapshot and restore them for exactly this reason — and a
    /// decoration change alters nothing structural: same nodes, same children, same
    /// disclosure. So this walks the rows AppKit has actually realised and re-applies the
    /// decoration through the same function `viewFor` uses, which keeps one description of
    /// how a row looks rather than two that can drift.
    func gitStatusDidChange() {
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileNode,
                let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? NSTableCellView
            else { continue }
            applyGitDecoration(to: cell, for: node)
        }
        gitHeader.update(summary: gitFollow?.branchSummary)
        notifySourceControlOfChange()
    }
}
