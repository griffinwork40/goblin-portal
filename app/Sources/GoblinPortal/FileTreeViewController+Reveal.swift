//
//  FileTreeViewController+Reveal.swift
//  Auto-reveal: select and scroll to the row for a file the editor just activated.
//
//  Moved out of `FileTreeViewController.swift` (was :283-349) whole, unchanged, when
//  that file hit the 350-line ceiling and #158 needed room for the async-loading call
//  sites. It is its own concern — a lazy, SYNCHRONOUS walk from the root to one URL —
//  and it deliberately stays synchronous: it must select the row in the same turn it
//  was asked to (see `FileTreeViewController+Loading.swift` for the full list of paths
//  that keep reading on the main thread, and why).
//

import AppKit

extension FileTreeViewController {

    // MARK: - Auto-reveal

    /// Scroll to and select the node for `url` without stealing keyboard focus.
    ///
    /// Called from `SpaceViewController+Delegates.swift` when the active document
    /// changes (tab-switch). Only `FileViewerPane` documents carry a file URL that
    /// maps to a tree node; terminal tabs are deliberately skipped at the call site
    /// (`SpaceViewController+Delegates.swift`).
    ///
    /// The method walks the tree lazily — expanding and loading directories as it
    /// descends — so it works even if the user has never opened the containing folder.
    /// If the URL is outside the current root, the method silently returns without
    /// moving the root: the sidebar only shows files under the Space's root, and
    /// moving the root to follow an unrelated file would be disorienting.
    ///
    /// Focus is deliberately NOT taken: `view.window?.makeFirstResponder(outlineView)`
    /// would yank the cursor out of the editor, which is the last thing a user wants
    /// while typing. The sidebar updates its selection in the background.
    func reveal(_ url: URL) {
        // Guard: URL must be inside the current tree root.
        let rootPath = root.url.resolvingSymlinksInPath().path
        let targetPath = url.resolvingSymlinksInPath().path
        guard targetPath.hasPrefix(rootPath + "/") || targetPath == rootPath else { return }

        // Walk the path components between root and target, expanding each directory
        // as we go so the child nodes are loaded before we try to show them.
        let components = url.pathComponents
        let rootComponents = root.url.pathComponents
        guard components.count > rootComponents.count else { return }

        // R1.2: default APFS volumes are case-insensitive; a URL whose component case
        // differs from the on-disk name silently misses every node. Use the cached
        // result (populated on first walk/reveal, cleared in setRoot when the root
        // moves to a new directory). Genuine CS volumes keep exact matching so we
        // never pick the wrong sibling when two names differ only by case.
        if caseSensitiveFS == nil { caseSensitiveFS = FileOperationPolicy.caseSensitiveFSAtRoot(root.url) }
        let caseSensitive = caseSensitiveFS ?? false
        var current: FileNode = root
        // Skip the root's own components; descend through the remainder.
        let descendantComponents = components.dropFirst(rootComponents.count)
        for (index, component) in descendantComponents.enumerated() {
            // Ensure children are loaded at this level.
            if current.children == nil { current.reloadChildren() }
            let isLastComponent = index == descendantComponents.count - 1
            guard let child = current.children?.first(where: {
                caseSensitive
                    ? $0.name == component
                    : $0.name.caseInsensitiveCompare(component) == .orderedSame
            }) else {
                return  // File not found in tree — outside root or filtered out
            }
            if !isLastComponent {
                // Expand intermediate directories so their children are visible.
                outlineView.expandItem(child)
            }
            current = child
        }

        // `current` is now the target node. Select it and scroll it visible.
        // `row(forItem:)` returns -1 when the item is not currently in the outline
        // (e.g. its parent directory was never expanded). After the walk above it
        // should be present, but guard defensively.
        let row = outlineView.row(forItem: current)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }
}
