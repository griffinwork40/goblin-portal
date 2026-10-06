// check-sidebar-activity-harness.swift
// Compiled and linked by check-sidebar-activity.sh against GoblinPortal's own
// object files. This file holds all Swift assertions; the shell script holds
// environment checks, build, and link. Same split as check-git-status-harness.swift.
//
// EXIT CODES (matches the shell wrapper):
//   0 = all cases passed
//   1 = a real assertion failed
//   2 = environmental failure (objects missing, window not created, etc.)
//
// CASES:
//   1  INITIAL-STATE  — right after SCM install, exactly one group is visible
//                       and it is Explorer. Addresses C2.
//   2  VIEW SWAP      — switchSidebarActivity(.scm) hides Explorer, shows SCM;
//                       switchSidebarActivity(.explorer) reverses.
//   3  MENU-SELECTOR  — read showExplorerSidebar: and showSourceControlSidebar:
//                       from the REAL built menu (View items by title), then walk
//                       window.firstResponder → nextResponder confirming responds(to:).
//                       The CONTROL case uses a bogus selector and must get nil.
//   4  BADGE COUNT    — pushBadgeCount(7) shows badge "7"; pushBadgeCount(0) hides it.
//   5  NO-REPO        — a Space on a non-git temp dir shows no switcher and the
//                       Explorer tree is visible.

