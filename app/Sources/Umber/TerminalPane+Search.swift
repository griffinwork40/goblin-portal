//
//  TerminalPane+Search.swift
//  Scrollback search — ⌘F opens SwiftTerm's built-in find bar.
//
//  Its own file for two reasons:
//  1. `TerminalPane.swift` is 4 lines from the 350-LOC ceiling — the next addition
//     that belongs in the file proper needs that headroom, and the rule is to find
//     a seam, not to defer the split.
//  2. The search feature involves enough SwiftTerm internals that keeping the
//     full picture in one place pays for itself at the next read.
//
//  HOW TERMINAL SEARCH WORKS — the complete chain, so a future reader does not have
//  to grep vendor/SwiftTerm to answer "but how does ⌘F actually open anything?":
//
//  1. MENU ITEMS. `buildMenu()` in `AppMenu.swift` adds five Edit-menu items, all
//     wired to `performFindPanelAction:` (the selector `NSTextView` also uses) with
//     `NSFindPanelAction` raw values as tags:
//       1 = showFindPanel  → ⌘F   (= open the find bar)
//       3 = next           → ⌘G
//       4 = previous       → ⌘⇧G
//       7 = setFindString  → ⌘E   (= seed from selection)
//     The tag is what dispatches: `performFindPanelAction(_:)` early-returns
//     unless the sender is an `NSMenuItem` and `menuItem.tag` matches a case
//     (`Mac/MacTerminalView.swift:2179`). That means a toolbar button or a bare
//     `performFindPanelAction(nil)` call would do nothing — items and their tags
//     are the protocol, not just a decoration.
//
//  2. ROUTING. All items have `target = nil`, so AppKit walks the key window's
//     responder chain. When a terminal tab is front the chain is:
//       UmberTerminalView → TerminalPane (via processDelegate, but that is not
//       a responder) → window → app
//     `UmberTerminalView` inherits `MacTerminalView`, which inherits `TerminalView`,
//     which is an `NSView`. `MacTerminalView.performFindPanelAction` is declared
//     `@objc open` at `Mac/MacTerminalView.swift:2179`, so AppKit finds it when
//     it walks up to the first-responder view.
//
//  3. KEY EQUIVALENT. ⌘F reaches the menu item because `UmberTerminalView.
//     performKeyEquivalent(with:)` only intercepts four keycodes (backspace,
//     forwardDelete, leftArrow, rightArrow via `MacLineEditing.controlBytes`)
//     and returns `super.performKeyEquivalent(with:)` for everything else.
//     `super` is `NSView`'s implementation, which returns false, letting AppKit
//     fall through to the main menu — where the ⌘F item matches and fires.
//     Full-screen was moved from ⌘F to ⌃⌘F (the macOS system default) precisely
//     so ⌘F could be search without a collision. See `AppMenu.swift:239-247`.
//
//  4. ENABLEMENT. `validateUserInterfaceItem` on `MacTerminalView`
//     (`Mac/MacTerminalView.swift:2129`) returns `true` for showFindPanel/next/
//     previous and gates setFindString on `selection.active`. Every other selector
//     returns `false`, which is why "Find and Replace" (tag 12, via
//     `NSTextFinder.Action.showReplaceInterface`) greys out over a terminal
//     automatically — scrollback is a transcript and cannot be rewritten.
//
//  5. FIND BAR. `performFindPanelAction` dispatches to `showFindBar(prefillSelection:)`
//     (`Mac/MacTerminalView.swift:2290`), which lazily constructs a
//     `TerminalFindBarView` (a `NSVisualEffectView` with `.popover` material) the
//     first time it is needed, anchors it in the top-right of the terminal view via
//     Auto Layout, and focuses the search field. `TerminalFindBarView` (defined in
//     `Mac/MacFindBarView.swift`) handles its own Escape via `NSSearchFieldDelegate`
//     — `cancelOperation:` calls the `onClose` closure, which calls `hideFindBar()`,
//     which hides the bar and returns first responder to the terminal view.
//
//  6. SEARCH ENGINE. Matches are found by `SearchService` (vendor/SwiftTerm/Sources/
//     SwiftTerm/Search.swift), which walks the terminal's buffer via `getLine(row:)`.
//     Matches highlight as yellow selection blocks; the current match cycles forward
//     and backward via ⌘G / ⌘⇧G. This is selection-based — one match highlighted at
//     a time — not all-match annotation. That is a known gap (AFK.md, "Search is
//     SwiftTerm's, not ours").
//
//  WHAT UMBER DOES NOT ADD: the find bar is SwiftTerm's own; its appearance (popover
//  material, 8pt corner radius) is fixed in `TerminalFindBarView.setup()`. No Umber
//  styling is applied. The bar works, and touching its internals would mean patching
//  the vendor — which costs a future re-vendor and was rejected for this feature for
//  the same reason libghostty's binary was rejected: auditability is the point.
//  Patch 0008 (`0008-make-draw-open-for-subclass-override.patch`) already landed to
//  let `UmberTerminalView` override `draw(_:)`; the find bar needs no further opens.

import AppKit
import SwiftTerm

// MARK: - Search entry point

extension TerminalPane {
    /// Open the find bar programmatically — the same effect as ⌘F via the menu.
    ///
    /// Provided so the command palette (and any future toolbar button) can trigger
    /// search without synthesising an `NSMenuItem`. The method sends a real
    /// `NSMenuItem` with the correct tag rather than calling `showFindBar` directly,
    /// because `performFindPanelAction(_:)` guards on `sender as? NSMenuItem` and
    /// reads `menuItem.tag` — a plain method call on the view would silently do
    /// nothing (`Mac/MacTerminalView.swift:2179-2181`).
    ///
    /// Safe to call when the find bar is already visible; `showFindBar` is idempotent
    /// and simply re-focuses the search field.
    func openSearch() {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        view.performFindPanelAction(item)
    }
}
