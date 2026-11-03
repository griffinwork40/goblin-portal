//
//  AppDelegate+RootSelection.swift
//  Folder picker for Space creation — the single path every new Space goes through.
//
//  Extracted from AppDelegate.swift at the 350-LOC ceiling. This file owns one
//  concern: presenting the folder picker that enforces the "Spaces = project roots"
//  invariant (#297, T5.2). Every gesture that creates a Space — ⌘N, ⌘⇧N, and the
//  first-launch fallback in `restoreSpaces()` — routes through `selectProjectRoot()`
//  here, so the invariant is structural rather than taught.
//
//  `openFolder` (⌘O) keeps its own panel in AppDelegate.swift because it predates
//  this extraction and has subtly different directoryURL logic (starts at the focused
//  Space's root, not at LastSpaceRoot).
//

import AppKit

@MainActor
extension AppDelegate {

    /// Present an NSOpenPanel for directory selection and return the chosen URL,
    /// or `nil` when the user cancels.
    ///
    /// This is the single picker every Space-creation path calls. `runModal()` is
    /// used (not `begin(completion:)`) because the callers — ⌘N, ⌘⇧N, and the
    /// `restoreSpaces` fallback — all need the result synchronously before
    /// constructing a `SpaceWindowController`.
    func selectProjectRoot() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder for the new Space."
        panel.prompt = "Open as Space"
        // Start where the user last was, or fall back to $HOME so the picker
        // never opens at an undefined location.
        panel.directoryURL = LastSpaceRoot.url
            ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Open `url` as a Space in a new detached window, deduplicating by resolved root.
    ///
    /// Parallels `OpenFileHandler.openDirectoryAsSpace(url:)` (which creates a tab)
    /// and shares the same dedup + `LastSpaceRoot` write pattern. Called by ⌘⇧N and
    /// the `restoreSpaces()` first-launch path.
    func openDirectoryAsNewWindow(url: URL) {
        LastSpaceRoot.url = url

        // resolvingSymlinksInPath so /tmp and /private/tmp do not read as two roots.
        let target = url.resolvingSymlinksInPath()
        if let existing = SpaceWindowController.open.first(
            where: { $0.root.resolvingSymlinksInPath() == target })
        {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        SpaceWindowController(config: config, root: url).present()
    }
}
