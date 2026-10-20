//
//  SpaceViewController+WindowLifecycle.swift
//  Window-focus response for a Space.
//
//  WHY THIS IS SEPARATE
//
//  `SpaceViewController.swift` reached the 350-LOC ceiling when the
//  `systemColorObserver` stored property and `subscribeToSystemColorChanges()`
//  wiring were added for the live accent-colour fix (#249). `windowDidBecomeKey()`
//  is extracted here as a self-contained concern: "what does a Space do when its
//  window comes to the front". `apply(config:)` writes `self.config`, whose setter
//  is `private` (file-scoped), so it stays in `SpaceViewController.swift`.
//

import AppKit

extension SpaceViewController {

    // MARK: - Window focus

    /// Called when the Space's window becomes key — see `FileTreeViewController.refresh()`
    /// for why that is the chosen trigger rather than FSEvents. The documents get the
    /// same signal for the same reason: an open file viewer is as stale as the tree is.
    func windowDidBecomeKey() {
        fileTree.refresh()
        // Follow the focused shell's cwd only while this Space can actually be looked at.
        // Paired with `stopDirectoryFollow()` in `windowDidResignKey()` — a background
        // Space polling a pty is pure cost. See `SpaceViewController+DirectoryFollow.swift`.
        startDirectoryFollow()
        for document in documents { document.documentWindowDidBecomeKey() }
        // Retire the active document's mark, because coming back to the window IS looking
        // at it. Reachable only since PR #21 review item 1 made `isActiveDocument` test
        // `isKeyWindow` too: a mark can now be raised while the whole app is in the
        // background, and without this the tab you return to would keep staring until you
        // switched away and back. The other documents keep theirs — the marker's contract is
        // "looking at the tab retires it", and only one tab is being looked at.
        activeDocument?.clearAttention()
        // A document may have picked up an external change; the strip does not show
        // that today, but the dot state is cheap to keep honest. After the line above, so
        // the cleared status is what gets drawn rather than the stale one.
        syncDocumentChrome()
        // Propagate window-level focus-in so DECSET 1004 focus events reach the terminal.
        // SwiftTerm only fires `setTerminalFocus` from `becomeFirstResponder`/
        // `resignFirstResponder` — switching macOS window tabs without changing first-
        // responder leaves tmux focus-events blind. Active document + its split peer only:
        // background tabs are not visible, so CSI I there is a spurious focus-in. SwiftTerm
        // gates the send on `sendFocus` (DECSET 1004), so a pane without focus events is a
        // no-op. Resign-key counterpart lives in `windowDidResignKey()` in +DirectoryFollow.
        activeDocument?.notifyWindowFocus(true)
        if let active = activeDocument {
            for peer in allSplitDocuments(for: active) { peer.notifyWindowFocus(true) }
        }
    }
}
