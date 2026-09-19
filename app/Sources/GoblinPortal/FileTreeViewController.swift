//
//  FileTreeViewController.swift
//  The sidebar file tree, rooted at the Space's project directory.
//
//  Four concerns live in files of their own: the tree's model in `FileNode.swift`; the
//  `NSOutlineView` data source and delegate, plus the cell machinery they build, in
//  `FileTreeViewController+OutlineView.swift`; the right-click menu in
//  `FileTreeViewController+ContextMenu.swift`; and git status — the poller, the snapshot
//  and the branch header — in `FileTreeViewController+Git.swift`. What stays here is the
//  controller itself: the views it assembles, the identity-preserving `refresh()`,
//  `setRoot(_:)` (repoint the tree at a new directory — cwd-follow), and double-click
//  routing.
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
}

@MainActor
final class FileTreeViewController: NSViewController {
    weak var delegate: FileTreeViewControllerDelegate?

    /// Internal, not `private`: the `NSOutlineViewDataSource` conformance moved to
    /// `FileTreeViewController+OutlineView.swift` and its `node(for:)` substitutes
    /// this for a nil item, which is how the root row is answered for. That
    /// extension only ever reads it, so `private(set)` — not plain `private` —
    /// keeps the getter at this same internal level while confining the *setter*
    /// to this file, where `setRoot(_:)` lives.
    ///
    /// `var`, not `let`: this used to be immutable on purpose, with a comment
    /// arguing the tree could never be repointed. That argument is retired, not
    /// the protection it existed for — cwd-follow needs the tree to move when the
    /// shell's cwd moves, and `setRoot(_:)` below is the one path allowed to do
    /// it, still gated to this file by `private(set)`.
    ///
    /// This is only the tree's **displayed** root. A Space's *identity* root —
    /// `SpaceWindowController.root`, the `GoblinPortalSpace:<path>` frame-autosave key,
    /// `OpenSpaceRoots`, `LastSpaceRoot` — is a separate, still-immutable concept:
    /// a Space stays "the project opened with ⌘O" no matter where its shell's cwd
    /// wanders, so a `cd` moving the sidebar must never rename the Space, relabel
    /// its window tab, or rewrite its remembered frame/restore entry.
    private(set) var root: FileNode

    /// Internal for the same reason `root` is: two extensions in other files need it.
    /// `+ContextMenu` reads `clickedRow` to know which row was hit, and `+Git` reloads
    /// row views in place when a status snapshot changes. Both only ever read it — the
    /// view is still built and owned here, and nothing outside this type may replace it.
    let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let rowMenu = NSMenu()

    /// The git-status poller. Nil until the Space's window first becomes key, because a
    /// Space nobody has looked at has nothing to decorate — see `startGitFollow()`.
    ///
    /// The only stored property the git concern needs, and it is here rather than in
    /// `FileTreeViewController+Git.swift` only because Swift extensions cannot add stored
    /// properties. Everything it does lives over there.
    var gitFollow: GitStatusFollow?

    /// The branch line above the tree. Built eagerly and hidden — it costs one view, and
    /// `loadView` has to put it in the stack before the first poll can decide whether it
    /// belongs on screen.
    let gitHeader = GitBranchHeaderView()

    // MARK: - Filter state (written by FileTreeViewController+Filter.swift)

    /// The NSSearchField injected between the branch header and the tree.
    /// Stored here because Swift extensions cannot add stored properties; all
    /// behaviour lives in `FileTreeViewController+Filter.swift`.
    let filterField = NSSearchField()

    /// The current filter query. Empty string = no filter.
    /// Written only by `applyFilter(_:)` in the filter extension.
    var filterQuery: String = ""

    /// When non-nil, the data source returns only children whose URLs appear here.
    /// Nil means "no filter — show everything". Written by `applyFilter(_:)`.
    var visibleURLs: Set<URL>?

