//
//  AppMenu.swift
//  The whole NSMenu tree — every key equivalent the app offers, in one place.
//

import AppKit

/// `AppDelegate`'s menu bar: the `buildMenu()` tree and nothing else.
///
/// Its own file because menu construction is a closed concern with a different
/// reason to change than the lifecycle and actions it points at — the actions are
/// *what the app does*, this is *how it is offered* — and it was two thirds of
/// `AppDelegate.swift`, which is the shape the 350-LOC ceiling exists to catch
/// (AFK.md, "Conventions"). An extension rather than a new type: these are still
/// the delegate's members, `NSApp.mainMenu` still wants one target for every
/// `#selector` below, and splitting the target out would mean promoting fourteen
/// `@objc` actions to reach it.
///
/// `validateMenuItem` is deliberately NOT here. It is the enablement half of the
/// Save *action* — its comment reads "the action above" and refers to
/// `saveDocument` — so it stays next to that action in `AppDelegate.swift` rather
/// than being filed under menu construction.
///
/// Nothing here is a Goblin Portal implementation of anything. Every item is either a
/// standard AppKit selector resolved through the responder chain (Copy, Paste,
/// Select All, full screen, Toggle Sidebar, scrollback search — see the Edit-menu
/// note on why search is SwiftTerm's) or one of the `@objc` actions in
/// `AppDelegate.swift`. Menu items carry no logic; they carry key equivalents,
/// `tag`s, and targets.
@MainActor
extension AppDelegate {
    /// Internal, not `private`: called from `applicationDidFinishLaunching` in
    /// `AppDelegate.swift`, and `private` is file-scoped in Swift. Nothing outside
    /// the module can see it either way — the target is an executable.
    func buildMenu() {
        let appName = "Goblin Portal"
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openConfigFile(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "r")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File menu — was "Shell". Renamed because its nouns are now Spaces and
        // documents, and a document is not necessarily a shell any more.
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Space", action: #selector(newSpace(_:)), keyEquivalent: "n")
        let newWindowItem = NSMenuItem(
            title: "New Space in New Window", action: #selector(newSpaceInWindow(_:)),
            keyEquivalent: "n")
        newWindowItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Open Folder…", action: #selector(openFolder(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newDocument(_:)), keyEquivalent: "t")
        fileMenu.addItem(.separator())
        // Grouped with the document verbs but fenced off from them: Save is the only
        // item in this menu that writes to the user's files.
        fileMenu.addItem(
            withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        // ⌘W closes the document. Closing the whole Space out from under the other
        // terminals in it is ⌘⇧W, which is the ordering every tabbed app uses.
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeDocument(_:)), keyEquivalent: "w")
        let closeSpaceItem = NSMenuItem(
            title: "Close Space", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeSpaceItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeSpaceItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit menu — the standard selectors; TerminalView implements them.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        // Undo/Redo. ⌘Z and ⌘⇧Z already worked before these items existed —
        // `FileViewerPane` sets `allowsUndo = true` (`FileViewerPane.swift:130`) and
        // AppKit's standard key bindings map the chords straight onto the text view —
        // so this is purely a discoverability fix: a user who does not already know
        // the chord had no way to learn the editor could undo at all.
        //
        // The class that actually implements `undo:`/`redo:` is **NSWindow**, not
        // NSTextView (verified with `instancesRespond(to:)`, 2026-07-28); the window
        // forwards to its `undoManager`, which is the focused text view's. So target
        // stays nil, AppKit walks the responder chain, and these reach the editor
        // without this menu — or the container — knowing an editor exists.
        //
        // Spelled as strings because no typed Swift selector exists for either:
        // `#selector(UndoManager.undo)` is the zero-argument `undo`, a different
        // selector that nothing in the responder chain answers. A typo here fails
        // *visibly* — the item greys out the first time the menu is opened — which is
        // what makes a string tolerable in a file that otherwise uses `#selector`.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())

        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())

