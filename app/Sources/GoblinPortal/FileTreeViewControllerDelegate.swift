//
//  FileTreeViewControllerDelegate.swift
//  The protocol the file tree reports user intent through, and its one default.
//
//  Its own file because `FileTreeViewController.swift` sat at 349/350 lines and the
//  file-operations work needed room there; the protocol is a whole concern (the
//  tree's outbound contract) with no dependency on the controller's internals.
//  Pure move, plus the doc comment on the default `didMutate`.
//

import AppKit

@MainActor
protocol FileTreeViewControllerDelegate: AnyObject {
    /// A file (not a directory) was activated — double-click, or "Open" from the
    /// row's context menu. The Space opens it as a document tab
    /// (`SpaceViewController.fileTree(_:didActivate:)`).
    func fileTree(_ controller: FileTreeViewController, didActivate url: URL)

    /// ⌥-double-click, or "Insert Path in Terminal". Types the quoted path into the
    /// Space's focused terminal without opening anything — the terminal-first
    /// gesture, which used to be bound to plain double-click and confused everyone.
    func fileTree(_ controller: FileTreeViewController, didRequestPathInsert url: URL)

    /// "New Terminal Here". Opens a new terminal document rooted at `url`, which is
    /// always a **directory** — the menu resolves a clicked file to its parent before
    /// calling, so the Space never has to ask what kind of row was hit
    /// (`SpaceViewController.fileTree(_:didRequestNewTerminalAt:)`).
    func fileTree(_ controller: FileTreeViewController, didRequestNewTerminalAt url: URL)

    /// "cd Here". The user asked to make `url` — always a **directory**, resolved
    /// from a clicked file to its parent exactly like `didRequestNewTerminalAt`
    /// above — the focused shell's working directory. Unlike the other three
    /// members this does not touch the tree itself; it is the other half of
    /// cwd-follow, the shell-to-tree direction being `setRoot(_:)`
    /// (`SpaceViewController.fileTree(_:didRequestChangeDirectory:)`).
    func fileTree(_ controller: FileTreeViewController, didRequestChangeDirectory url: URL)

    /// A file was created, renamed, moved, or trashed. `newURL` is nil when trashed.
    ///
    /// **Creation convention (R1.3):** when a New File or New Folder is committed,
    /// the delegate is called with `oldURL == newURL` — no prior location, just an
    /// arrival. This lets a stale tab at that path (e.g. left open by a sole-pane
    /// trash from PR #157) refresh itself when the file is recreated. A conformer
    /// that does not track stale URLs can ignore the `oldURL == newURL` case safely.
    func fileTree(_ controller: FileTreeViewController, didMutate oldURL: URL, newURL: URL?)
}

extension FileTreeViewControllerDelegate {
    /// Default: ignore mutations. Optional because only a container that shows
    /// documents for tree files (`SpaceViewController`) has anything to update when
    /// one moves; a delegate without open documents loses nothing by skipping it.
    /// Note a conformer that misspells the signature silently gets this no-op
    /// instead of a compile error — the usual cost of a protocol-extension default.
    func fileTree(_ controller: FileTreeViewController, didMutate oldURL: URL, newURL: URL?) {}
}
