//
//  SpaceWindowController.swift
//  One window == one Space == one project root. Documents live inside it.
//
//  Native macOS window tabbing (tabbingIdentifier + addTabbedWindow) is KEPT and
//  re-pointed: a system tab is now a *Space*, not a shell. That is the whole
//  argument for branch (C) (plan §12.3) — ⌘⇧[ / ⌘⇧] cycling, the tab overview,
//  drag-to-reorder, drag-out-to-detach, Merge All Windows, full-screen behaviour
//  and VoiceOver all stay free, and they land at the level where detaching and
//  merging actually mean something: a project.
//
//  What a system tab could NOT do is documents. A window tab *is* an NSWindow, so
//  a mixed terminal/editor strip would give every document its own contentView and
//  there could be no shared, full-height sidebar (plan §12.2). Documents therefore
//  live in `SpaceViewController`'s hand-rolled strip. Two tab levels, each using
//  the mechanism that fits it.
//

import AppKit

@MainActor
final class SpaceWindowController: NSWindowController, NSWindowDelegate,
    SpaceViewControllerDelegate
{
    /// Shared identifier is what makes separate windows join one tab group.
    private static let tabbingIdentifier = "com.griffinlong.goblin-portal.space"

    /// Every open Space, so the app can attach a new tab to one, fan a config
    /// reload across all of them, and know when the last one is gone.
    ///
    /// Also the source of truth restore is persisted from — see `persistOpenRoots()`.
    /// That is why this needed no new machinery: the set of open Spaces was already
    /// modelled here, it was just never written down.
    private(set) static var open: [SpaceWindowController] = []

    /// Set by `AppDelegate.applicationShouldTerminate` the moment quitting is
    /// committed, so the teardown of N windows cannot be mistaken for the user
    /// closing N Spaces and erase the very list restore needs.
    ///
    /// AppKit is not documented to send `windowWillClose` on app termination, and it
    /// generally does not — but the whole feature turns on that, the difference is
    /// invisible until a real relaunch, and this flag costs one Bool. Deliberate
    /// insurance against an ordering that is not verifiable in a headless build.
    static var isTerminating = false

    /// Write the roots of the currently-open Spaces down, in tab order.
    ///
    /// Called from the three places `open` changes rather than from
    /// `applicationWillTerminate`, because a terminal hosting a long-running agent
    /// gets force-quit, killed by the OOM killer, and crashed — none of which call any
    /// termination hook. Persisting on change means the worst case is a session that
    /// lost whatever changed after the last open or close, instead of everything.
    ///
    /// The empty list is a legitimate, deliberate state: closing your last Space is
    /// you saying you are done, and the next launch should be one fresh default Space
    /// rather than a resurrection of what you just dismissed. `isTerminating` is what
    /// keeps ⌘Q from producing that same empty list for the opposite reason.
    ///
    /// Also called once from `AppDelegate.applicationShouldTerminate` — not as a
    /// belt-and-braces flush, but because it closes a real gap: dragging tabs to
    /// reorder changes no window's open/closed state, so nothing else here fires, and
    /// a reorder followed by ⌘Q would otherwise restore yesterday's order. At
    /// quit-commit time every window is still open, so `inTabOrder` is accurate.
    static func persistOpenRoots() {
        guard !isTerminating else { return }
        OpenSpaceRoots.urls = inTabOrder.map(\.root)
    }

    /// The open Spaces in the order the user actually sees them.
    ///
    /// `open` is append-ordered — *creation* order — and a native tab bar can be
    /// dragged to reorder, so the two diverge the first time anyone rearranges their
    /// Spaces. `NSWindow.tabGroup?.windows` is the visual left-to-right order
    /// (measured: chaining `addTabbedWindow(_:ordered: .above)` down a group yields
    /// exactly the insertion order back), so prefer it.
    ///
    /// The `open` fallback is defensive, NOT a documented nil case: a lone window with
    /// a `tabbingIdentifier` and `tabbingMode = .preferred` still reports a non-nil
    /// `tabGroup` containing just itself — measured, having first assumed the opposite.
    /// Since every Space shares one identifier, the usual state is a single group
    /// holding all of them.
    ///
    /// Only the first group found is consulted, and any Space not in it is appended in
    /// creation order. That is a deliberate approximation for the split-across-windows
    /// case: restore rebuilds exactly one tab group
    /// (`AppDelegate.restoreSpaces()`), so such a session is already being flattened,
    /// and ordering it perfectly would be precision the restore itself does not have.
    /// What this must never do is *drop* a Space, hence the `ungrouped` append.
    private static var inTabOrder: [SpaceWindowController] {
        guard let group = open.compactMap({ $0.window?.tabGroup }).first else { return open }
        let grouped = group.windows.compactMap { window in open.first { $0.window === window } }
        let ungrouped = open.filter { controller in !grouped.contains { $0 === controller } }
        return grouped + ungrouped
    }

    /// Frame autosave name for one project root.
    ///
    /// This was the single hardcoded string `"UmberWindow"`, which meant every Space
    /// shared one saved frame: the last window you moved overwrote the geometry of
    /// all the others, and they all restored to it. A Space is a project, and the
    /// window geometry that suits a project is a property of that project — a wide
    /// two-monitor layout for one checkout, a narrow strip for another.
    ///
    /// The root's path, verbatim, rather than a hash of it: this lands in
    /// `UserDefaults` as `NSWindow Frame GoblinPortalSpace:/path/to/project`, which stays
    /// greppable in `defaults read com.griffinlong.goblin-portal` while debugging, and the
    /// full path is already stored in the clear next to it by `LastSpaceRoot`, so
    /// there is nothing new disclosed. The cost is one abandoned key per root ever
    /// opened; a stale frame entry is a few dozen bytes and AppKit ignores it.
    ///
    /// `GoblinPortal`-prefixed per the naming convention, and distinct from the legacy
    /// string so the pre-per-root frame stays readable — see `init`.
    private static func frameAutosaveName(for root: URL) -> NSWindow.FrameAutosaveName {
        "GoblinPortalSpace:\(root.path)"
    }


    let space: SpaceViewController

    /// This Space's project root. Stored, not just handed to `SpaceViewController`,
    /// so `AppDelegate.openFolder` can focus an already-open Space for a folder
    /// instead of opening a second Space onto the same directory.
    let root: URL

    init(config: AppConfig, root: URL) {
        self.root = root
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 680)
        self.space = SpaceViewController(config: config, root: root)

        // NOT .fullSizeContentView. That flag makes the content view span the
        // whole window frame, including the 28pt the titlebar occupies — and
        // since the titlebar here is opaque, it hid the terminal's top ~1.7
        // rows. Row 0 is where a fresh prompt, the caret, and typed echo all
        // live, so the pane looked empty and dead while working perfectly:
        // measured contentView 600pt vs contentLayoutRect 572pt at 37 rows.
        // A sidebar item is the textbook reason to reach for the flag, and it is
        // still declined: AppKit would probably propagate the safe area correctly
        // now that the terminal sits two levels deeper, but "probably" is not worth
        // re-opening a bug that cost real debugging (plan §12.4 item 6).
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .preferred
        // The system tab bar shows window titles, and a system tab is a Space — so
        // the title names the project and the *subtitle* carries the active
        // document. Titling the window after the shell would make every project's
        // tab read "zsh" (plan §12.4 item 1).
        window.title = root.lastPathComponent
        // Match the terminal's own background so the titlebar area does not flash
        // a mismatched colour on open or during a live resize. A nil theme leaves
        // SwiftTerm on its own defaults, whose background is black
        // (`Colors.swift:37` defaultBackground) — so match that, not the system
        // window colour, or the chrome and the terminal disagree.
        window.backgroundColor = config.effectiveBackground
        // Set on the window so it cascades to every system-drawn surface at once —
        // the sidebar's vibrant material, the source-list selection pill, the label
        // colours, the scroller knob and the titlebar. Without it they all follow
        // System Settings instead of the theme, which is what put a Light-Mode grey
        // file tree against a black terminal. See `AppConfig.appearance`.
        window.appearance = config.appearance
        window.titlebarAppearsTransparent = false
        // macOS 26+: Liquid Glass chrome — fullSizeContentView + transparent
        // titlebar so the sidebar and titlebar form one continuous glass surface.
        // Safe area insets prevent the terminal clipping that caused
        // fullSizeContentView to be declined on pre-26 (see comment at :132).
        if #available(macOS 26, *) {
            LiquidGlass.configureWindow(window)
        }
        window.contentViewController = space
        // Discoverable ⌘B: a button beside the traffic lights, wired to the
        // same responder-chain selector the menu item already used. See
        // `SidebarToggleAccessory.swift`.
        window.addTitlebarAccessoryViewController(SidebarToggleAccessory())
        // Wider floor than the old terminal-only window: below this the sidebar's
        // 150pt minimum plus the document area's 240pt cannot both be honoured and
        // the split view starts fighting itself.
        window.minSize = NSSize(width: 480, height: 240)

        super.init(window: window)

        window.delegate = self
        space.spaceDelegate = self

        // Restore position/size per *project root*, not per app. This was one
        // hardcoded string, so every Space shared a single saved frame and the last
        // window moved dictated where all of them reopened.
        //
        // NOTE: Umber's per-root geometry (`NSWindow Frame UmberSpace:/path`) lived in
        // the `com.griffinlong.umber` defaults domain. `setFrameUsingName` reads from
        // `[NSUserDefaults standardUserDefaults]` (the running bundle's domain), so
        // there is no public-API path to recover those frames post-rename. Users who
        // upgrade from Umber open at the 1100x680 default on first launch, and the
        // new `GoblinPortalSpace:` key takes over from the first window move.
        //
        // Two Spaces CAN share a root (⌘N twice; ⌘O dedupes, `AppDelegate.openFolder`)
        // and therefore this name. Measured, not assumed: a second live window taking
        // an already-claimed autosave name still returns true, so there is no failure
        // to handle here — the two simply overwrite each other's saved frame, and the
        // last one moved wins.
        //
        // Honest limit: while Spaces are *tabbed*, AppKit keeps every window in the
        // group at the group's frame, so the per-root frames converge on it. The
        // per-root name earns its keep for Spaces dragged out to their own windows and
        // for the geometry a project reopens at — not for giving tabs different sizes,
        // which a tab group cannot do anyway.
        window.setFrameAutosaveName(Self.frameAutosaveName(for: root))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — windows are created programmatically")
    }

    // MARK: - Lifecycle

    func present() {
        Self.open.append(self)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        openFirstDocument()
        Self.persistOpenRoots()
    }

    /// Open as a system tab on the frontmost existing Space, falling back to a
    /// plain window when there is nothing to attach to.
    func presentAsTab(relativeTo host: NSWindow?) {
        Self.open.append(self)
        if let host, let window {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
        openFirstDocument()
        // After `addTabbedWindow`, so `inTabOrder` sees this window already in the
        // group and records the roots in the order the tab bar shows them.
        Self.persistOpenRoots()
    }

    /// Deferred until the window is on screen, and forced through a layout pass
    /// first. `TerminalPane` sizes its SwiftTerm view from the frame it is handed,
    /// and the document container's bounds are zero until the split view has laid
    /// out — starting the shell before that would hand it a 0×0 pty and a bogus
    /// initial `SIGWINCH`.
    private func openFirstDocument() {
        space.view.layoutSubtreeIfNeeded()
        space.addTerminalDocument()
        // Restore saved split arrangement after the first terminal has geometry.
        if let snapshots = SplitStateStore.snapshots(for: root),
           let first = snapshots.first {
            space.restoreSplit(from: first)
        }
    }

    /// Present this Space for `--wait` mode: show the window but open `url`
    /// instead of the default terminal, and skip session persistence.
    ///
    /// Like `present()` — it is the single writer of `SpaceWindowController.open`
    /// — but omits `openFirstDocument()` and `persistOpenRoots()`, which are both
    /// wrong for a transient CLI session. Full contract in `AppDelegate+WaitMode.swift`.
    func presentForWaitMode(opening url: URL) {
        // B-4 / B-5: Mark the session as terminating from the start so
        // `persistOpenRoots()` is a no-op for this ephemeral CLI session. Without
        // this, either ⌘⇧W (`windowWillClose` → `persistOpenRoots`) or ⌘W's
        // single-tab path (`spaceViewControllerDidCloseLastDocument` → `close()` →
        // `windowWillClose` → `persistOpenRoots`) would write the temp file path into
        // the user's session restore list, corrupting it on next normal launch.
        Self.isTerminating = true
        Self.open.append(self)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        space.view.layoutSubtreeIfNeeded()
        space.openFile(url: url)
    }

    // MARK: - SpaceViewControllerDelegate

    func spaceViewController(_ controller: SpaceViewController, didChangeDocumentTitle title: String) {
        window?.subtitle = title
    }

    func spaceViewControllerDidCloseLastDocument(_ controller: SpaceViewController) {
        // A Space with no documents has nothing to show; closing matches every
        // other terminal's behaviour when the last shell in a tab exits.
        close()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // The agent running in the terminal beside the tree is what mutates these
        // files, so "you came back to this window" is very close to the moment the
        // tree went stale. See `FileTreeViewController.refresh()`.
        space.windowDidBecomeKey()
    }

    /// The mirror of the above, and it exists for one reason: cwd-follow polls the focused
    /// shell's working directory on a timer, and a Space you are not looking at should not
    /// be polling. See `SpaceViewController+DirectoryFollow.swift`.
    func windowDidResignKey(_ notification: Notification) {
        space.windowDidResignKey()
    }

    /// Closing a Space closes every document in it, so it has to honour the same
    /// veto ⌘W does — otherwise ⌘⇧W is a way to discard unsaved work without ever
    /// being asked.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        space.spaceShouldClose()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
        // `windowShouldClose` only asked permission; this is where the close commits, so it is
        // where every document's unmanaged state is released. Safe to run on the ⌘Q path too
        // even though AppKit "generally does not" send this on quit (see the note at the top of
        // this file): `documentWillClose()` is required to be idempotent, and app termination
        // needs no teardown of its own — the process is exiting, the pty master closes with it,
        // and the child gets SIGHUP. So a missed call here costs nothing and a doubled one is
        // harmless, which is the only reason it is safe to have exactly one call site for a
        // path AppKit will not promise to deliver.
        space.tearDownAllDocuments()
        // Closing a Space is the user saying they are done with that project, so it
        // has to come back out of the restore list — otherwise ⌘⇧W would be
        // undoable only until the next launch, which resurrected it. Gated on
        // `isTerminating` inside `persistOpenRoots`, so ⌘Q tearing down N windows
        // cannot be read as the user closing N Spaces.
        Self.persistOpenRoots()
        // A closed Space's splits should not be restored next launch. Gated on
        // `isTerminating` the same way -- ⌘Q should preserve the split state so
        // relaunch can restore it. Only an explicit Space close clears it.
        if !Self.isTerminating {
            SplitStateStore.removeSnapshots(for: root)
        }
    }
}
