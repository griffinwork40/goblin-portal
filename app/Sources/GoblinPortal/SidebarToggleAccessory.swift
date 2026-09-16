//
//  SidebarToggleAccessory.swift
//  The discoverable button beside the traffic lights that toggles the sidebar.
//
//  ⌘B and View → Toggle Sidebar already worked — both drive
//  `NSSplitViewController.toggleSidebar(_:)` through the responder chain
//  (`AppMenu.swift:205-207`) — but neither is discoverable without already
//  knowing the app has a sidebar to hide, or that this app even has a menu bar
//  shortcut for it. This is the click target: one borderless SF Symbol button,
//  wired to the exact same selector the menu item uses, so it inherits the
//  same enablement and the same collapse animation for free instead of
//  reimplementing either.
//
//  `NSTitlebarAccessoryViewController` rather than a custom titlebar view: it
//  is the system affordance for adding a control beside the traffic lights.
//  `SpaceWindowController` declines `.fullSizeContentView` (the `styleMask` at
//  `SpaceWindowController.swift:144`, argued by the comment block at
//  `:132-141`) precisely so the titlebar stays an opaque strip AppKit owns and
//  draws — this accessory attaches to that strip rather than requiring any
//  change to it.
//
//  `target = nil`. Same reasoning as the menu item: the responder chain finds
//  `SpaceViewController`, the window's `contentViewController`, which
//  inherits the selector from `NSSplitViewController` — so this button and
//  the menu item are two doors onto the one piece of state
//  (`NSSplitViewItem.isCollapsed`), never a second copy of it.
//

import AppKit

/// One borderless button, permanently installed on the leading edge of every
/// Space window's titlebar.
///
/// No stored state beyond the button itself: there is nothing here to read
/// back later, so `SpaceWindowController` constructs one and hands it straight
/// to `NSWindow.addTitlebarAccessoryViewController(_:)` without keeping a
/// reference — the window retains its own accessory list.
@MainActor
final class SidebarToggleAccessory: NSTitlebarAccessoryViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        // `.left` deliberately, and NOT because `.leading` is invalid — an
        // earlier version of this comment claimed exactly that and was wrong.
        // `NSTitlebarAccessoryViewController.h:27` reads: "For applications
        // linked on 10.12 and higher, NSLayoutAttributeLeading and
        // NSLayoutAttributeTrailing can also be used to specify an abstract
        // position that automatically flips depending on the localized
        // language." This app links against macOS 14 (`Package.swift:11`), so
        // `.leading` is available; the "all other values ... will assert"
        // sentence above it in that header is the 10.11-era text the 10.12
        // paragraph amends. Verified by execution, not by reading: `.leading`
        // attaches and pumps a run loop cleanly at `-target
        // arm64-apple-macos14`, while a genuinely unsupported attribute
        // (`.width`) aborts with AppKit naming "Left/Leading" among the pair
        // it accepts.
        //
        // The real reason to pin `.left`: per that same sentence, `.left` no
        // longer auto-flips for an app linked on 10.12+, so it is the literal,
        // non-mirroring choice — and Goblin Portal ships no localization, so there is
        // nothing to mirror and nothing gained by an abstract position that
        // would only ever resolve one way. Switch to `.leading` the day this
        // app grows a right-to-left language, not before. Either attribute
        // puts the control beside both the traffic lights and the sidebar it
        // controls.
        layoutAttribute = .left
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — controllers are created programmatically")
    }

    override func loadView() {
        // Keep the accessory's root a plain, zero-inset view. An NSButton has
        // alignment-rect insets; making it the root lets AppKit's titlebar
        // constraints move its frame origin, which the accessory controller
        // explicitly forbids ("changing the view's origin is not allowed").
        // The container owns the 28×24 titlebar footprint while Auto Layout
        // centres the button inside it without moving the accessory itself.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        // SF Symbol, not a bespoke glyph: `sidebar.leading` is the system
        // symbol Finder, Xcode and Safari all use for this exact control, so
        // it reads as "toggle sidebar" with no label needed. Template mode is
        // what lets it re-tint itself for light/dark and for every theme's
        // window appearance — same reasoning as the git branch glyph
        // (`GitBranchHeaderView.swift:51-54`).
        button.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        button.image?.isTemplate = true
        // Borderless, image-only: no local `NSButton` precedent exists
        // anywhere in this codebase to match, so this defaults to the system
        // idiom for a titlebar icon button rather than a bespoke bezel.
        button.isBordered = false
        button.imagePosition = .imageOnly
        // No target: the same responder-chain trick as the menu item
        // (`AppMenu.swift:201-207`) — `SpaceViewController` inherits
        // `toggleSidebar(_:)` from `NSSplitViewController`, so this button
        // and ⌘B drive the identical state through the identical selector,
        // never a second implementation of "hide the sidebar".
        button.target = nil
        button.action = #selector(NSSplitViewController.toggleSidebar(_:))
        // A tooltip and an accessibility label say what the glyph alone
        // cannot, mirroring `GitBranchHeaderView.swift:106-108` and the row
        // tooltip in `FileTreeViewController+OutlineView.swift:178` — a
        // control with only a glyph is unlabelled on hover and unusable by
        // VoiceOver without both.
        button.setAccessibilityLabel("Toggle Sidebar")
        button.toolTip = "Toggle Sidebar"

        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = container
    }
}
