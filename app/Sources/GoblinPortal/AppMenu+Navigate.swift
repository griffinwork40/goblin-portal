//
//  AppMenu+Navigate.swift
//  The Navigate submenu — document-level movement and symbol navigation.
//
//  Extracted from AppMenu.swift when the View menu's split and pane-focus items
//  pushed the file past the 350-LOC ceiling. This is one whole concern ("moving
//  between documents and symbols") separable from the rest of menu construction.
//

import AppKit

extension AppDelegate {
    /// Build the Navigate menu and append it to the given menu bar.
    ///
    /// Deliberately NOT folded into the Window menu. That menu carries the standard
    /// role, and its native tab commands (Show All Tabs, Move Tab to New Window) act
    /// on *Spaces*; putting document navigation beside them would present two
    /// different tab levels as one list.
    func buildNavigateMenu(in mainMenu: NSMenu) {
        let navigateItem = NSMenuItem()
        let navigateMenu = NSMenu(title: "Navigate")
        // ⌘⇧P — Command Palette. Sublime's most-imitated invention: fuzzy-search
        // all editor commands from a floating panel. ⌘⇧P is the universal chord for
        // it (VS Code, Zed, Cursor all use it), and it does not collide with any
        // existing binding in this app. Answers in every window — palette is a
        // singleton, not tied to a document kind.
        let paletteItem = NSMenuItem(
            title: "Command Palette…",
            action: #selector(showCommandPalette(_:)), keyEquivalent: "p")
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        navigateMenu.addItem(paletteItem)
        // ⌘⇧O — Jump to Symbol. Regex-based symbol extraction per language; opens a
        // floating, keyboard-driven outline panel. Target nil so AppKit walks the
        // responder chain to `FileViewerPane.showSymbolOutline:`, and the item greys
        // out automatically over a terminal (nothing in the terminal chain answers it).
        let symbolItem = NSMenuItem(
            title: "Jump to Symbol…",
            action: Selector(("showSymbolOutline:")), keyEquivalent: "o")
        symbolItem.keyEquivalentModifierMask = [.command, .shift]
        navigateMenu.addItem(symbolItem)
        // ⌘⇧A — Window Chooser. Opens the command palette with Space entries so
        // you can fuzzy-search and switch between open Spaces and their tabs —
        // the Goblin Portal equivalent of tmux's ctrl-b w.
        let chooserItem = NSMenuItem(
            title: "Choose Window…",
            action: #selector(showWindowChooser(_:)), keyEquivalent: "a")
        chooserItem.keyEquivalentModifierMask = [.command, .shift]
        navigateMenu.addItem(chooserItem)
        navigateMenu.addItem(.separator())
        let nextTabItem = NSMenuItem(
            title: "Next Tab", action: #selector(nextDocument(_:)),
            keyEquivalent: Self.functionKeyEquivalent(NSRightArrowFunctionKey))
        nextTabItem.keyEquivalentModifierMask = [.command, .option]
        navigateMenu.addItem(nextTabItem)
        let previousTabItem = NSMenuItem(
            title: "Previous Tab", action: #selector(previousDocument(_:)),
            keyEquivalent: Self.functionKeyEquivalent(NSLeftArrowFunctionKey))
        previousTabItem.keyEquivalentModifierMask = [.command, .option]
        navigateMenu.addItem(previousTabItem)
        navigateMenu.addItem(.separator())
        // ⌘1…⌘9 only — ⌘0 is Actual Size and predates this menu.
        for index in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(index)", action: #selector(selectDocumentByIndex(_:)),
                keyEquivalent: String(index))
            item.tag = index
            navigateMenu.addItem(item)
        }
        navigateItem.submenu = navigateMenu
        mainMenu.addItem(navigateItem)
    }
}
