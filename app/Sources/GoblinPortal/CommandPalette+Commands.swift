//
//  CommandPalette+Commands.swift
//  The static command list that populates the ⌘⇧P command palette.
//
//  Its own file because the list is a configuration table, not logic — it
//  changes when commands are added or renamed, not when the palette UI changes.
//  That makes it the right seam when `CommandPalette.swift` approaches the
//  350-LOC ceiling. Adding a new command means editing this file only.
//
//  Every entry is a `PaletteCommand` (title, key hint, selector, optional tag).
//  The `tag` field is required only for `performFindPanelAction:` senders (Find
//  Next, Find Previous, Find and Replace) — see `AppMenu.swift`'s search block
//  for the full explanation of why. `Find…` is the exception: it now routes
//  through `openSearch(_:)` instead of `performFindPanelAction:`, so it does
//  not need a tag.
//
//  SUPERSET CONTRACT: every actionable menu item in AppMenu.swift /
//  AppMenu+Navigate.swift / AppMenu+SourceControl.swift must have a
//  corresponding entry here, executing through the same selector the menu item
//  uses, so validation and behaviour cannot drift. The gate
//  `Scripts/check-palette-covers-menu.sh` enforces this mechanically at build
//  time. Allowlisted selectors (things that make no sense in a palette):
//    cut:/copy:/paste:/selectAll: — clipboard text operations
//    undo:/redo: — in palette but also allowlisted from mechanical check
//    terminate:/hide:/orderFrontStandardAboutPanel: — app/system management
//    performMiniaturize:/performZoom:/arrangeInFront:/hideOtherApplications:/
//      unhideAllApplications: — window manager stock selectors
//    performFindPanelAction: — covered by tagged variants below
//    showCommandPalette: — IS the palette; invoking it from itself is circular
//    selectDocumentByIndex: — the ⌘1-9 select-tab family (dynamic, handled by
//      spaceCommands() which generates per-open-tab entries instead)
//
//  FUTURE: clearBuffer: is pre-stubbed here for the parallel lane adding
//  ⌘K / Clear Buffer as a menu item. It is disabled/no-op until that lane
//  lands, but pre-registering it keeps this gate green after both merge.
//

import AppKit

