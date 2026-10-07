//
//  GoblinPortalTerminalView+Clear.swift
//  Clear Buffer (⌘K) — erase the screen AND scrollback of the focused terminal.
//
//  Placed on GoblinPortalTerminalView, NOT on TerminalPane, because:
//
//    The AppKit responder chain runs through NSView subclasses, not through the
//    NSObject (TerminalPane) that owns the view. The focused pane's
//    GoblinPortalTerminalView is the first responder; a nil-target menu action
//    walks that chain — NSView → NSClipView → ... → NSWindow → NSApp. TerminalPane
//    is never in that chain, so `clearBuffer:` on TerminalPane would be a dead item
//    that renders, clicks, and silently does nothing (the exact hazard class AFK.md
//    names for all nil-target items, and the defect the previous agent shipped).
//
//    GoblinPortalTerminalView IS in the chain — it is the view whose firstResponder
//    the window holds — so placing the action here makes it reachable automatically
//    in both the single-pane and split-pane cases: in a split, the focused pane's
//    view is first responder, so only that pane clears.
//
//  VALIDATION SEAM:
//    `clearBuffer:` must be ENABLED when a terminal is first responder. SwiftTerm's
//    own `validateUserInterfaceItem` (MacTerminalView.swift:2144) has a `default:`
//    branch that returns `false`, which would grey it out. The fix lives in
//    GoblinPortalTerminalView.validateUserInterfaceItem (class body, not an extension
//    — Swift disallows extension overrides of non-@objc-dynamic methods), which
//    returns `true` for `clearBuffer:` and delegates everything else to `super`.
//    A blanket `validateMenuItem` override is deliberately NOT used: AppKit prefers
//    `validateMenuItem` over `validateUserInterfaceItem` for menu items and would
//    hijack copy/paste/find validation that SwiftTerm already handles correctly.
//
//  SEMANTICS (iTerm2 / Terminal.app parity):
//    • Erase the entire scrollback buffer, not just the visible screen.
//    • Leave the cursor at the prompt — the shell is still running.
//    • Redraw the prompt so the visible screen is not blank after the clear.
//
//  IMPLEMENTATION:
//    1. `getTerminal().resetToInitialState()` — Terminal.swift:5204. This is the
//       RIS (ESC c) handler: clears normal buffer, alt buffer, scrollback, and all
//       terminal state. Compared to alternatives:
//         • `changeScrollback(0)` then restore: trims the history ring but leaves
//           screen content intact — wrong semantics for "Clear Buffer".
//         • Sending ESC c via `feed(text:)`: equivalent but goes through the
//           escape parser; `resetToInitialState()` is the direct public API.
//    2. Send `\x0c` (form feed / Ctrl-L) to the pty via `send(txt:)`. This asks
//       the shell's line editor (zsh/bash/fish) to repaint the prompt. It is the
//       same byte that ⌃L sends in the terminal, and what iTerm2 sends after its
//       own clear buffer operation. `send(txt:)` routes through
//       AppleTerminalView.send → pty master fd — the same path as a real keypress.
//

import AppKit
import SwiftTerm

extension GoblinPortalTerminalView {
    /// Clear the terminal screen and scrollback, then redraw the shell prompt.
    ///
    /// Invoked through the responder chain from the Edit > Clear Buffer (⌘K) menu item.
    /// The nil target on that item means AppKit walks the first-responder chain to
    /// whichever GoblinPortalTerminalView currently holds focus — correct in both the
    /// single-pane and split-pane cases without any explicit routing.
    ///
    /// `validateUserInterfaceItem` in `GoblinPortalTerminalView.swift` returns `true`
    /// for this selector, enabling the menu item whenever a terminal is first responder.
    /// Over a file-editor tab the item greys out automatically because no view in the
    /// responder chain answers `clearBuffer:`.
    @objc func clearBuffer(_ sender: Any?) {
        // Step 1: wipe every line in the normal buffer (including scrollback) and reset
        // all terminal state. resetToInitialState is Terminal.swift:5204 — it calls
        // setup(isReset: true), clearAllKittyImages(), refresh, and syncScrollArea.
        // Equivalent to the host sending ESC c (RIS); this is what iTerm2 does for
        // its "Clear Buffer" action.
        getTerminal().resetToInitialState()

        // Step 2: ask the shell to redraw its prompt. ^L (form feed, 0x0C) is the
        // conventional signal: zsh/bash/fish all treat it as "redraw the command line".
        // `send(txt:)` → AppleTerminalView.send → pty master fd — identical to the
        // path a real ^L keypress takes (AppleTerminalView.swift:2287).
        send(txt: "\u{0c}")
    }
}
