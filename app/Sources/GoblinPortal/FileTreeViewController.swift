//
//  FileTreeViewController.swift
//  The sidebar file tree, rooted at the Space's project directory.
//
//  Its concerns live in files of their own, among them: the tree's model in
//  `FileNode.swift`; the `NSOutlineView` data source and delegate, plus the cell
//  machinery they build, in `FileTreeViewController+OutlineView.swift`; the right-click
//  menu in `+ContextMenu.swift`; git status — the poller, the snapshot and the branch
//  header — in `+Git.swift`; the async reloads (`refresh()`, `refreshSynchronously()`,
//  setRoot's listing) in `+Loading.swift`; and auto-reveal in `+Reveal.swift`. What stays
//  here is the controller itself: the views it assembles, `setRoot(_:)` (repoint the tree
//  at a new directory — cwd-follow), and double-click routing.
//

import AppKit

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

    /// The root the OUTLINE is showing, which is `root` except while a `setRoot(_:)`
    /// listing is in flight: then it is still the previous tree (#158 review, I1).
    /// Every data-source callback and every walk over visible rows reads THIS, so the
    /// outline never shows an empty frame on a cwd-follow re-root and never holds items
    /// nothing retains (`NSOutlineView` does not retain its items — this property is what
    /// keeps the old tree alive while it is on screen). `root` moves first, so setRoot's
    /// same-path guard, the git poller and cwd-follow see the new directory at once; the
    /// two converge in ONE `reloadData()` when the listing lands (`adoptRoot()`,
    /// `+Loading.swift`), or synchronously in `refreshSynchronously()`. Internal setter
    /// because `+Loading.swift` is where they converge.
    var displayedRoot: FileNode

    /// Internal for the same reason `root` is: two extensions in other files need it.
    /// `+ContextMenu` reads `clickedRow` to know which row was hit, and `+Git` reloads
    /// row views in place when a status snapshot changes. Both only ever read it — the
    /// view is still built and owned here, and nothing outside this type may replace it.
    let outlineView = FileTreeOutlineView()
    let scrollView = NSScrollView()
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

    /// Expansion state saved the moment a filter is first applied, so it can be
    /// restored exactly when the filter is cleared. Nil when no filter is active.
    /// Stored here (not in the extension file) because Swift extensions cannot
    /// add stored properties.
    var preFilterExpansion: [FileNode]?

    /// Cached result of the volume case-sensitivity query for `root` (R1.2, #176).
    /// Populated lazily on the first walk/reveal; invalidated in `setRoot(_:)` when
    /// the root moves (the new directory may sit on a volume with different semantics).
    /// Nil = not yet queried. Stored here because Swift extensions cannot add stored
    /// properties.
    var caseSensitiveFS: Bool?

    init(root url: URL) {
        let node = FileNode(url: url, isDirectory: true)
        self.root = node
        self.displayedRoot = node
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
        // ONLY the private type: registering `.fileURL` accepted Finder and other-app
        // drops as MOVES out of their source (S-3). Internal drags only, for now.
        outlineView.registerForDraggedTypes([Self.draggedFileURLType])
        // Key routing (⌘⌫, Return, F2, Esc) and ⌘X/⌘C/⌘V reach the controller through
        // this; it was only set when an edit began, so the first ⌘⌫ did nothing (H1).
        outlineView.fileOpsDelegate = self
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

    // `refresh()` (async, window-became-key) and `refreshSynchronously()` (every file
    // operation) live in `FileTreeViewController+Loading.swift` (#158).

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
        // FIRST, before the filter is touched: clearing the filter reloads the outline,
        // which would destroy an open inline editor. Remember the root and replay it
        // when the edit ends (`finishEditReplay()` in +Mutation.swift) (H4).
        guard !isEditingInline else { pendingRoot = url; return }
        filterField.stringValue = ""
        // Only an ACTIVE filter is cleared here: `applyFilter("")` reloads the outline,
        // and with no filter that reload only collapsed the tree that stays on screen
        // while the new root lists (`displayedRoot`, I1) — a visible jolt for nothing.
        if !filterQuery.isEmpty {
            preFilterExpansion = nil
            applyFilter("")
        }
        guard url.resolvingSymlinksInPath().path != root.url.resolvingSymlinksInPath().path
        else { return }
        // Back to the tree still on screen before its replacement landed (`cd x; cd -`
        // inside one listing): keep the displayed tree and its expansion, drop the
        // in-flight listing, and run any reveal that was waiting for the two to converge.
        if displayedRoot !== root,
            url.resolvingSymlinksInPath().path == displayedRoot.url.resolvingSymlinksInPath().path
        {
            root = displayedRoot
            invalidatePendingLoads()
            performPendingReveal()
            gitFollowPollNow()
            return
        }
        root = FileNode(url: url, isDirectory: true)
        // The new root may sit on a different volume with different case semantics, so
        // the cached query must be invalidated; it is re-populated lazily on the next
        // walk or reveal call (#176).
        caseSensitiveFS = nil
        // Lists the new root OFF the main thread (#158); the outline keeps showing the old
        // tree (`displayedRoot`) until it lands — `FileTreeViewController+Loading.swift`.
        beginRootLoad()
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
}
