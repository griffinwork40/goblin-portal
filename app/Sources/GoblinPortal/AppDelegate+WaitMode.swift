//
//  AppDelegate+WaitMode.swift
//  Launch-time wiring for `--wait` mode ($EDITOR / $VISUAL support).
//
//  Its own file because the 350-line ceiling in `AppDelegate.swift` is already
//  reached, and the concern is coherent enough to stand alone: everything here
//  is about what happens when the binary is invoked as an editor by an external
//  process (git, crontab, etc.) rather than by the user double-clicking the app.
//
//  Dependency direction matches the rest of the delegate: only `AppDelegate`
//  touches `SpaceWindowController`, `SpaceViewController`, and `FileViewerPane`.
//  Nothing here reaches back.
//

import AppKit

@MainActor
extension AppDelegate {
    /// Open `url` in a fresh Space and make it the only window.
    ///
    /// Called from `applicationDidFinishLaunching` when `--wait` was passed on
    /// the command line. The caller (git, crontab, …) is blocking on this process;
    /// when the `FileViewerPane` is closed the app terminates, unblocking it. That
    /// termination is wired in `FileViewerPane+Document.swift:documentWillClose()`.
    ///
    /// The file's parent directory is used as the Space root. That gives the
    /// sidebar a useful starting point — the directory containing the file, which
    /// is where the caller is working — without requiring a separately-passed root
    /// argument. For git commit messages that is the repo root (git's cwd); for
    /// crontab it is a temp directory, where the sidebar is irrelevant but harmless.
    func openWaitFile(_ url: URL) {
        // B-3: Reject a non-existent --wait file before opening anything. Without this
        // check the app would open a placeholder ("Could not read …") for a path that
        // doesn't exist yet, exit 0, and the calling process (git, crontab) would read
        // back an unchanged file — silent false success. Exiting 1 here lets the caller
        // report the problem instead.
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(
                "goblin-portal: --wait file does not exist: \(url.path)\n".data(using: .utf8)!)
            exit(1)
        }
        let root = url.deletingLastPathComponent()
        let controller = SpaceWindowController(config: config, root: root)
        // `presentForWaitMode` is the single writer of `SpaceWindowController.open`
        // that is appropriate here: it shows the window and opens the file without
        // starting a terminal or persisting the session to the restore list.
        controller.presentForWaitMode(opening: url)
    }
}
