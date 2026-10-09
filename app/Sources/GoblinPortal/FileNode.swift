//
//  FileNode.swift
//  The sidebar tree's model: one lazily-populated directory node.
//
//  Its own file because it is the only part of the file tree that is not view
//  code — a URL, two flags and a directory read, with no NSOutlineView and no
//  AppKit control anywhere in it (hence `Foundation`, not `AppKit`, below). It is
//  also where the tree's load-bearing invariant lives: `reloadChildren()` reuses
//  existing children by URL, so node *identity* survives a reload, and that is the
//  only reason `FileTreeViewController.refresh()` can put the user's expanded rows
//  back — `NSOutlineView` tracks disclosure state by item identity. That argument
//  deserves to be readable without the cell layout and menu building it used to
//  sit inside.
//

import Foundation

/// A lazily-populated directory node.
///
/// Children are loaded on first disclosure, not up front: rooting a Space at
/// `$HOME` and eagerly walking it would stat tens of thousands of files before the
/// first frame.
@MainActor
final class FileNode {
    let url: URL
    let isDirectory: Bool
    /// Hidden according to the *filesystem*, not according to a name check.
    /// `.isHiddenKey` is true for both ways macOS hides something — the dot-prefix
    /// convention (`.afk`) and the `chflags hidden` bit on an undotted name
    /// (`~/Library`) — so one read covers both where `hasPrefix(".")` would miss
    /// half. Verified on this machine: Library isHidden=true/dot=false, .afk
    /// isHidden=true/dot=true, Projects false/false.
    let isHidden: Bool
    private(set) var children: [FileNode]?

    /// `isHidden` defaults to false for the root, which is never sorted against
    /// siblings — only children are.
    init(url: URL, isDirectory: Bool, isHidden: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.isHidden = isHidden
    }

    var name: String { url.lastPathComponent }

    /// Insert a transient placeholder child at `index` (or append if nil).
    /// Used by `FileTreeViewController+FileOps` to show a new-file/folder
    /// row before the file exists on disk. The placeholder is removed when
    /// `reloadChildren()` is next called (since the URL won't exist yet).
    func insertChild(_ node: FileNode, at index: Int? = nil) {
        if children == nil { children = [] }
        if let i = index, i <= (children?.count ?? 0) {
            children?.insert(node, at: i)
        } else {
            children?.append(node)
        }
    }

    /// Read the directory, **reusing existing child nodes by URL**. Identity has to
    /// survive a refresh or `NSOutlineView` loses every expanded row: it tracks
    /// disclosure state by item identity, so handing it fresh objects for unchanged
    /// paths collapses the whole tree on each reload.
    func reloadChildren() {
        guard isDirectory else { return }
        let existing = Dictionary(
            (children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })

        // Delegate the FileManager call and URL re-rooting to the seam so the
        // test harness can replace `DirectoryListing.lister` with a controlled
        // stub (DirectoryListing.swift).  Production behaviour is identical:
        // same keys, same re-rooting, same isVisible filter.
        let entries = DirectoryListing.lister(url)

        children =
            entries
            .map { entry -> FileNode in
                let normURL = entry.url
                let isDir = entry.isDirectory
                let isHidden = entry.isHidden
                // Reuse check: look up by the normalized URL so identity survives
                // a refresh even when FileManager changes its symlink resolution.
                // Both facts gate reuse. A reused node is returned as-is, so a flag
                // that flipped on disk would otherwise never reach the UI.
                if let reused = existing[normURL], reused.isDirectory == isDir,
                    reused.isHidden == isHidden
                {
                    return reused
                }
                return FileNode(url: normURL, isDirectory: isDir, isHidden: isHidden)
            }
            .sorted { lhs, rhs in
                // Directories first, then case-insensitive name — Finder's order,
                // and the one every file tree a developer already uses follows.
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                // Then hidden entries LAST within each group. They stay *shown* —
                // see `isVisible`; hiding `.github` or `.env` in a terminal-first
                // IDE would be obstructive — but `localizedStandardCompare` orders
                // "." ahead of letters, so plain name order buries the real content
                // behind them. Measured on this machine's $HOME: 53 dot-directories
                // sorted above `Projects/`, 57% of the first screen, every one of
                // them a tool cache nobody browses.
                if lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        // Recurse only into what the user already opened, so a refresh costs the
        // same as the disclosure state and not the size of the tree.
        for child in children ?? [] where child.children != nil {
            child.reloadChildren()
        }
    }

    /// Dotfiles are deliberately **shown**: this is a developer tool, and hiding
    /// `.github`, `.env` or this project's own `.afk/` in a terminal-first IDE
    /// would be actively obstructive. Only the two entries nobody ever wants to
    /// browse are dropped. A config field can generalise this later.
    // isVisible moved to DirectoryListing.isVisible (DirectoryListing.swift:88-91)
    // and still called from DirectoryListing.list(_:). The method is intentionally
    // removed from FileNode to keep the listing logic in one place.
}
