//
//  FileTreeViewController+Mutation.swift
//  The shared machinery behind every file-tree mutation: which rows an action
//  targets, how the tree reloads afterwards, how failures reach the user, and the
//  two seams a behavioural gate can drive (`confirmTrash`, `presentAlert`).
//
//  Separate from `+FileOps.swift` because that file is the edit lifecycle and the
//  responder actions — the *what* — and this is the *how it lands*: one reload path
//  (`refreshAfterMutation`) and one error path (`reportFileOpError`), so the drag-drop
//  extension and the actions cannot drift apart again. Before this, each action
//  called `reloadData()` itself (collapsing the tree) and beeped on failure.
//

import AppKit
import ObjectiveC

nonisolated(unsafe) private var pendingRootKey: UInt8 = 0

extension FileTreeViewController {

    // MARK: Seams

    /// Asked before anything goes to the Trash; returns true to proceed. A seam so a
    /// gate can answer without a modal: assign a closure, run `performTrash`, assert.
    /// The default names the item(s), because "Move 3 items?" with no names is the
    /// confirmation people click through without reading.
    static var confirmTrash: @MainActor ([URL]) -> Bool = { urls in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? "Move “\(urls[0].lastPathComponent)” to the Trash?"
            : "Move \(urls.count) items to the Trash?"
        // List at most ten names; a longer list would push the buttons off-screen.
        let names = urls.prefix(10).map(\.lastPathComponent).joined(separator: "\n")
        alert.informativeText = urls.count > 10 ? names + "\n…" : names
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// How a finished error alert is shown. A seam for the same reason as
    /// `confirmTrash`: a gate replaces it to capture the alert instead of blocking.
    static var presentAlert: @MainActor (NSAlert) -> Void = { _ = $0.runModal() }

    /// A root `setRoot(_:)` was asked to show while an inline edit was open (H4).
    /// Replayed by `finishEditReplay` once the edit ends; nil when none is waiting.
    var pendingRoot: URL? {
        get { objc_getAssociatedObject(self, &pendingRootKey) as? URL }
        set { objc_setAssociatedObject(self, &pendingRootKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // MARK: Errors

    /// The single failure path for file operations (R10): an alert the user cannot
    /// miss, where a beep said only "something", and a stderr line under
    /// `GOBLIN_PORTAL_DIAG` so a failed operation is greppable after the fact.
    func reportFileOpError(_ message: String, _ error: Error?) {
        if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
            let detail = error.map { " (\($0.localizedDescription))" } ?? ""
            FileHandle.standardError.write(Data("[goblin-portal] fileops: \(message)\(detail)\n".utf8))
        }
        let alert = error.map { NSAlert(error: $0) } ?? NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let ce = error as? CocoaError, ce.code == .fileWriteFileExists {
            // CocoaError's own text for this code is generic; say what actually happened.
            alert.informativeText = "An item with that name already exists. Nothing was overwritten."
        } else if let error {
            alert.informativeText = error.localizedDescription
        }
        Self.presentAlert(alert)
    }

    // MARK: Targets

    /// What an action applies to (H2). A context-menu item carries the right-clicked
    /// node in `representedObject`, and that wins over the selection, which may be a
    /// different row entirely. If the clicked node is part of a multi-selection, the
    /// whole selection is the target (Finder's rule). Keyboard and menu-bar senders
    /// carry no node and fall back to the selection.
    func targetNodes(_ sender: Any?) -> [FileNode] {
        let selected = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileNode }
        guard let clicked = (sender as? NSMenuItem)?.representedObject as? FileNode else { return selected }
        return selected.contains { $0 === clicked } ? selected : [clicked]
    }

    /// The directory an action creates or pastes into: the target itself when it is a
    /// directory, its parent when it is a file, the root when nothing is targeted.
    func targetDirectory(_ sender: Any?) -> URL {
        let node = ((sender as? NSMenuItem)?.representedObject as? FileNode)
            ?? (outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as? FileNode : nil)
        // The DISPLAYED root: that is the tree the user aimed at (`displayedRoot`).
        guard let node else { return displayedRoot.url }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    /// Drop any URL that lives inside another URL in the list: trashing or moving a
    /// folder already takes its selected children with it, and acting on them again
    /// afterwards would fail on a path that no longer exists.
    func topLevel(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            !urls.contains { $0 != url && FileOperationPolicy.isDescendant(url: url, of: $0) }
        }
    }

    /// Symlink-resolved, standardised location: `/tmp/x` and `/private/tmp/x` are one
    /// place, and every cycle or same-folder check must agree on that (S-4).
    func resolvedLocation(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardized }

    /// The first name based on `base` that is free in `directory` (M1).
    func freeName(_ base: String, in directory: URL) -> String {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return FileOperationPolicy.availableName(base: base, existingNames: existing)
    }

    // MARK: Reload

    /// Every post-operation reload goes through here (H5). `refreshSynchronously()` keeps the
    /// expansion and selection of rows whose paths survived; `rebasing` carries the
    /// expansion of renamed or moved directories across to their new paths, which
    /// identity-based restoration cannot do because the node is new. Then the
    /// affected row is revealed and selected.
    func refreshAfterMutation(select url: URL?, rebasing moves: [(URL, URL)] = []) {
        let expanded = (0..<outlineView.numberOfRows)
            .compactMap { outlineView.item(atRow: $0) as? FileNode }
            .filter { outlineView.isItemExpanded($0) }
            .map(\.url.path)
        var rebased: [URL] = []
        for (old, new) in moves {
            for path in expanded where path == old.path || path.hasPrefix(old.path + "/") {
                rebased.append(URL(fileURLWithPath: new.path + path.dropFirst(old.path.count)))
            }
        }
        // The span wraps the whole body — rebase walk, refresh, expansion replay, and
        // reveal — so the logged elapsed time matches the actual mutation-reload cost.
        // `refreshSynchronously()` logs its own nested `refreshSync` span, so every file
        // operation prints TWO lines and they can be near-equal: refreshSync is the
        // reload alone, afterMutation adds the walk and reveal. Read the difference as
        // their cost; do not sum them (TreeRefreshTiming's header lists every site).
        TreeRefreshTiming.measure(site: "afterMutation", expandedCount: expanded.count) {
            // SYNCHRONOUS on purpose: the walk/expand/reveal below need the new children
            // in place this turn. It also invalidates any async refresh in flight (#158).
            refreshSynchronously()
            // Shallowest first, so each parent is expanded (and loaded) before its child.
            for dir in rebased.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) {
                if let node = walk(to: dir) { outlineView.expandItem(node) }
            }
            if let url { reveal(url) }
        }
    }

    /// End-of-edit replay: the reload any blocked `refresh()` asked for, then the root
    /// any blocked `setRoot(_:)` asked for (H4).
    func finishEditReplay(select url: URL?, rebasing moves: [(URL, URL)] = []) {
        pendingReload = false
        refreshAfterMutation(select: url, rebasing: moves)
        if let next = pendingRoot {
            pendingRoot = nil
            setRoot(next)
        }
    }

    /// The node for `url`, expanding each ancestor on the way so it is a visible row.
    /// Walks `displayedRoot`, not `root`: it expands ROWS, so it must walk the tree the
    /// outline is showing (they differ only while a setRoot listing is in flight). Its
    /// callers are `refreshAfterMutation` — after `refreshSynchronously()`, which has
    /// converged the two — and `insertPlaceholder`, which edits the tree on screen.
    private func walk(to url: URL) -> FileNode? {
        let root = displayedRoot
        let rootCount = root.url.pathComponents.count
        guard url.pathComponents.count > rootCount,
              url.path.hasPrefix(root.url.path + "/") else { return nil }
        // R1.2: default APFS volumes are case-insensitive, so a URL whose component
        // case differs from the on-disk name would silently miss every node. The
        // cached value is authoritative for the walk (volume properties do not change
        // while the tree is open). Populate the cache here on first access; cleared
        // in setRoot(_:) whenever the root moves to a different directory. Keeps exact
        // (case-sensitive) matching on genuine CS volumes, where two siblings can share
        // the same spelling under different cases and picking the wrong one is a bug.
        // The cache describes `self.root`'s volume; mid-setRoot the walked tree is the
        // OLD root, which may sit elsewhere, so ask without caching in that window.
        if caseSensitiveFS == nil, root === self.root {
            caseSensitiveFS = FileOperationPolicy.caseSensitiveFSAtRoot(root.url)
        }
        let caseSensitive = root === self.root
            ? (caseSensitiveFS ?? false) : FileOperationPolicy.caseSensitiveFSAtRoot(root.url)
        var current = root
        for component in url.pathComponents.dropFirst(rootCount) {
            if current.children == nil { current.reloadChildren() }
            guard let child = current.children?.first(where: {
                caseSensitive
                    ? $0.name == component
                    : $0.name.caseInsensitiveCompare(component) == .orderedSame
            }) else { return nil }
            if current !== root { outlineView.expandItem(current) }
            current = child
        }
        return current
    }

    /// Show a not-yet-on-disk row under its parent and open the editor on it. The
    /// placeholder disappears on the next refresh unless the commit created it.
    /// Against `displayedRoot` for `walk(to:)`'s reason. Mid-setRoot, the invalidation
    /// below drops the new root's listing; that cannot strand the sidebar, because the
    /// edit always ends in `finishEditReplay` → `refreshSynchronously()`, which adopts it.
    func insertPlaceholder(url: URL, isDirectory: Bool) {
        let root = displayedRoot
        let parentURL = url.deletingLastPathComponent()
        // The root has no row; anything else must be walked to (and expanded).
        let parent: FileNode? = parentURL.path == root.url.path ? root : walk(to: parentURL)
        guard let parent else { return }
        if parent !== root { outlineView.expandItem(parent) }
        parent.reloadChildren()
        // An async listing issued before this would land without the placeholder and
        // reload the outline under the editor about to open on it — invalidate it (#158).
        invalidatePendingLoads()
        let placeholder = FileNode(url: url, isDirectory: isDirectory)
        parent.insertChild(placeholder)
        // `reloadItem(nil, …)` is how the root's children are reloaded.
        outlineView.reloadItem(parent === root ? nil : parent, reloadChildren: true)
        beginInlineEdit(for: placeholder, isNew: true)
    }
}
