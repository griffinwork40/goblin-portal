//
//  AppDelegate+Validation.swift
//  `NSMenuItemValidation` conformance for AppDelegate — the single place where every
//  menu item's enabled/disabled state is decided.
//
//  WHY THIS FILE EXISTS. `AppDelegate.swift` hit the 350-LOC ceiling when the
//  terminal-action guard (lane F, `TerminalActionGuard.swift`) added the foreground-kind
//  check to the sendPathToTerminal/runInTerminal validation block. Rather than shave
//  lines, the whole validation concern is extracted here — the seam AppKit already
//  provides (`NSMenuItemValidation`) becomes the file boundary. AFK.md "Conventions"
//  names this exact pattern: "find the seam and pull one whole concern out". The
//  example given was "move menu validation into AppDelegate+Validation.swift" —
//  that is this file.
//
//  The `NSMenuItemValidation` protocol conformance is declared here, not in the class
//  body, because Swift extension conformances are allowed for classes defined in the
//  same module. The conformance is still @MainActor because `AppDelegate` is @MainActor.
//

import AppKit

// MARK: - Menu Validation

extension AppDelegate: NSMenuItemValidation {
    /// AppKit calls this for every menu item that targets AppDelegate (directly or via
    /// the responder chain) before drawing the menu. Return true to enable, false to grey.
    ///
    /// Validation greys out ⌘⇧C/⌘⇧R when the foreground is not shell-safe —
    /// the user sees the disabled state and knows the action would be refused.
    /// `TerminalActionGuard.validates` does NOT beep; beeping is reserved for the
    /// execution-time `check` call in the action body.
    ///
    /// The palette routes through the same selectors so it also picks up this
    /// validation automatically (AppKit's `NSMenuItem.isEnabled` is set from this
    /// before the palette's item list is drawn).
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
        // Terminal-integration items need a file viewer, a shell host, AND a safe foreground.
        // Greys out ⌘⇧C/⌘⇧R when an agent, remote, or unknown program is in front so the
        // user sees at a glance that the action would be refused — plan §coordinator-4.
        if sel == #selector(sendPathToTerminal(_:)) || sel == #selector(runInTerminal(_:)) {
            guard focusedSpace?.activeDocument is FileViewerPane,
                  let shell = focusedSpace?.focusedShellHost else { return false }
            return TerminalActionGuard.production.validates(host: shell)
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
}