        // Scrollback search. Nothing here implements searching — SwiftTerm already
        // ships the engine, the find bar, and the validation:
        // `performFindPanelAction` is `@objc open`
        // (`Mac/MacTerminalView.swift:2169`), it dispatches on `NSFindPanelAction`
        // raw values to `showFindBar` / `performFind(next:)`, and
        // `validateUserInterfaceItem` (`:2119`) already returns true for
        // showFindPanel/next/previous and gates setFindString on an active
        // selection. `GoblinPortalTerminalView` inherits all of it, so this menu is the
        // only missing piece.
        //
        // Two details that are load-bearing:
        //   * target stays nil so AppKit walks the responder chain to the focused
        //     terminal view. A hardcoded target would break the moment splits exist.
        //   * `performFindPanelAction` early-returns unless the sender IS an
        //     NSMenuItem and reads `menuItem.tag`, so every item below must carry a
        //     tag or it silently does nothing.
        // The tag type widens from `NSFindPanelAction` to a raw `Int` for one reason:
        // "show the replace row" is not in that enum. `NSFindPanelAction` stops at 10
        // and has no such case — the action is `NSTextFinder.Action`
        // `.showReplaceInterface` (12), which `NSTextView.performFindPanelAction`
        // forwards as an `NSTextFinder.Action` raw value. Both enums' raw values were
        // read off the SDK rather than hardcoded (2026-07-28), so a literal `12` never
        // appears here and the compiler owns the number.
        //
        // Replace needs no enablement logic and no terminal guard. SwiftTerm's
        // `validateUserInterfaceItem` (`Mac/MacTerminalView.swift:2119`) whitelists
        // only showFindPanel/next/previous/setFindString, so this item greys out
        // automatically whenever a terminal is the focused document — the right answer,
        // since scrollback is a transcript and cannot be rewritten. It enables itself
        // only over a real editor, which today means `FileViewerPane`.
        //
        // ⌥⌘F rather than a new chord: it is what TextEdit and Xcode both use, and it
        // survives `MacLineEditing.controlBytes`, which fires only on `intent ==
        // [.command]` exactly (`KeyBindings.swift`) — so the ⌥ keeps it off the pty for
        // the same reason plain ⌘F already reaches this menu untouched.
        let findItems: [(String, String, NSEvent.ModifierFlags, Int)] = [
            ("Find…", "f", [.command], Int(NSFindPanelAction.showFindPanel.rawValue)),
            ("Find Next", "g", [.command], Int(NSFindPanelAction.next.rawValue)),
            ("Find Previous", "g", [.command, .shift], Int(NSFindPanelAction.previous.rawValue)),
            ("Use Selection for Find", "e", [.command], Int(NSFindPanelAction.setFindString.rawValue)),
            (
                "Find and Replace…", "f", [.command, .option],
                NSTextFinder.Action.showReplaceInterface.rawValue
            ),
        ]
        for (title, key, mask, tag) in findItems {
            let item = NSMenuItem(
                title: title,
                action: #selector(NSTextView.performFindPanelAction(_:)),
                keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.tag = tag
            editMenu.addItem(item)
        }
        editMenu.addItem(.separator())
        // ⌘D — Select Next Occurrence. The entry point to multi-cursor editing.
        // Target is nil so AppKit walks the responder chain; `FileViewerPane`
        // answers `selectNextOccurrence:`; terminals don't, so the item greys
        // out automatically when a terminal tab is focused.
        let selectNextItem = NSMenuItem(
            title: "Select Next Occurrence",
            action: #selector(selectNextOccurrence(_:)), keyEquivalent: "d")
        editMenu.addItem(selectNextItem)
        editMenu.addItem(.separator())
        // Go to Line. ⌘L, the chord Xcode, BBEdit, Nova, CotEditor and Sublime all
        // use. `target: nil` so AppKit walks the responder chain — `FileViewerPane`
        // answers `goToLine:`, terminals do not, and the item greys itself out over
        // a terminal automatically (nobody in the responder chain responds).
        editMenu.addItem(
            withTitle: "Go to Line…",
            action: Selector(("goToLine:")), keyEquivalent: "l")
        editMenu.addItem(.separator())
        // Terminal integration — send information from the editor to the shell.
        // ⌘⇧C sends the current file's path; ⌘⇧R runs it with a language-detected
        // command. Both grey out when no file viewer is active or no shell is
        // available, via `validateMenuItem` in `AppDelegate.swift`.
        let sendPathItem = NSMenuItem(
            title: "Send Path to Terminal",
            action: #selector(sendPathToTerminal(_:)), keyEquivalent: "c")
        sendPathItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(sendPathItem)
        let runItem = NSMenuItem(
            title: "Run in Terminal",
            action: #selector(runInTerminal(_:)), keyEquivalent: "r")
        runItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(runItem)
        editMenu.addItem(.separator())
        // Code folding — indent-based, no AST. ⌘⌥[ collapses the block at the cursor;
        // ⌘⌥] expands it. Target is nil so AppKit walks the responder chain to the
        // focused FileViewerPane (which answers `foldAtCursor:` / `unfoldAtCursor:`);
        // items grey out automatically when a terminal is front.
        let foldItem = NSMenuItem(
            title: "Fold Block",
            action: Selector(("foldAtCursor:")), keyEquivalent: "[")
        foldItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(foldItem)
        let unfoldItem = NSMenuItem(
            title: "Unfold Block",
            action: Selector(("unfoldAtCursor:")), keyEquivalent: "]")
        unfoldItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(unfoldItem)

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // View menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // Shown as ⌘+ because that is what people read, but a key equivalent of
        // "+" only matches the literal plus glyph — i.e. ⌘⇧=. Pressing ⌘= (what
        // everyone actually does, and what every other app honours) matched
        // nothing in v0.1, so zoom appeared not to work at all. Verified with a
        // performKeyEquivalent harness: a HIDDEN item still matches its key
        // equivalent, which is the standard way to register the ⌘= alias without
        // showing a duplicate row in the menu.
        viewMenu.addItem(withTitle: "Bigger Font", action: #selector(biggerFont(_:)), keyEquivalent: "+")
        let plusAlias = NSMenuItem(
            title: "Bigger Font", action: #selector(biggerFont(_:)), keyEquivalent: "=")
        plusAlias.isHidden = true
        viewMenu.addItem(plusAlias)
        viewMenu.addItem(withTitle: "Smaller Font", action: #selector(smallerFont(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetFont(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        // ⌃⌘F, not ⌘F. ⌘F belonged to full screen until scrollback search existed,
        // and ⌘F is search's key everywhere on this platform — so full screen moves
        // rather than search taking a non-standard chord. ⌃⌘F is also what macOS
        // itself uses (System Settings › Keyboard › Shortcuts), so this is a
        // correction to the platform default, not a compromise.
        let fullScreenItem = NSMenuItem(
            title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem)
        viewMenu.addItem(.separator())
        // Word Wrap toggle. No key equivalent — ⌘⇧W is Close Space. The menu
        // item's state (checkmark) is managed by `validateUserInterfaceItem`; the
        // action is answered by `AppDelegate.toggleWordWrap(_:)` or routed to the
        // focused document through the responder chain.
        viewMenu.addItem(
            withTitle: "Word Wrap",
            action: Selector(("toggleWordWrap:")), keyEquivalent: "")
        viewMenu.addItem(.separator())
        // No custom action and no target: the responder chain reaches
        // SpaceViewController, which is the window's contentViewController and
        // inherits toggleSidebar(_:) from NSSplitViewController. Using the system
        // selector also gets the correct menu-item state and the collapse animation.
        viewMenu.addItem(
            withTitle: "Toggle Sidebar",
            action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "b")
        viewMenu.addItem(.separator())
        // Splits — tmux-inspired: ⌘⇧\ (pipe) splits right, ⌘⇧- splits down.
        // Target is nil so AppKit walks the responder chain to
        // `splitHorizontal:`/`splitVertical:` on SpaceViewController; greyed out
        // by `validateUserInterfaceItem` when inappropriate (no terminal or already
        // split).
        let splitItem = NSMenuItem(
            title: "Split Right",
            action: Selector(("splitHorizontal:")), keyEquivalent: "\\")
        splitItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(splitItem)
        let splitDownItem = NSMenuItem(
            title: "Split Down",
            action: Selector(("splitVertical:")), keyEquivalent: "-")
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(splitDownItem)
        viewMenu.addItem(.separator())
        // Pane focus — tmux-inspired h/j/k/l with ⌘⇧. Walks the responder chain
        // to `moveFocusLeft:`…`moveFocusRight:` on SpaceViewController; greyed out
        // by `validateUserInterfaceItem` when no split exists in the active tab.
        let focusItems: [(String, String, String)] = [
            ("Focus Pane Left", "h", "moveFocusLeft:"),
            ("Focus Pane Down", "j", "moveFocusDown:"),
            ("Focus Pane Up", "k", "moveFocusUp:"),
            ("Focus Pane Right", "l", "moveFocusRight:"),
        ]
        for (title, key, sel) in focusItems {
            let item = NSMenuItem(
                title: title, action: Selector((sel)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .shift]
            viewMenu.addItem(item)
        }
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        buildNavigateMenu(in: mainMenu)

        // Window menu — giving it the standard role is what makes the native tab
        // commands (Show All Tabs, Move Tab to New Window, …) appear.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    /// Arrow keys as a menu key equivalent: AppKit expresses them as function-key
    /// code points, not ASCII, so `"→"` or `"\u{2192}"` would silently never match.
    ///
    /// ⌘⌥← / ⌘⌥→ are verified safe against `KeyBindings.swift`: its guard is
    /// `intent == [.command]`, *exact* equality on the masked modifier set, so
    /// adding Option cannot collide with the ⌘←/⌘→ line-editing bytes (^A/^E) —
    /// the event falls through instead (plan §12.4 item 4).
    /// Internal, not `private`: `AppMenu+Navigate.swift` needs the same helper for
    /// ⌘⌥← / ⌘⌥→, and `private` stops at this file's edge.
    static func functionKeyEquivalent(_ functionKey: Int) -> String {
        String(utf16CodeUnits: [unichar(functionKey)], count: 1)
    }
}
