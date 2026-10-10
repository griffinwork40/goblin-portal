//
//  FileTreeViewController+Loading.swift
//  The tree's reloads: the async `refresh()` (window became key), the async listing
//  behind `setRoot(_:)`, and the synchronous `refreshSynchronously()` every file
//  operation needs (#158).
//
//  WHY OFF MAIN. The baseline (.afk/research/tree-refresh-baseline-2026-10-09.md)
//  measured `refresh()` at p50 86 ms on a 42k-entry tree with 300 directories expanded
//  — a dropped-frame stall on every window activation — and a single `setRoot` listing
//  on an SMB/iCloud volume can take seconds. The listing is pure I/O over value types
//  (`DirectoryEntry`), so it moves to a background queue; everything that touches a
//  `FileNode` or the outline stays on the main actor.
//
//  SHAPE (copied from +Git.swift's `GitStatusFollow.pollNow()`): snapshot on main →
//  `DispatchQueue.global()` lists into an immutable `[URL: [DirectoryEntry]]` →
//  `Task { @MainActor in }` lands it. The lister closure is READ on main
//  (`DirectoryListing.lister` is a `@MainActor` var) and passed into the background
//  block as a value; its `@Sendable` type is what lets it cross (DirectoryListing.swift,
//  `lister`).
//
//  STALENESS. Every issue bumps `treeLoadGeneration`; a landing whose generation is no
//  longer current is DROPPED. The token is bumped by: a newer `refresh()`, a newer
//  `setRoot` listing, `refreshSynchronously()` (so every file mutation, and every edit
//  ending — `finishEditReplay` goes through it), placeholder insertion
//  (+Mutation.swift `insertPlaceholder`), and setRoot returning to the displayed root.
//  Teardown drops results through `[weak self]`.
//
//  EDITS. A CURRENT result that lands while an inline edit is open is not applied (it
//  would reload the outline under the editor). It sets `pendingReload` and returns.
//  The flag is a RECORD, not a trigger: nothing branches on it. The replay is
//  unconditional — every edit ends in `finishEditReplay` → `refreshAfterMutation` →
//  `refreshSynchronously()`, because every edit end must re-read anyway (a placeholder
//  to drop, a rename to show) — and `finishEditReplay` clears it. It exists so a gate
//  can tell "deferred" from "dropped": check-tree-refresh EDIT-DEFER asserts it, and the
//  `drop-during-edit` falsify mutant (which returns without setting it) fails there.
//
//  TWO ROOTS. `root` is the directory the tree is FOR; `displayedRoot` is the tree the
//  outline is SHOWING. They differ only while a setRoot listing is in flight, when the
//  old tree stays on screen (FileTreeViewController.swift `displayedRoot`). They
//  converge in `adoptRoot()` — on that listing's landing, or synchronously in
//  `refreshSynchronously()` — and a reveal asked for in between waits for it
//  (`pendingReveal`, +Reveal.swift).
//
//  STILL SYNCHRONOUS, deliberately (each needs its children in the same turn):
//  `loadView` (first frame, FileTreeViewController.swift `root.reloadChildren()`),
//  `reveal(_:)` (+Reveal.swift), `walk(to:)` and `insertPlaceholder` (+Mutation.swift),
//  disclosure expansion (`shouldExpandItem`, +OutlineView.swift), the filter's
//  `collectVisible` (+Filter.swift), and `refreshAfterMutation` via
//  `refreshSynchronously()` below — which, mid-setRoot, also lists the new root.
//  A LANDING never lists: it only applies what the background listed
//  (check-tree-refresh NO-MAIN-LISTING).
//

import AppKit
import ObjectiveC

nonisolated(unsafe) private var treeLoadGenerationKey: UInt8 = 0

extension FileTreeViewController {

