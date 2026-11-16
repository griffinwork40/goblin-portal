//
//  AppMenu+SourceControl.swift
//  The Source Control submenu: stage, unstage, commit, push, pull, session, discard.
//
//  Separated from `AppMenu.swift` because Source Control is an entire new concern,
//  and `AppMenu.swift` is already dense with the existing menu tree. This follows the
//  same extraction pattern as `AppMenu+Navigate.swift`.
//
//  All items use `target: nil` so they walk the responder chain — the `@objc` actions
//  are declared in `AppDelegate+SourceControl.swift`, which routes them to the focused
//  Space's source control panel.
//

import AppKit

extension AppDelegate {
    /// Insert a Source Control submenu into the main menu, before the Window menu.
    static func addSourceControlMenu(to mainMenu: NSMenu) {
        let scItem = NSMenuItem()
        let scMenu = NSMenu(title: "Source Control")

        scMenu.addItem(withTitle: "Stage All Changes",
                       action: #selector(AppDelegate.scStageAll(_:)),
                       keyEquivalent: "")

        scMenu.addItem(withTitle: "Unstage All Changes",
                       action: #selector(AppDelegate.scUnstageAll(_:)),
                       keyEquivalent: "")

        scMenu.addItem(.separator())

        scMenu.addItem(withTitle: "Commit…",
                       action: #selector(AppDelegate.scCommit(_:)),
                       keyEquivalent: "")

        scMenu.addItem(.separator())

        scMenu.addItem(withTitle: "Push",
                       action: #selector(AppDelegate.scPush(_:)),
                       keyEquivalent: "")

        scMenu.addItem(withTitle: "Pull",
                       action: #selector(AppDelegate.scPull(_:)),
                       keyEquivalent: "")

        scMenu.addItem(.separator())

        // Session items (#298). Static titles, no counts, no shortcuts: "session" here
        // means files observed changed since tracking started or was last cleared.
        scMenu.addItem(withTitle: "Stage Session Changes",
                       action: #selector(AppDelegate.scStageSessionChanges(_:)),
                       keyEquivalent: "")

        scMenu.addItem(withTitle: "Clear Session Highlights",
                       action: #selector(AppDelegate.scClearSessionHighlights(_:)),
                       keyEquivalent: "")

        scMenu.addItem(.separator())

        let discardItem = NSMenuItem(
            title: "Discard All Changes…",
            action: #selector(AppDelegate.scDiscardAll(_:)),
            keyEquivalent: "")
        scMenu.addItem(discardItem)

        scItem.submenu = scMenu
        // Insert before the Window menu (last system menu before Help).
        let insertIndex = max(0, mainMenu.numberOfItems - 2)
        mainMenu.insertItem(scItem, at: insertIndex)
    }
}