extension CommandPalette {
    /// Every command the palette offers. Order is priority order — the most-used
    /// commands appear first even in an empty query.
    ///
    /// Key hints are Unicode glyphs matching the macOS standard:
    ///   ⌘ Command, ⇧ Shift, ⌥ Option, ⌃ Control.
    static let allCommands: [PaletteCommand] = [
        // File
        PaletteCommand("Save",                        key: "⌘S",     action: #selector(AppDelegate.saveDocument(_:))),
        PaletteCommand("New Tab",                     key: "⌘T",     action: #selector(AppDelegate.newDocument(_:))),
        PaletteCommand("New Space",                   key: "⌘N",     action: #selector(AppDelegate.newSpace(_:))),
        PaletteCommand("New Space in New Window",     key: "⌘⇧N",    action: #selector(AppDelegate.newSpaceInWindow(_:))),
        PaletteCommand("Open Folder…",                key: "⌘O",     action: #selector(AppDelegate.openFolder(_:))),
        PaletteCommand("Close Tab",                   key: "⌘W",     action: #selector(AppDelegate.closeDocument(_:))),
        PaletteCommand("Close Space",                 key: "⌘⇧W",    action: #selector(NSWindow.performClose(_:))),
        // Navigate
        PaletteCommand("Go to Line…",                 key: "⌘L",     action: #selector(AppDelegate.goToLine(_:))),
        PaletteCommand("Jump to Symbol…",             key: "⌘⇧O",    action: Selector(("showSymbolOutline:"))),
        PaletteCommand("Choose Window…",              key: "⌘⇧A",    action: #selector(AppDelegate.showWindowChooser(_:))),
        PaletteCommand("Next Tab",                    key: "⌘⌥→",    action: #selector(AppDelegate.nextDocument(_:))),
        PaletteCommand("Previous Tab",                key: "⌘⌥←",    action: #selector(AppDelegate.previousDocument(_:))),
        // Edit
        PaletteCommand("Undo",                        key: "⌘Z",     action: Selector(("undo:"))),
        PaletteCommand("Redo",                        key: "⌘⇧Z",    action: Selector(("redo:"))),
        PaletteCommand("Select All",                  key: "⌘A",     action: #selector(NSText.selectAll(_:))),
        PaletteCommand("Select Next Occurrence",      key: "⌘D",     action: #selector(AppDelegate.selectNextOccurrence(_:))),
        // Find (tags must match NSFindPanelAction raw values — see AppMenu.swift)
        PaletteCommand("Find…",                       key: "⌘F",
                       action: #selector(AppDelegate.openSearch(_:))),
        PaletteCommand("Find Next",                   key: "⌘G",
                       action: #selector(NSTextView.performFindPanelAction(_:)),
                       tag: Int(NSFindPanelAction.next.rawValue)),
        PaletteCommand("Find Previous",               key: "⌘⇧G",
                       action: #selector(NSTextView.performFindPanelAction(_:)),
                       tag: Int(NSFindPanelAction.previous.rawValue)),
        PaletteCommand("Use Selection for Find",      key: "⌘E",
                       action: #selector(NSTextView.performFindPanelAction(_:)),
                       tag: Int(NSFindPanelAction.setFindString.rawValue)),
        PaletteCommand("Find and Replace…",           key: "⌥⌘F",
                       action: #selector(NSTextView.performFindPanelAction(_:)),
                       tag: NSTextFinder.Action.showReplaceInterface.rawValue),
        // Code folding — greyed out automatically when no editor is focused
        PaletteCommand("Fold Block",                  key: "⌘⌥[",    action: Selector(("foldAtCursor:"))),
        PaletteCommand("Unfold Block",                key: "⌘⌥]",    action: Selector(("unfoldAtCursor:"))),
        // View
        PaletteCommand("Bigger Font",                 key: "⌘+",     action: #selector(AppDelegate.biggerFont(_:))),
        PaletteCommand("Smaller Font",                key: "⌘-",     action: #selector(AppDelegate.smallerFont(_:))),
        PaletteCommand("Actual Size",                 key: "⌘0",     action: #selector(AppDelegate.resetFont(_:))),
        PaletteCommand("Toggle Word Wrap",                             action: Selector(("toggleWordWrap:"))),
        PaletteCommand("Toggle Sidebar",              key: "⌘B",     action: #selector(NSSplitViewController.toggleSidebar(_:))),
        PaletteCommand("Show Explorer",               key: "⌘⇧E",    action: Selector(("showExplorerSidebar:"))),
        PaletteCommand("Show Source Control",         key: "⌃⇧G",    action: Selector(("showSourceControlSidebar:"))),
        PaletteCommand("Enter Full Screen",           key: "⌃⌘F",    action: #selector(NSWindow.toggleFullScreen(_:))),
        // Splits — greyed out by validateUserInterfaceItem when inappropriate
        PaletteCommand("Split Right",                 key: "⌘⇧\\",   action: Selector(("splitHorizontal:"))),
        PaletteCommand("Split Down",                  key: "⌘⇧-",    action: Selector(("splitVertical:"))),
        // Pane focus — greyed out when no split exists in the active tab
        PaletteCommand("Focus Pane Left",             key: "⌘⇧H",    action: Selector(("moveFocusLeft:"))),
        PaletteCommand("Focus Pane Down",             key: "⌘⇧J",    action: Selector(("moveFocusDown:"))),
        PaletteCommand("Focus Pane Up",               key: "⌘⇧K",    action: Selector(("moveFocusUp:"))),
        PaletteCommand("Focus Pane Right",            key: "⌘⇧L",    action: Selector(("moveFocusRight:"))),
        // Terminal integration
        PaletteCommand("Send Path to Terminal",       key: "⌘⇧C",    action: #selector(AppDelegate.sendPathToTerminal(_:))),
        PaletteCommand("Run in Terminal",             key: "⌘⇧R",    action: #selector(AppDelegate.runInTerminal(_:))),
        // Source Control — greyed out when no git repo is open
        PaletteCommand("Stage All Changes",                            action: #selector(AppDelegate.scStageAll(_:))),
        PaletteCommand("Unstage All Changes",                          action: #selector(AppDelegate.scUnstageAll(_:))),
        PaletteCommand("Commit…",                                      action: #selector(AppDelegate.scCommit(_:))),
        PaletteCommand("Push",                                         action: #selector(AppDelegate.scPush(_:))),
        PaletteCommand("Pull",                                         action: #selector(AppDelegate.scPull(_:))),
        PaletteCommand("Discard All Changes…",                         action: #selector(AppDelegate.scDiscardAll(_:))),
        // Config
        PaletteCommand("Settings…",                   key: "⌘,",     action: #selector(AppDelegate.openConfigFile(_:))),
        PaletteCommand("Reload Config",               key: "⌘R",     action: #selector(AppDelegate.reloadConfig(_:))),
        PaletteCommand("Check for Updates…",                           action: #selector(AppDelegate.checkForUpdates(_:))),
        // String selectors, not #selector: these two are answered by code that lands in the
        // standard-menus PR (clearBuffer: on GoblinPortalTerminalView, openHelp: on
        // AppDelegate). Written this way so each PR compiles alone and
        // check-palette-covers-menu.sh stays green once both merge; until then sendAction
        // finds no responder and the command is a no-op.
        PaletteCommand("Clear Buffer",                key: "⌘K",     action: Selector(("clearBuffer:"))),
        PaletteCommand("Goblin Portal Help",                           action: Selector(("openHelp:"))),
    ]

    /// Dynamic commands generated at show-time: one entry per open Space, so the
    /// palette doubles as a tmux ctrl-b w style window chooser when you type "space"
    /// or "switch". Rebuilt on each `toggle(in:)` call -- cheap, always fresh.
    static func spaceCommands() -> [PaletteCommand] {
        SpaceWindowController.open.enumerated().map { idx, wc in
            let name = wc.root.lastPathComponent
            let isCurrent = wc.window?.isKeyWindow == true
            let prefix = isCurrent ? "● " : ""
            return PaletteCommand(
                "\(prefix)Space: \(name)",
                key: idx < 9 ? "⌘\(idx + 1)" : "",
                action: #selector(AppDelegate.selectSpace(_:)),
                tag: idx)
        }
    }
}
