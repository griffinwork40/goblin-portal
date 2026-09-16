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
//  The `tag` field is required only for `performFindPanelAction:` senders — see
//  `AppMenu.swift`'s search block for the full explanation of why.
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
        PaletteCommand("Save",                     key: "⌘S",    action: #selector(AppDelegate.saveDocument(_:))),
        PaletteCommand("New Tab",                  key: "⌘T",    action: #selector(AppDelegate.newDocument(_:))),
        PaletteCommand("Close Tab",                key: "⌘W",    action: #selector(AppDelegate.closeDocument(_:))),
        // Navigate
        PaletteCommand("Go to Line…",              key: "⌘L",    action: #selector(AppDelegate.goToLine(_:))),
        PaletteCommand("Next Tab",                 key: "⌘⌥→",   action: #selector(AppDelegate.nextDocument(_:))),
        PaletteCommand("Previous Tab",             key: "⌘⌥←",   action: #selector(AppDelegate.previousDocument(_:))),
        // Edit
        PaletteCommand("Undo",                     key: "⌘Z",    action: Selector(("undo:"))),
        PaletteCommand("Redo",                     key: "⌘⇧Z",   action: Selector(("redo:"))),
        PaletteCommand("Select All",               key: "⌘A",    action: #selector(NSText.selectAll(_:))),
        PaletteCommand("Select Next Occurrence",   key: "⌘D",    action: #selector(AppDelegate.selectNextOccurrence(_:))),
        // Find (tags must match NSFindPanelAction raw values — see AppMenu.swift)
        PaletteCommand("Find…",                    key: "⌘F",
                       action: #selector(AppDelegate.openSearch(_:))),
        PaletteCommand("Find Next",                key: "⌘G",
                       action: #selector(NSTextView.performFindPanelAction(_:)),
                       tag: Int(NSFindPanelAction.next.rawValue)),
        PaletteCommand("Find Previous",            key: "⌘⇧G",
                       action: #selector(NSTextView.performFindPanelAction(_:)),
                       tag: Int(NSFindPanelAction.previous.rawValue)),
        PaletteCommand("Find and Replace…",        key: "⌥⌘F",
                       action: #selector(NSTextView.performFindPanelAction(_:)),
                       tag: NSTextFinder.Action.showReplaceInterface.rawValue),
        // View
        PaletteCommand("Bigger Font",              key: "⌘+",    action: #selector(AppDelegate.biggerFont(_:))),
        PaletteCommand("Smaller Font",             key: "⌘-",    action: #selector(AppDelegate.smallerFont(_:))),
        PaletteCommand("Actual Size",              key: "⌘0",    action: #selector(AppDelegate.resetFont(_:))),
        PaletteCommand("Toggle Word Wrap",                        action: #selector(AppDelegate.toggleWordWrap(_:))),
        PaletteCommand("Toggle Sidebar",           key: "⌘B",    action: #selector(NSSplitViewController.toggleSidebar(_:))),
        PaletteCommand("Enter Full Screen",        key: "⌃⌘F",   action: #selector(NSWindow.toggleFullScreen(_:))),
        // Terminal integration
        PaletteCommand("Send Path to Terminal",    key: "⌘⇧C",   action: #selector(AppDelegate.sendPathToTerminal(_:))),
        PaletteCommand("Run in Terminal",          key: "⌘⇧R",   action: #selector(AppDelegate.runInTerminal(_:))),
        // Config
        PaletteCommand("Settings…",               key: "⌘,",    action: #selector(AppDelegate.openConfigFile(_:))),
        PaletteCommand("Reload Config",            key: "⌘R",    action: #selector(AppDelegate.reloadConfig(_:))),
        PaletteCommand("New Space",                key: "⌘N",    action: #selector(AppDelegate.newSpace(_:))),
        // Splits
        PaletteCommand("Split Right",              key: "⌘⇧\\",  action: #selector(SpaceViewController.splitHorizontal(_:))),
        PaletteCommand("Split Down",               key: "⌘⇧-",   action: #selector(SpaceViewController.splitVertical(_:))),
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
