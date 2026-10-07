//
//  AppMenu+Window.swift
//  Window and Help menus — standard AppKit items that complete the system menu bar.
//
//  Extracted from AppMenu.swift because adding these items to the inline Window block
//  would push AppMenu.swift past the 350-LOC ceiling (it sits at 338 after the App-menu
//  and Edit-menu additions in this PR). Same extraction pattern as AppMenu+Navigate.swift.
//
//  WINDOW MENU — three standard AppKit items omitted from the initial implementation:
//    • Minimize (⌘M) — performMiniaturize: is NSWindow's own selector; nil target lets
//      AppKit walk the responder chain to the key window. The chord ⌘M is free: Focus
//      Pane Up uses ⌘⇧K (AppMenu.swift:291) and KeyBindings.swift maps only backspace/
//      delete/arrows — not letters — so ⌘M never reaches the pty (verified by reading
//      MacLineEditing.controlBytes; SwiftTerm's performKeyEquivalent also does not
//      intercept ⌘M — MacTerminalView.swift has no handler for it and the kittyBaseLayoutKeyMap
//      at line 1986 only covers non-command scancodes).
//    • Zoom — performZoom: is also NSWindow's. No key equivalent; that matches
//      Terminal.app and Finder. AppKit's windowsMenu role already shows native tab
//      commands (Show All Tabs, Move Tab to New Window) before these items; these go
//      beneath a separator to keep the groups distinct.
//    • Bring All to Front — arrangeInFront: on NSApplication itself; the conventional
//      location is near the bottom of the Window menu, separated from the window list
//      that NSApp.windowsMenu appends automatically.
//
//  HELP MENU — NSApp.helpMenu is the special hook the system uses to inject its
//  Spotlight-driven search field into the menu bar. Assigning a real NSMenu to it (rather
//  than leaving it nil) is what makes that field appear; without it the Help menu in
//  the menu bar shows nothing at all for this app. A single 'Goblin Portal Help' item
//  opening the project README on GitHub is the right scope: the app has no bundled
//  .help bundle, and shipping one for a personal project adds significant packaging
//  overhead for minimal benefit. The README URL is the public repo's readme anchor —
//  the same link users would reach from the project page.
//

import AppKit

extension AppDelegate {
    /// Append the Window menu to `mainMenu` and register it as `NSApp.windowsMenu`,
    /// then build the Help menu and register it as `NSApp.helpMenu`.
    ///
    /// Called from `buildMenu()` after the Navigate and Source Control menus are in place,
    /// so the Window menu occupies the conventional second-from-last slot and Help is last.
    func buildWindowAndHelpMenus(in mainMenu: NSMenu) {
        // MARK: - Window menu

        // Giving the Window menu the NSApp.windowsMenu role is what makes AppKit's
        // native tab commands appear automatically: Show All Tabs, Move Tab to New
        // Window, and the list of open windows are all injected by the system when this
        // role is set. The role was already set in buildMenu(); this file moves the
        // construction out of that function so the inline item count stays under the
        // 350-LOC ceiling.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")

        // Minimize (⌘M) and Zoom — the two standard NSWindow operations every macOS app
        // exposes. Placed before the separator that precedes the system-injected window
        // list, matching Terminal.app's ordering. Both use nil target so AppKit resolves
        // through the responder chain to whichever window is key at action time.
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        // Zoom carries no key equivalent — same as Terminal.app and Finder. A fixed chord
        // for zoom would conflict with user-defined Mission Control shortcuts on many
        // machines, and AppKit does not reserve one in the HIG.
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())

        // Bring All to Front — NSApplication's arrangeInFront: raises every window to the
        // front of the screen stack. Conventional location is at the end of the Window
        // menu, above the auto-injected window list. Target is nil (responder chain
        // reaches NSApp directly).
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())

        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        // Register the role BEFORE appending the help menu so AppKit's tab-management
        // items land under Window, not Help.
        NSApp.windowsMenu = windowMenu

        // MARK: - Help menu

        // NSApp.helpMenu is the system hook: any NSMenu assigned here receives the
        // Spotlight search field that macOS injects into every app's menu bar. Without
        // this assignment the field never appears. The menu is also appended to mainMenu
        // via addItem so it occupies the final, conventional position.
        //
        // One item only — 'Goblin Portal Help' opens the README on GitHub. Rationale:
        //   • The app ships no .help bundle; creating one for a personal project is
        //     packaging work that belongs in a separate PR when docs mature.
        //   • The GitHub README is already the canonical reference (AFK.md links it).
        //   • A browser link is less fragile than a bundled HelpBook path that needs
        //     CFBundleHelpBookFolder in Info.plist and proper HelpKit registration.
        //   • openURL is the single line of code; the selector is on NSWorkspace so
        //     this uses a concrete @objc action rather than nil target + responder chain.
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Goblin Portal Help",
                         action: #selector(openHelp(_:)),
                         keyEquivalent: "?")

        let helpItem = NSMenuItem()
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.helpMenu = helpMenu
    }

    /// Open the project README on GitHub in the default browser.
    ///
    /// Wired to the Help menu's single item. NSWorkspace.open(_:) honours the user's
    /// default browser and never fails silently with a void return. The URL is the public
    /// README anchor — the #readme fragment is GitHub's canonical anchor for the rendered
    /// README tab, so the link navigates directly to the documentation rather than landing
    /// on an arbitrary commit or the repository root.
    @objc func openHelp(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/griffinwork40/goblin-portal#readme")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
