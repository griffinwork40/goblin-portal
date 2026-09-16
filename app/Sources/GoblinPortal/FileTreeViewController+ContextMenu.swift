//
//  FileTreeViewController+ContextMenu.swift
//  The file tree's right-click menu: what it offers, and what each item does.
//
//  Its own file because it is one whole concern with one reason to change — the
//  affordances a row offers — and because the controller had no room left. At 300 lines it
//  was inside `check-file-size.sh`'s warning band with a sidebar git header still to land,
//  and AFK.md's rule for that is to find the seam and pull a concern out rather than
//  shave lines. This menu is the cleanest seam in the file: nine methods that talk to the
//  delegate, the pasteboard and Finder, and touch nothing the controller needs.
//
//  Pure move, with one simplification. `NSMenuDelegate`'s single member used to forward to
//  a private `menuNeedsUpdateImpl` for no reason except that the conformance and the
//  implementation sat in different halves of one file; they are together now, so the
//  indirection is gone. No behaviour changed.
//

import AppKit

extension FileTreeViewController: NSMenuDelegate {
    /// Built per right-click rather than once, so the item set can depend on what
    /// was actually clicked (a directory has nothing to "Open" in a viewer).
    ///
    /// Every action carries its `FileNode` in `representedObject` instead of
    /// re-reading `clickedRow` when it fires: the menu outlives the click, and a
    /// refresh landing in between would silently retarget the action at whatever
    /// row moved into that index.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode else { return }

        if !node.isDirectory {
            menu.addItem(withTitle: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "")
            menu.addItem(
                withTitle: "Insert Path in Terminal", action: #selector(menuInsertPath(_:)),
                keyEquivalent: "")
        }
        // Offered for files as well as directories — it resolves a file to its parent
        // (`menuNewTerminal`), which is what "here" means when you right-click a file
        // you are about to run something against. Finder's own "New Terminal at
        // Folder" service is directory-only and that is a worse rule in a project
        // tree, where the row your eye is on is usually the file, not its folder.
        menu.addItem(
            withTitle: "New Terminal Here", action: #selector(menuNewTerminal(_:)),
            keyEquivalent: "")
        // Right beside "New Terminal Here": both answer "here", one by starting a
        // fresh shell at this path, the other by redirecting the shell you already
        // have. Same file-to-parent resolution as that item, for the same reason —
        // see `menuChangeDirectory`.
        menu.addItem(
            withTitle: "cd Here", action: #selector(menuChangeDirectory(_:)),
            keyEquivalent: "")
        // The separator moved out of the `!isDirectory` block rather than being
        // duplicated: it was conditional only because a directory row had nothing
        // above it to separate, and now every row does. The in-app actions stay above
        // it, the two hand-offs to the rest of macOS stay below.
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Reveal in Finder", action: #selector(menuReveal(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: "Copy Path", action: #selector(menuCopyPath(_:)), keyEquivalent: "")

        for item in menu.items where item.action != nil {
            item.target = self
            item.representedObject = node
        }
    }

    private func node(from sender: Any?) -> FileNode? {
        (sender as? NSMenuItem)?.representedObject as? FileNode
    }

    @objc private func menuOpen(_ sender: Any?) {
        guard let node = node(from: sender) else { return }
        delegate?.fileTree(self, didActivate: node.url)
    }

    @objc private func menuInsertPath(_ sender: Any?) {
        guard let node = node(from: sender) else { return }
        delegate?.fileTree(self, didRequestPathInsert: node.url)
    }

    /// Resolve the clicked row to a directory here, in the one place that knows what
    /// was clicked, rather than passing the raw node and making the Space re-derive
    /// it: `deletingLastPathComponent()` on a directory URL would climb to its
    /// *parent*, so a receiver that guessed wrong would open every folder's terminal
    /// one level too high.
    @objc private func menuNewTerminal(_ sender: Any?) {
        guard let node = node(from: sender) else { return }
        let directory = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        delegate?.fileTree(self, didRequestNewTerminalAt: directory)
    }

    /// Same file-to-parent resolution as `menuNewTerminal`, and for the same
    /// reason: the row under a right-click here is usually the file you are about
    /// to work on, not its enclosing folder, so `cd`-ing to a *file* would fail —
    /// this makes it just work instead of asking the container to handle that.
    @objc private func menuChangeDirectory(_ sender: Any?) {
        guard let node = node(from: sender) else { return }
        let directory = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        delegate?.fileTree(self, didRequestChangeDirectory: directory)
    }

    @objc private func menuReveal(_ sender: Any?) {
        guard let node = node(from: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func menuCopyPath(_ sender: Any?) {
        guard let node = node(from: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }
}