    /// Bumped by every load issue and every invalidation; an async landing applies only
    /// if it still matches. Associated-object storage, like `pendingRoot` (+Mutation.swift),
    /// because Swift extensions cannot add stored properties.
    var treeLoadGeneration: Int {
        get { objc_getAssociatedObject(self, &treeLoadGenerationKey) as? Int ?? 0 }
        set { objc_setAssociatedObject(self, &treeLoadGenerationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Make any async listing currently in flight land as stale. Called by every path
    /// that changes the tree synchronously, so a late result can never overwrite it.
    func invalidatePendingLoads() { treeLoadGeneration += 1 }

    /// Re-read the tree, preserving expansion and selection — ASYNC: the directories are
    /// listed off the main thread and landed later.
    ///
    /// Called when the Space's window becomes key rather than driven by FSEvents.
    /// That is a deliberate first cut, and it is well matched to this app's actual
    /// job: the thing mutating these files is an agent running in the terminal
    /// beside the tree, so "you came back to this window" is almost exactly the
    /// moment the tree is stale. FSEvents is the obvious upgrade if it ever feels behind.
    ///
    /// Async is safe HERE because nothing after the call depends on the new children.
    /// `refreshAfterMutation` is the opposite — it walks, expands and reveals immediately
    /// after — so it calls `refreshSynchronously()` instead.
    func refresh() {
        guard !isEditingInline else {
            TreeRefreshTiming.note(site: "refresh", "deferred (inline edit active)")
            pendingReload = true; return
        }
        let start = ContinuousClock.now
        // Git status is stale for exactly the same reason the tree is, at exactly the same
        // moment, so the two share one trigger. `start()` is idempotent and polls once
        // immediately. The stop half is in `SpaceViewController.windowDidResignKey()`.
        startGitFollow()
        issueListing(of: root.loadedDirectories(), site: "refresh", start: start)
    }

    /// The pre-#158 `refresh()`: list on the main thread, reload, restore. Every file
    /// operation lands through this (`refreshAfterMutation`) because its walk/expand/
    /// reveal need the new children this turn. Also invalidates any async listing in
    /// flight: that listing predates the mutation and must not land over it.
    ///
    /// A setRoot listing in flight (`displayedRoot !== root`) is ADOPTED here, not
    /// dropped (I3, case SYNC-ADOPT): the new root is listed now, on main, and shown.
    /// Invalidating it and re-reading only the displayed tree would strand the sidebar
    /// on the old directory with nothing left to move it. Listing it synchronously is
    /// the cheaper of the two honest options — one directory, on a path that already
    /// lists every expanded directory on main — and the alternative (keep B's listing
    /// valid and refresh A under it) would let a listing that predates this mutation
    /// land afterwards, which is exactly what the invalidation exists to prevent.
    func refreshSynchronously() {
        guard !isEditingInline else {
            TreeRefreshTiming.note(site: "refreshSync", "deferred (inline edit active)")
            pendingReload = true; return
        }
        invalidatePendingLoads()
        if displayedRoot !== root {
            TreeRefreshTiming.measure(site: "refreshSync-adopt", expandedCount: 0) {
                root.reloadChildren()
                adoptRoot()
            }
            startGitFollow()
            return
        }
        let expanded = expandedNodes()
        let selectedURL = (outlineView.item(atRow: outlineView.selectedRow) as? FileNode)?.url
        TreeRefreshTiming.measure(site: "refreshSync", expandedCount: expanded.count) {
            root.reloadChildren()
            outlineView.reloadData()
            restore(expanded: expanded, selectedURL: selectedURL)
        }
        startGitFollow()
    }

    /// `setRoot(_:)`'s listing. The caller has already swapped in the new, childless
    /// `root`; the outline is NOT reloaded here. It keeps drawing `displayedRoot` — the
    /// previous tree, still retained, so its rows stay valid items — until the listing
    /// lands and `adoptRoot()` swaps both in one `reloadData()` (I1, case
    /// NO-EMPTY-FRAME). Reloading here drew at least one empty frame on every
    /// cwd-follow re-root, and on an SMB/iCloud volume left the tree blank for seconds.
    func beginRootLoad() {
        issueListing(of: [root.url], site: "setRoot", start: ContinuousClock.now)
    }

    /// Make the outline show `root`: ONE `reloadData()` from the old tree's rows to the
    /// new tree's, then the reveal that was queued while they differed (I2, case
    /// REVEAL-IN-FLIGHT). No expansion or selection is carried across — a different
    /// directory has none to carry (`setRoot(_:)`). An active filter belonged to the old
    /// tree, so it is cleared the way `setRoot(_:)` clears one.
    func adoptRoot() {
        displayedRoot = root
        if !filterQuery.isEmpty {
            filterField.stringValue = ""
            filterQuery = ""; visibleURLs = nil; preFilterExpansion = nil
        }
        outlineView.reloadData()
        performPendingReveal()
    }

    // MARK: - Issue and land

    private func issueListing(of dirs: [URL], site: String, start: ContinuousClock.Instant) {
        treeLoadGeneration += 1
        let generation = treeLoadGeneration
        let issuedRoot = root
        let lister = DirectoryListing.lister
        let issueMs = TreeRefreshTiming.ms(since: start)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listStart = ContinuousClock.now
            var listings: [URL: [DirectoryEntry]] = [:]
            for dir in dirs { listings[dir] = lister(dir) }
            let listMs = TreeRefreshTiming.ms(since: listStart)
            Task { @MainActor in
                TreeRefreshTiming.record(site: site + "-list", expandedCount: dirs.count, ms: listMs)
                self?.land(listings, generation: generation, root: issuedRoot, site: site, issueMs: issueMs)
            }
        }
    }

    private func land(
        _ listings: [URL: [DirectoryEntry]], generation: Int, root issuedRoot: FileNode,
        site: String, issueMs: Double
    ) {
        guard generation == treeLoadGeneration, issuedRoot === root else {
            TreeRefreshTiming.note(site: site, "dropped (stale)"); return
        }
        guard !isEditingInline else {
            TreeRefreshTiming.note(site: site, "deferred (inline edit active)")
            pendingReload = true; return
        }
        let start = ContinuousClock.now
        // `root` was issued as the new root of a setRoot (or a refresh issued while one
        // was in flight): it has no rows to preserve, so adopt it outright (I1).
        guard displayedRoot === root else {
            root.applyListings(listings)
            adoptRoot()
            TreeRefreshTiming.record(
                site: site + "-adopt", expandedCount: 0, ms: issueMs + TreeRefreshTiming.ms(since: start))
            return
        }
        let expanded = expandedNodes()
        let selectedURL = (outlineView.item(atRow: outlineView.selectedRow) as? FileNode)?.url
        root.applyListings(listings)
        outlineView.reloadData()
        restore(expanded: expanded, selectedURL: selectedURL)
        // Main-thread cost only: the issue half plus this landing. The listing itself
        // is logged separately as `<site>-list` above.
        TreeRefreshTiming.record(
            site: site, expandedCount: expanded.count, ms: issueMs + TreeRefreshTiming.ms(since: start))
    }

    private func expandedNodes() -> [FileNode] {
        (0..<outlineView.numberOfRows)
            .compactMap { outlineView.item(atRow: $0) as? FileNode }
            .filter { outlineView.isItemExpanded($0) }
    }

    /// Re-expand by identity (which is why reconciliation must keep unchanged nodes)
    /// and reselect by URL.
    private func restore(expanded: [FileNode], selectedURL: URL?) {
        for node in expanded { outlineView.expandItem(node) }
        guard let selectedURL else { return }
        for row in 0..<outlineView.numberOfRows
        where (outlineView.item(atRow: row) as? FileNode)?.url == selectedURL {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            break
        }
    }
}