    init(root url: URL) {
        self.root = FileNode(url: url, isDirectory: true)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — views are created programmatically")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        // `.sourceList` is what makes the rows adopt the system sidebar's
        // selection pill and vibrancy-aware text colours, so this tree matches
        // Finder and Xcode instead of looking like a plain table in a grey box.
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = 12
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.autoresizingMask = [.width, .height]

        // Right-click affordances. This is also where "insert path in terminal"
        // becomes findable: bound only to a modifier chord it was a feature nobody
        // could discover, which is most of why the tree felt like it did nothing.
        rowMenu.delegate = self
        outlineView.menu = rowMenu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // The sidebar item paints its own vibrant material; an opaque scroll view
        // on top of it would flatten that back to a solid rectangle.
        scrollView.drawsBackground = false

        // A stack rather than manual constraints, for one specific property: an
        // `NSStackView` detaches hidden views from its layout, so `GitBranchHeaderView`
        // hiding itself in a Space that is not a git repository leaves no gap above the
        // tree and needs no height constraint to animate to zero. The sidebar then looks
        // exactly as it did before this feature existed, which is the bar for added chrome.
        let stack = NSStackView(views: [gitHeader, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        // Breathing room between the sidebar's top edge and the first content.
        // Sourced from `GlassDrawingStyle` (4pt on macOS 26, 2pt on earlier) so the
        // value is colocated with the other glass-conditional tokens in
        // `LiquidGlass.swift`. `edgeInsets.top` is stack-level and always applied,
        // which is why the value is modest — a Space on ~/Documents (no repo, header
        // hidden) would show dead space at larger values.
        let style = GlassDrawingStyle.resolved()
        stack.edgeInsets = NSEdgeInsets(top: style.sidebarTopInset, left: 6, bottom: 0, right: 6)
        // The header keeps its 22pt; the scroll view takes everything left over. Without
        // this the stack splits the space between them and the tree ends up half-height.
        gitHeader.setContentHuggingPriority(.required, for: .vertical)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The split view sizes this controller's root view by frame, as it did when that
        // root was the scroll view itself; inside the stack, its children use constraints.
        stack.autoresizingMask = [.width, .height]

        // Splice the filter field between the branch header and the tree.
        // Logic, state, and the NSSearchFieldDelegate conformance are in
        // `FileTreeViewController+Filter.swift` — only the layout call lives here
        // because the stack is a local variable in this method.
        addFilterField(to: stack)

        root.reloadChildren()
        view = stack
    }

    /// Re-read the tree, preserving expansion and selection.
    ///
    /// Called when the Space's window becomes key rather than driven by FSEvents.
    /// That is a deliberate first cut, and it is well matched to this app's actual
    /// job: the thing mutating these files is an agent running in the terminal
    /// beside the tree, so "you came back to this window" is almost exactly the
    /// moment the tree is stale. FSEvents is the obvious upgrade if it ever feels
    /// behind.
    func refresh() {
        let expanded = (0..<outlineView.numberOfRows)
            .compactMap { outlineView.item(atRow: $0) as? FileNode }
            .filter { outlineView.isItemExpanded($0) }
        let selectedURL = (outlineView.item(atRow: outlineView.selectedRow) as? FileNode)?.url

        root.reloadChildren()
        outlineView.reloadData()

        // Git status is stale for exactly the same reason the tree is, at exactly the same
        // moment: the agent in the terminal beside this sidebar has been editing and
        // committing while the window was in the background. So the two refreshes share
        // one trigger rather than inventing a second lifecycle hook. `start()` is
        // idempotent and polls once immediately, so this both starts the poller the first
        // time and re-reads on every later activation. The stop half is in
        // `SpaceViewController.windowDidResignKey()`, next to cwd-follow's.
        startGitFollow()

        for node in expanded { outlineView.expandItem(node) }
        if let selectedURL {
            for row in 0..<outlineView.numberOfRows
            where (outlineView.item(atRow: row) as? FileNode)?.url == selectedURL {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                break
            }
        }
    }

    /// Repoint the tree at a different directory — cwd-follow, the shell-to-tree
    /// half of it (the tree-to-shell half is "cd Here" below).
    ///
    /// Deliberately does **not** preserve expansion/selection the way `refresh()`
    /// does. `refresh()` re-reads the *same* directory, so an expanded row is still
    /// the same path with possibly-changed contents — carrying its state forward is
    /// exactly right. `setRoot(_:)` points at a *different* directory: a row
    /// expanded under the old root is an unrelated path under the new one (same
    /// relative position, different file), so "restoring" it would show disclosure
    /// state that has nothing to do with what's on disk at the new root. A full
    /// `reloadData()` against a fresh `FileNode` is the correct amount of state to
    /// carry across a root change: none.
    ///
    /// The early return on an unchanged root is **load-bearing, not an
    /// optimisation**: this is meant to be driven by a shell's reported cwd
    /// (`TerminalPane.hostCurrentDirectoryUpdate`, currently a wired-but-empty OSC 7
    /// stub) and the tree's own "cd Here" pushes the opposite direction, into the
    /// shell — together that is a UI <-> shell feedback loop, and a shell that
    /// echoes its cwd on every prompt would otherwise rebuild `root` and blow away
    /// the user's expansion/selection on every keystroke even when the directory
    /// never changed. The guard is what makes "did anything actually change?" the
    /// question, not "did an update arrive?". `resolvingSymlinksInPath()` matches
    /// the normalisation `AppDelegate.openFolder` and `SpaceRestore` already use so
    /// `/tmp` vs `/private/tmp` cannot defeat it.
    /// Compared as **paths, not as `URL`s**, and that is not a style preference — it is a
    /// bug that was caught by `check-cwd-follow.sh` before it shipped. `URL` equality
    /// includes the directory marker (a trailing slash), and `resolvingSymlinksInPath()`
    /// drops that marker when the last component is itself a symlink: measured,
    /// `URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()` is `file:///tmp/`
    /// while `URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()` is `file:///tmp` —
    /// same `.path`, and `==` is **false**. With a `URL` comparison this guard would have
    /// answered "changed" every time for such a directory, so a 750ms poller would have
    /// rebuilt the tree and discarded the user's expansion and selection twice a second:
    /// precisely the damage the guard exists to prevent, in the shape of a passing test.
    func setRoot(_ url: URL) {
        guard url.resolvingSymlinksInPath().path != root.url.resolvingSymlinksInPath().path
        else { return }
        root = FileNode(url: url, isDirectory: true)
        root.reloadChildren()
        outlineView.reloadData()
        // The tree now shows a different project, so the decorations on screen belong to
        // the old one. Waiting out the poller's 2s tick would leave them there — not merely
        // late but *wrong*, which is worse than showing none. The follower re-discovers the
        // repository when it finds the root has moved outside the one it knew.
        gitFollowPollNow()
    }

    @objc private func handleDoubleClick() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            // ⌥ is the "give me the path, do not open it" modifier — the same key
            // Finder uses to turn Copy into Copy as Pathname.
            delegate?.fileTree(self, didRequestPathInsert: node.url)
        } else {
            delegate?.fileTree(self, didActivate: node.url)
        }
    }

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
        guard targetPath.hasPrefix(rootPath) else { return }

        // Walk the path components between root and target, expanding each directory
        // as we go so the child nodes are loaded before we try to show them.
        let components = url.pathComponents
        let rootComponents = root.url.pathComponents
        guard components.count > rootComponents.count else { return }

        var current: FileNode = root
        // Skip the root's own components; descend through the remainder.
        let descendantComponents = components.dropFirst(rootComponents.count)
        for (index, component) in descendantComponents.enumerated() {
            // Ensure children are loaded at this level.
            if current.children == nil { current.reloadChildren() }
            let isLastComponent = index == descendantComponents.count - 1
            guard let child = current.children?.first(where: { $0.name == component }) else {
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
