//
//  AppDelegate.swift
//  App lifecycle, and the actions the menu bar points at.
//
//  Three concerns live in extensions of their own, each in its own file: the menu
//  tree and its validation in `AppMenu.swift`, launch-time Space restore in
//  `SpaceRestore.swift`, and the first-run config template in
//  `StarterConfig.swift`. What stays here is the lifecycle (launch, terminate)
//  and the `@objc` actions those menu items send.
//

import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// `private(set)`, not `private`: `restoreSpaces()` moved to
    /// `SpaceRestore.swift` and builds each Space with this config, and Swift's
    /// `private` is *file*-scoped. Only the read is widened — the setter stays
    /// file-private, so `reloadConfig` remains the one place this is reassigned.
    private(set) var config = AppConfig.load()

    /// Watches `NSApp.effectiveAppearance` and fans a theme switch out to every open
    /// Space when the user has configured `"preset": "auto"`. Nil when auto mode is
    /// not active — the observer exists and listens, but its `applyThemeSwitch` only
    /// acts on Spaces that have a non-nil `autoTheme`. Created once and held for the
    /// lifetime of the app; released (and the KVO observation invalidated) with the
    /// delegate. See `AppearanceObserver.swift` for the full rationale.
    private let appearanceObserver = AppearanceObserver()

    /// Handles open-file requests from the `goblin-portal` CLI binary via
    /// NSDistributedNotificationCenter. Registered in applicationDidFinishLaunching.
    /// Held for the app lifetime so its observer token is never released early.
    private let openFileHandler = OpenFileHandler()

    /// The preferences panel. Created once on first ⌘, and retained so its
    /// values survive a hide-and-re-show cycle (singleton pattern).
    private var preferencesWindow: PreferencesWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Surface config problems where the user will actually see them, instead
        // of silently substituting defaults and leaving them wondering why their
        // theme did nothing.
        for warning in config.warnings {
            FileHandle.standardError.write("config: \(warning)\n".data(using: .utf8)!)
        }
        buildMenu()
        if let f = CLIArguments.shared.waitFile { openWaitFile(f) } else { restoreSpaces() } // --wait mode: AppDelegate+WaitMode.swift

        // Register the CLI open-file notification handler. Must happen after
        // applicationDidFinishLaunching so the run loop is running and distributed
        // notifications can be delivered. The CLI waits 0.5s after the app appears
        // in NSRunningApplication before posting, so this registration window is safe.
        openFileHandler.register()

        // Request notification permission so the app can post alerts when long
        // commands finish in background tabs (CommandNotification). Safe to call
        // repeatedly — the system ignores it after the user has granted or denied.
        CommandNotification.requestPermissionIfNeeded()

        // Register as delegate so macOS delivers banners even when Goblin Portal is
        // frontmost. Without this, the system silently drops notifications from
        // the active app — defeating the primary use-case: a build finishing in
        // a background TAB of the same window. Conformance lives in
        // AppDelegate+Notifications.swift.
        UNUserNotificationCenter.current().delegate = self

        // Check for a newer release on GitHub, silently, at most once per 24 hours.
        // Deferred to the next run-loop tick so the window is visible before any
        // alert appears (auto-check only shows one when a new version exists).
        DispatchQueue.main.async {
            UpdateChecker.shared.checkOnLaunch(currentVersion: UpdateChecker.bundleVersion)
        }
    }

    /// ⌘S. A no-op on a terminal (`SpaceDocument.saveDocument()` defaults to a
    /// successful no-op), so this needs no branching on document kind.
    @objc func saveDocument(_ sender: Any?) {
        _ = focusedSpace?.activeDocument?.saveDocument()
    }

    /// Greys the Save item out unless the active document actually has something
    /// to save. `documentIsEdited` defaults to `false` for a terminal
    /// (`SpaceDocument.swift`), so this also disables Save whenever a terminal tab
    /// is focused — consistent with the action above being a no-op there
    /// (PR #2 review, finding 4).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let sel = menuItem.action
        if sel == #selector(saveDocument(_:)) {
            return focusedSpace?.activeDocument?.documentIsEdited == true
        }
        if sel == #selector(goToLine(_:)) {
            return focusedSpace?.activeDocument is FileViewerPane
        }
        if sel == #selector(toggleWordWrap(_:)) {
            guard let viewer = focusedSpace?.activeDocument as? FileViewerPane else {
                menuItem.state = .off
                return false
            }
            menuItem.state = viewer.isWrapping ? .on : .off
            return true
        }
        // Terminal-integration items need both a file viewer AND a shell.
        if sel == #selector(sendPathToTerminal(_:)) || sel == #selector(runInTerminal(_:)) {
            return focusedSpace?.activeDocument is FileViewerPane
                && focusedSpace?.focusedShellHost != nil
        }
        // ⌘D — only enabled over a file viewer, not a terminal.
        if sel == #selector(selectNextOccurrence(_:)) {
            return focusedSpace?.activeDocument is FileViewerPane
        }
        // ⌘⇧P — always available (palette surfaces all commands).
        if sel == #selector(showCommandPalette(_:)) { return true }
        // `openSearch(_:)` falls through: valid in both terminal and editor contexts.
        return true
    }

    /// Quitting closes every Space, so it owes the same prompt ⌘W does. Without
    /// this, ⌘Q is a one-keystroke path past every unsaved-changes guard in the app.
    ///
    /// Known limitation, documented rather than fixed here (PR #2 review, finding
    /// 2): `spaceShouldClose()` is evaluated per-Space in `SpaceWindowController
    /// .open`'s order, and it is not a pure predicate — picking "Save" in a dirty
    /// document's alert writes the file to disk right there, inline. So with 2+
    /// Spaces holding unsaved documents, Saving an earlier Space then Cancelling a
    /// later one leaves the earlier Space's write committed even though the
    /// overall quit is aborted: "Cancel" here means "the app didn't quit," not
    /// "nothing on disk changed." A correct fix needs the `SpaceDocument` close
    /// contract split into a decide-then-commit pair so every Space's decision is
    /// known before any write executes — real enough surface area (a protocol
    /// change touching every conformer, plus ⌘W's single-document close path,
    /// which does NOT have this problem and should keep its simpler combined
    /// behaviour) that it belongs in its own change, not folded into a
    /// review-feedback pass.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        for controller in SpaceWindowController.open
        where controller.space.hasEditedDocuments && !controller.space.spaceShouldClose() {
            return .terminateCancel
        }
        // Record the final order while every window is still open, then stop
        // persisting. Both halves matter and they must happen in this order:
        //   * The write closes a gap nothing else covers — dragging tabs to reorder
        //     changes no window's open/closed state, so `persistOpenRoots`'s other
        //     call sites never fire, and a reorder then ⌘Q would restore yesterday's
        //     order. This is the last moment `tabGroup?.windows` is still accurate.
        //   * The flag then makes teardown inert: from here a closing window is the
        //     app exiting, not the user closing that Space, and recording those would
        //     erase the very list restore needs (`SpaceWindowController.isTerminating`).
        // Both sit *after* the veto loop, so a cancelled ⌘Q leaves persistence live.
        SpaceWindowController.persistOpenRoots()
        SpaceWindowController.open.forEach { $0.space.persistSplitState(for: $0.root) }
        SpaceWindowController.isTerminating = true
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Actions

    /// Help → Check for Updates…
    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.shared.checkNow(currentVersion: UpdateChecker.bundleVersion)
    }

    /// The root a Space gets when the user did not name one (⌘N, ⌘⇧N, first launch).
    ///
    /// The last root opened with ⌘O, falling back to `$HOME` — which is still the
    /// right *first* answer, because a login shell starts there anyway, but a poor
    /// steady-state one: you almost always want the project you were last in, not a
    /// home directory whose first screen is tool caches. See `LastSpaceRoot`.
    private var defaultSpaceRoot: URL {
        LastSpaceRoot.url ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// ⌘N — a new Space, joining the existing tab group. A system tab *is* a Space
    /// under this design, and `tabbingMode = .preferred` already says macOS wants
    /// these tabbed; ⌘⇧N exists for when a genuinely separate window is wanted.
    @objc func newSpace(_ sender: Any?) {
        let host = NSApp.keyWindow ?? SpaceWindowController.open.last?.window
        SpaceWindowController(config: config, root: defaultSpaceRoot)
            .presentAsTab(relativeTo: host)
    }

    @objc func newSpaceInWindow(_ sender: Any?) {
        SpaceWindowController(config: config, root: defaultSpaceRoot).present()
    }

    /// ⌘O — choose a project folder and open it as a Space.
    ///
    /// This is what makes the sidebar file tree worth having: until now every Space
    /// rooted at `$HOME`, so the tree showed the home directory and nothing else was
    /// reachable. The root was already a threaded init parameter
    /// (`SpaceWindowController.init(config:root:)` → `SpaceViewController` →
    /// `FileTreeViewController`), so this action only has to supply a URL.
    ///
    /// Re-opening a folder that already has a Space focuses it instead of making a
    /// duplicate — two Spaces onto one root would give the same project two file
    /// trees and two titles with no way to tell them apart.
    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder to open as a Space."
        panel.prompt = "Open as Space"
        // Start where the focused Space already is, so opening a sibling project is
        // one level up rather than a walk from $HOME.
        panel.directoryURL = focusedSpaceWindow?.root ?? defaultSpaceRoot

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Recorded before the dedupe, not after: re-opening a folder that already
        // has a Space is still you saying "this is where I am working", and the
        // next ⌘N should land there even though this call goes on to just focus
        // the existing window.
        LastSpaceRoot.url = url

        // resolvingSymlinksInPath so /tmp and /private/tmp — or any symlinked
        // checkout — do not read as two different roots and defeat the dedupe.
        let target = url.resolvingSymlinksInPath()
        if let existing = SpaceWindowController.open.first(
            where: { $0.root.resolvingSymlinksInPath() == target })
        {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSApp.keyWindow ?? SpaceWindowController.open.last?.window
        SpaceWindowController(config: config, root: url).presentAsTab(relativeTo: host)
    }

    /// ⌘T — a new document inside the focused Space. This is the semantic change at
    /// the heart of the restructure: it used to spawn a whole NSWindow.
    @objc func newDocument(_ sender: Any?) {
        guard let space = focusedSpace else { return newSpace(sender) }
        space.addTerminalDocument()
    }

    /// ⌘W — close the *document*, falling through to the window only when it was the
    /// last one (`SpaceViewController` reports that back via its delegate). Wiring ⌘W
    /// straight to the window would throw away every other terminal in the project.
    @objc func closeDocument(_ sender: Any?) {
        guard let space = focusedSpace else { return NSApp.keyWindow?.performClose(sender) ?? () }
        space.closeActiveDocument()
    }

    @objc func nextDocument(_ sender: Any?) { focusedSpace?.cycleDocument(by: 1) }
    @objc func previousDocument(_ sender: Any?) { focusedSpace?.cycleDocument(by: -1) }

    /// ⌘1…⌘9. The index rides in the menu item's `tag` so nine items share one action.
    @objc func selectDocumentByIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        focusedSpace?.selectDocument(at: item.tag - 1)
    }

    /// Re-read the config file and apply it to every open pane, so tuning the
    /// theme does not require restarting the app.
    @objc func reloadConfig(_ sender: Any?) {
        config = AppConfig.load()
        for warning in config.warnings {
            FileHandle.standardError.write("config: \(warning)\n".data(using: .utf8)!)
        }
        for controller in SpaceWindowController.open {
            controller.space.apply(config: config)
            controller.window?.backgroundColor = config.effectiveBackground
            // Re-derived on every reload, not just at init: editing the theme from
            // a dark background to a light one (or back) has to move the sidebar
            // and titlebar with it, or ⌘R leaves the chrome showing the old theme.
            controller.window?.appearance = config.appearance
        }
    }

    @objc func openConfigFile(_ sender: Any?) {
        // First visit: ensure a starter config exists so loadCurrentValues has
        // something to read (matches the old behaviour before this panel existed).
        let url = AppConfig.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? StarterConfig.text.write(to: url, atomically: true, encoding: .utf8)
        }
        // Open the native preferences panel. Power users can reach the raw JSON
        // via the "Open config.json" button inside the panel.
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindow()
        }
        preferencesWindow?.loadCurrentValues()  // re-read on every show
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// The Space whose window has focus, falling back to the most recently opened.
    /// Same resolution order as `focusedSpace`; this one keeps the window controller
    /// because `openFolder` needs its `root`, which `SpaceViewController` does not
    /// expose. Internal (not private) so `AppDelegate+EditorActions.swift` can reach it.
    var focusedSpaceWindow: SpaceWindowController? {
        SpaceWindowController.open.first { $0.window === NSApp.keyWindow }
            ?? SpaceWindowController.open.last
    }

    /// Widened from `private` because `+EditorActions.swift` uses it across the
    /// file boundary. The one-reader discipline (it computes, callers consume)
    /// is the real invariant, not the access level.
    var focusedSpace: SpaceViewController? {
        focusedSpaceWindow?.space
    }

    /// Every document in every Space. Zoom and config reload are app-wide, so they
    /// need the flattened list rather than one pane per window as before.
    ///
    /// Typed `[SpaceDocument]`, not `[TerminalPane]`: this used to flatten
    /// `terminalPanes`, so the moment a second document kind existed ⌘+ would have
    /// skipped it in silence — the file viewer would simply never zoom, with nothing
    /// to see in a build log. `SpaceDocument` makes zoom a hard requirement precisely
    /// so that class of bug cannot be reintroduced by a future conformer.
    private var allDocuments: [SpaceDocument] {
        SpaceWindowController.open.flatMap { $0.space.allDocuments }
    }

    private var focusedDocument: SpaceDocument? {
        focusedSpace?.activeDocument ?? allDocuments.last
    }

    /// Zoom every document, not just the focused one. Per-pane sizing reads as a bug
    /// in a tabbed terminal: you zoom because the text is too small for your eyes
    /// and this screen, which is not a property of one tab — and now, not a
    /// property of one Space, or of one document kind, either (plan §12.4 item 7).
    private func zoomAllDocuments(by delta: CGFloat) {
        guard let anchor = focusedDocument else { return }
        let target = anchor.currentFontSize + delta
        anchor.setFontSize(target, persist: true)
        // Mirror the anchor's post-clamp size so every document agrees even at a bound.
        let settled = anchor.currentFontSize
        for document in allDocuments where document !== anchor {
            document.setFontSize(settled, persist: false)
        }
    }

    @objc func biggerFont(_ sender: Any?) { zoomAllDocuments(by: 1) }
    @objc func smallerFont(_ sender: Any?) { zoomAllDocuments(by: -1) }

    @objc func resetFont(_ sender: Any?) {
        for document in allDocuments { document.resetFontSize() }
    }

    // Wave 2 + Wave 3 editor actions → AppDelegate+EditorActions.swift
}
