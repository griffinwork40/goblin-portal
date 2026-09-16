//
//  SpaceRestore.swift
//  Reopening the Spaces that were open at quit.
//

import AppKit

/// Launch-time Space restore — the read half of `OpenSpaceRoots`.
///
/// Its own file because it is the one piece of `AppDelegate` with a written
/// contract about what it deliberately does NOT restore, and that argument (below)
/// is longer than the code making it. It also has a verification surface of its
/// own: `Scripts/check-space-restore.sh` compiles `Defaults.swift` and runs a
/// 12-case truth table over the `OpenSpaceRoots` list this reads, so the concern
/// is already separable — the restore policy is one thing to understand, the
/// launch/terminate lifecycle around it is another.
///
/// An extension, not a type: this is `applicationDidFinishLaunching`'s second
/// statement, and it reads the delegate's own `config` to build each Space.
@MainActor
extension AppDelegate {
    /// Reopen every Space that was open at quit, as one native tab group.
    ///
    /// This used to be an unconditional `newSpaceInWindow(nil)` — exactly one Space,
    /// always — so N Spaces at quit became 1 Space at relaunch and the other N−1
    /// project roots were simply forgotten (only `LastSpaceRoot` survived). See
    /// `OpenSpaceRoots` for why the roots are persisted where they are.
    ///
    /// **A restored Space does NOT restore its documents.** Every document kind that
    /// exists is either a shell (`TerminalPane` — a login `$SHELL` with no resumable
    /// state; its scrollback, its cwd after you `cd`, and its running process all died
    /// with the last launch) or a file view (`FileViewerPane`, which cannot be dirty
    /// at quit because `documentShouldClose` already vetoes a close with unsaved
    /// changes and `applicationShouldTerminate` honours that veto). So reopening four
    /// terminals would be theatre: four fresh prompts arranged to *look* like the
    /// session you left, in a strip whose tab titles would be wrong until each shell
    /// emitted its first OSC 0/2. The project root is the durable part of a Space, and
    /// it is the part restored. Documents come back as `present()`/`presentAsTab` make
    /// them: one fresh terminal each.
    ///
    /// Degrades to a single default Space when there is nothing to restore, which
    /// covers both first-ever launch (no key) and every remembered root having been
    /// deleted since (`OpenSpaceRoots.urls` filters those out) — never an app with no
    /// window, which on a `.regular` app is a Dock icon that does nothing.
    /// Internal, not `private`: called from `applicationDidFinishLaunching` in
    /// `AppDelegate.swift`, and `private` is file-scoped in Swift.
    func restoreSpaces() {
        let roots = OpenSpaceRoots.urls
        guard let first = roots.first else { return newSpaceInWindow(nil) }

        // The first Space opens as a plain window; the rest attach as system tabs via
        // the existing `presentAsTab(relativeTo:)`. Spaces ARE native macOS window
        // tabs (`SpaceWindowController.tabbingIdentifier` + `addTabbedWindow`), so
        // getting this wrong does not mean a cosmetic glitch — it means N detached
        // windows instead of one tab group.
        //
        // The host must NOT be `NSApp.keyWindow`, the way ⌘N resolves it: during launch
        // no window has been made key yet, so it is nil, and nil is exactly the input
        // that makes `presentAsTab` fall through to its untabbed branch — every Space
        // its own window.
        //
        // Each tab is anchored on the PREVIOUS restored window, not on the first one.
        // `addTabbedWindow(_:ordered: .above)` inserts immediately after its host, so
        // anchoring everything on the first window would place tab 3 between tabs 1 and
        // 2, tab 4 between 1 and 3, and reverse the whole group behind the leftmost tab.
        // Walking the chain keeps the saved left-to-right order.
        let host = SpaceWindowController(config: config, root: first)
        host.present()
        var previous = host
        for root in roots.dropFirst() {
            let controller = SpaceWindowController(config: config, root: root)
            controller.presentAsTab(relativeTo: previous.window)
            previous = controller
        }

        // Focus a chosen Space rather than whichever tab the loop ended on.
        // `presentAsTab` makes each new tab key, so without this the rightmost restored
        // tab wins by accident.
        //
        // `LastSpaceRoot` is the pick: it is the one piece of "where was I working"
        // state that already exists, so ⌘O a project → quit → relaunch lands back in
        // it. It is an honest proxy and not the real answer — it only updates on ⌘O
        // (`openFolder`), not when you switch tabs — and recording true
        // frontmost-at-quit would mean new persisted state for a tab selection, which
        // is not worth it. Falling back to the leftmost tab keeps this deterministic
        // either way.
        let preferred = LastSpaceRoot.url?.resolvingSymlinksInPath()
        let focus = SpaceWindowController.open.first {
            $0.root.resolvingSymlinksInPath() == preferred
        } ?? host
        focus.window?.makeKeyAndOrderFront(nil)
    }
}