import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String)   { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

/// Pump the main run loop so view-swap side-effects propagate.
@MainActor func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

/// Walk the responder chain from `start`, returning the first responder that
/// responds to `sel`, or nil if none does. Matches the behavior AppKit uses
/// for nil-target actions — it walks firstResponder.nextResponder.nextResponder
/// without requiring a key window. This is the T2 fix: under .accessory policy
/// NSApp.target(forAction:to:nil,from:nil) always returns nil because the window
/// never activates; walking the chain directly gives the correct answer.
@MainActor func findResponder(for sel: Selector, startingAt start: NSResponder?) -> NSResponder? {
    var r: NSResponder? = start
    while let current = r {
        if current.responds(to: sel) { return current }
        r = current.nextResponder
    }
    return nil
}

MainActor.assumeIsolated {
    let spaceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let noGitRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

    // Build the app menu so NSApp.mainMenu carries the real View items.
    // AppDelegate.buildMenu() is internal; call it here the same way
    // applicationDidFinishLaunching does, so the harness sees the real selectors
    // the menu items send. Without this call mainMenu is nil and all View-item
    // lookups return nil (T2 fix).
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    appDelegate.buildMenu()

    // ============================================================================================
    // REPO SPACE SETUP
    // ============================================================================================
    let wc = SpaceWindowController(config: .defaults(), root: spaceRoot)
    guard let window = wc.window else {
        print("  ENV  SpaceWindowController produced no window")
        exit(2)
    }
    let space = wc.space

    // Install the SCM panel — the same lazy path the first git-status snapshot
    // triggers in production. The harness calls through the same public surface.
    space.fileTree.installSourceControlPanel(from: space)

    window.setFrame(NSRect(x: -20000, y: -20000, width: 1100, height: 680), display: false)
    window.orderFront(nil)
    window.makeKey()
    pump(0.5)

    // ============================================================================================
    // CASE 1 — INITIAL STATE.
    // Right after SCM install exactly one group is visible, and it is Explorer.
    // This is the C2 regression check: without switchSidebarActivity after install,
    // both groups were visible simultaneously.
    // ============================================================================================
    print("  [case 1] initial state after installSourceControlPanel")
    let explorerScrollVisible  = !space.fileTree.sidebarScrollView.isHidden
    let explorerGitHdrVisible  = !space.fileTree.gitHeader.isHidden
    let explorerFilterVisible  = !space.fileTree.filterField.isHidden
    let scmPanelHidden         = space.scmPanelViewController?.view.isHidden ?? true
    let scmDividerHidden       = space.scmDividerView?.isHidden ?? true
    let switcherActivityExpl   = space.currentSidebarActivity == .explorer

    print("  initial: scrollVisible=\(explorerScrollVisible) gitHdrVisible=\(explorerGitHdrVisible)"
        + " filterVisible=\(explorerFilterVisible) scmPanelHidden=\(scmPanelHidden)"
        + " scmDividerHidden=\(scmDividerHidden) activity=\(switcherActivityExpl ? "explorer" : "scm")")

    if explorerScrollVisible && explorerGitHdrVisible && explorerFilterVisible
        && scmPanelHidden && scmDividerHidden && switcherActivityExpl {
        ok("initial state: Explorer visible, SCM hidden, activity=.explorer")
    } else {
        fail("initial state wrong — Explorer and SCM both visible, or wrong activity."
            + " (C2: call switchSidebarActivity after installActivitySwitcher)")
    }

    // ============================================================================================
    // CASE 2 — VIEW SWAP.
    // Drive the swap via the public API; Cases 3 confirms the menu selectors reach it.
    // ============================================================================================
    print("  [case 2] view swap via switchSidebarActivity")
    space.switchSidebarActivity(.scm)
    pump(0.2)

    let scrollHiddenSCM    = space.fileTree.sidebarScrollView.isHidden
    let gitHdrHiddenSCM    = space.fileTree.gitHeader.isHidden
    let filterHiddenSCM    = space.fileTree.filterField.isHidden
    let scmVisibleSCM      = !(space.scmPanelViewController?.view.isHidden ?? true)
    print("  after .scm: scrollHidden=\(scrollHiddenSCM) gitHdrHidden=\(gitHdrHiddenSCM)"
        + " filterHidden=\(filterHiddenSCM) scmVisible=\(scmVisibleSCM)")
    if scrollHiddenSCM && gitHdrHiddenSCM && filterHiddenSCM && scmVisibleSCM {
        ok("view-swap to SCM: Explorer hidden, SCM panel visible")
    } else {
        fail("view-swap to SCM wrong — scroll/filter/gitHdr not all hidden, or SCM not visible")
    }

    space.switchSidebarActivity(.explorer)
    pump(0.2)

    let scrollVisibleExpl  = !space.fileTree.sidebarScrollView.isHidden
    let gitHdrVisibleExpl  = !space.fileTree.gitHeader.isHidden
    let filterVisibleExpl  = !space.fileTree.filterField.isHidden
    let scmHiddenExpl      = space.scmPanelViewController?.view.isHidden ?? true
    print("  after .explorer: scrollVisible=\(scrollVisibleExpl) gitHdrVisible=\(gitHdrVisibleExpl)"
        + " filterVisible=\(filterVisibleExpl) scmHidden=\(scmHiddenExpl)")
    if scrollVisibleExpl && gitHdrVisibleExpl && filterVisibleExpl && scmHiddenExpl {
        ok("view-swap to Explorer: Explorer visible, SCM panel hidden")
    } else {
        fail("view-swap to Explorer wrong — Explorer views not all visible, or SCM not hidden")
    }

    // ============================================================================================
    // CASE 3 — MENU-SELECTOR RESOLUTION.
    //
    // Read the selectors from the REAL built menu (AppDelegate.buildMenu() already ran via
    // NSApp initialisation; we find the View items by title). Then walk window.firstResponder
    // → nextResponder testing responds(to:) — this is what AppKit does for nil-target items
    // and it works correctly under .accessory policy (unlike NSApp.target(forAction:to:nil,
    // from:nil) which requires an active key window). T2 fix.
    //
    // CONTROL: a bogus selector must produce nil via the same walk — proving the walk is not
    // vacuously returning the first responder regardless of selector.
    // ============================================================================================
    print("  [case 3] menu-selector resolution via responder chain walk")

    // Find View menu items by title — reads the selector the MENU actually sends, not
    // the selector the test author had in mind (the distinction T2 exists to enforce).
    var explorerMenuSel: Selector? = nil
    var scmMenuSel:      Selector? = nil
    if let mainMenu = NSApp.mainMenu {
        for item in mainMenu.items {
            guard let sub = item.submenu else { continue }
            for subItem in sub.items {
                if subItem.title == "Show Explorer" {
                    explorerMenuSel = subItem.action
                } else if subItem.title == "Show Source Control" {
                    scmMenuSel = subItem.action
                }
            }
        }
    }
    print("  Show Explorer action: \(String(describing: explorerMenuSel))")
    print("  Show Source Control action: \(String(describing: scmMenuSel))")

    if explorerMenuSel == nil {
        fail("'Show Explorer' menu item not found — AppDelegate.buildMenu() may not have run")
    }
    if scmMenuSel == nil {
        fail("'Show Source Control' menu item not found — AppDelegate.buildMenu() may not have run")
    }

    // Walk the chain starting from the file tree's outline view — a concrete leaf
    // inside the window's view hierarchy. AppKit's nil-target action dispatch walks
    // firstResponder → nextResponder, and NSView.nextResponder is its superview's
    // controller, then the view controller chain up through SpaceViewController.
    // Walking from the content view or the outline view reaches SpaceViewController;
    // walking from window.firstResponder (NSWindow) reaches only NSWindow→NSApp→delegate,
    // which is what the .accessory policy gives us. Using fileTree.outlineView as the
    // start is what the menu item's actual responder search would do if the tree had focus.
    let firstR: NSResponder = space.fileTree.outlineView
    print("  chain walk origin: \(type(of: firstR))")

    if let sel = explorerMenuSel {
        let target = findResponder(for: sel, startingAt: firstR)
        print("  chain walk for showExplorerSidebar: -> \(String(describing: target.map { type(of: $0) }))")
        if let target {
            ok("showExplorerSidebar: resolves via chain to \(type(of: target))")
        } else {
            fail("showExplorerSidebar: resolves to nil — ⌘⇧E would silently do nothing")
        }
    }
    if let sel = scmMenuSel {
        let target = findResponder(for: sel, startingAt: firstR)
        print("  chain walk for showSourceControlSidebar: -> \(String(describing: target.map { type(of: $0) }))")
        if let target {
            ok("showSourceControlSidebar: resolves via chain to \(type(of: target))")
        } else {
            fail("showSourceControlSidebar: resolves to nil — ⌃⇧G would silently do nothing")
        }
    }

    // CONTROL: bogus selector must not resolve from the same start point.
    // The same chain that found the real selectors must reject a typo'd one —
    // otherwise the walk is vacuous (T2 requirement).
    let bogusSel = NSSelectorFromString("umberProbeNoSuchAction:")
    let controlTarget = findResponder(for: bogusSel, startingAt: firstR)
    print("  chain walk for umberProbeNoSuchAction: -> \(String(describing: controlTarget.map { type(of: $0) }))")
    if let controlTarget {
        fail("CONTROL: bogus selector resolved to \(type(of: controlTarget)) — chain walk is vacuous")
    } else {
        ok("control: bogus selector correctly resolved to nil")
    }

    // ============================================================================================
    // CASE 4 — BADGE COUNT.
    // ============================================================================================
    print("  [case 4] badge count")
    space.pushBadgeCount(7)
    pump(0.1)
    let switcher = space.sidebarActivitySwitcher
    let badgeLabel = switcher.subviews.first(where: { $0 is NSTextField }) as? NSTextField
    if let bl = badgeLabel {
        print("  badge: isHidden=\(bl.isHidden) stringValue=\"\(bl.stringValue)\" (count=7)")
        if !bl.isHidden && bl.stringValue == "7" {
            ok("badge visible with count=7, text=\"7\"")
        } else {
            fail("badge incorrect after count=7: isHidden=\(bl.isHidden) stringValue=\"\(bl.stringValue)\"")
        }
    } else {
        fail("badge NSTextField not found in SidebarActivitySwitcher subviews")
    }
    space.pushBadgeCount(0)
    pump(0.1)
    if let bl = badgeLabel {
        print("  badge: isHidden=\(bl.isHidden) (count=0)")
        if bl.isHidden { ok("badge hidden after count=0") }
        else { fail("badge still visible after count=0: stringValue=\"\(bl.stringValue)\"") }
    }

    // ============================================================================================
    // CASE 5 — NO-REPO SPACE.
    // A Space on a non-git temp dir: after the git poller concludes there is no
    // repository (hasRepo: false), the switcher must be hidden and the Explorer tree
    // must be visible. We simulate the poller's outcome by calling
    // updateSwitcherVisibility(hasRepo:false) directly — the same call
    // updateSourceControl makes when repository is nil.
    // ============================================================================================
    print("  [case 5] no-repo space")
    let wc2 = SpaceWindowController(config: .defaults(), root: noGitRoot)
    guard let window2 = wc2.window else {
        print("  ENV  second SpaceWindowController produced no window")
        exit(2)
    }
    let space2 = wc2.space
    space2.fileTree.installSourceControlPanel(from: space2)
    window2.setFrame(NSRect(x: -22000, y: -22000, width: 1100, height: 680), display: false)
    window2.orderFront(nil)
    pump(0.2)

    // Simulate the git poller reporting no repo — the same path updateSourceControl
    // takes when GitStatusReader.discoverRepository returns nil.
    space2.updateSwitcherVisibility(hasRepo: false)
    pump(0.1)

    let switcherHidden2  = space2.sidebarActivitySwitcher.isHidden
    let scrollVisible2   = !space2.fileTree.sidebarScrollView.isHidden
    print("  no-repo: switcherHidden=\(switcherHidden2) scrollVisible=\(scrollVisible2)")
    if switcherHidden2 && scrollVisible2 {
        ok("no-repo: switcher hidden, Explorer tree visible")
    } else {
        fail("no-repo: expected switcher hidden and tree visible — "
            + "switcherHidden=\(switcherHidden2) scrollVisible=\(scrollVisible2)")
    }

    // ============================================================================================
    // RESULT
    // ============================================================================================
    if bad == 0 {
        print("\nall sidebar-activity cases passed (initial-state + view-swap + selectors + badge + no-repo)")
    } else {
        print("\n\(bad) sidebar-activity case(s) FAILED")
    }
    exit(bad == 0 ? 0 : 1)
}
