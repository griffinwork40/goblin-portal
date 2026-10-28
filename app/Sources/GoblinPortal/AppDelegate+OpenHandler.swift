//
//  AppDelegate+OpenHandler.swift
//  Dock icon drops and macOS "Open With" delivery.
//
//  WHY A SEPARATE FILE.  AppDelegate.swift is at 341 LOC (close to the 350-line
//  ceiling).  This concern — handling externally-delivered URLs — is self-contained
//  and parallels AppDelegate+WaitMode.swift.
//
//  HOW IT WORKS.  macOS calls `application(_:open:)` when a user drops files or
//  folders onto the Dock icon, or when Goblin Portal is the default handler for a
//  URL scheme.  Each URL is classified: directories open as Spaces (deduped by
//  resolved root), files open as FileViewerPane tabs in the frontmost Space.
//
//  LAUNCH ORDERING.  When the app is not running and a user drops on the Dock,
//  macOS launches the app and delivers `application(_:open:)` AFTER
//  `applicationDidFinishLaunching`.  `restoreSpaces()` fires first — restored
//  Spaces open, then the dropped folder opens as an additional tab.
//

import AppKit

@MainActor
extension AppDelegate {

    /// Dock icon drops and macOS "Open With" delivery.
    ///
    /// Directories open as Spaces (with symlink-resolved dedup).  Files open as
    /// tabs in the frontmost Space, or in a new Space if none is open.  The shared
    /// primitives live on `OpenFileHandler` so the CLI notification path and this
    /// path use the same logic.
    func application(_ sender: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }
            if isDir.boolValue {
                openFileHandler.openDirectoryAsSpace(url: url)
            } else {
                openFileHandler.openInFrontmostSpace(url: url)
            }
        }
    }
}
