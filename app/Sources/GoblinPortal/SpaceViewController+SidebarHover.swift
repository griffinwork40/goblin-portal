//
//  SpaceViewController+SidebarHover.swift
//  Applies `"sidebar": { "revealOnHover": … }` — whether a COLLAPSED sidebar slides back in
//  when the pointer touches the window's left edge in full screen.
//
//  WHAT THE BEHAVIOUR IS. Nothing in this repo implements a hover reveal. It is AppKit's: an
//  `NSSplitViewItem(sidebarWithViewController:)` (`SpaceViewController.swift`) is created with
//  `revealsOnEdgeHoverInFullscreen = YES`. Measured on macOS 27.2: a sidebar item reads YES, a
//  plain `NSSplitViewItem(viewController:)` reads NO, and `NSSplitViewController` only starts
//  its edge-hover observer (`_startObservingEdgeHover`) in full screen. A collapsed sidebar in a
//  normal window never reveals on hover, so this one flag is the whole behaviour.
//
//  WHY KVC ON A NAME THE HEADER DOES NOT LIST. The property is absent from the SDK's
//  `NSSplitViewItem.h` but is a plain, non-underscored accessor pair
//  (`revealsOnEdgeHoverInFullscreen` / `setRevealsOnEdgeHoverInFullscreen:`), and the split
//  view controller re-derives `_hasItemToRevealOnEdgeHover` from it live (measured: flipping it
//  on a collapsed item flips that state with no other call). The alternative, a non-sidebar
//  item, would lose the system sidebar material and the free `toggleSidebar(_:)` behind ⌘B.
//  The setter is called only after `responds(to:)` says it exists, so a future macOS that
//  drops it degrades to the system behaviour plus one stderr line, never a crash.
//
//  WHY ITS OWN FILE. `SpaceViewController.swift` is at the 350-LOC ceiling. Callers mirror
//  the titlebar style: `SpaceWindowController.init` (after the view loads) and
//  `AppDelegate.reloadConfig` (⌘R and Settings Apply). Gated by `check-sidebar-hover.sh`.
//

import AppKit

extension SpaceViewController {
    /// The KVC key on `NSSplitViewItem`. One constant so the gate reads the same name.
    static let sidebarHoverRevealKey = "revealsOnEdgeHoverInFullscreen"

    /// Push `config.sidebarRevealOnHover` onto the sidebar split item. Idempotent; a no-op
    /// before the view has loaded (there is no split item to configure yet).
    func applySidebarHoverReveal() {
        guard let item = splitViewItems.first else { return }
        let setter = NSSelectorFromString("setRevealsOnEdgeHoverInFullscreen:")
        guard item.responds(to: setter) else {
            // Only worth saying when the user asked for something we cannot honour.
            if !config.sidebarRevealOnHover {
                FileHandle.standardError.write(Data(
                    "goblin-portal: sidebar.revealOnHover=false ignored — this macOS has no \(Self.sidebarHoverRevealKey)\n".utf8))
            }
            return
        }
        item.setValue(config.sidebarRevealOnHover, forKey: Self.sidebarHoverRevealKey)
    }
}
