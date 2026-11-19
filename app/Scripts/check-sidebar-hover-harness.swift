// check-sidebar-hover-harness.swift — compiled and run by check-sidebar-hover.sh.
//
// Drives a REAL SpaceWindowController (offscreen, .accessory, never activated) and asks two
// questions per case: what does the sidebar NSSplitViewItem's `revealsOnEdgeHoverInFullscreen`
// read, and does the NSSplitViewController agree (`_hasItemToRevealOnEdgeHover`, which AppKit
// re-derives from the item flag live — measured on macOS 27.2 while writing this gate)?
// The second read is what makes this more than "we called setValue": it is AppKit's own
// answer to "is there an item to reveal when the pointer hits the edge?".
//
// Every failure line is `  FAIL <case>: …` so the shell can attribute a mutant to its case.
// Exit 0 = all cases passed, 1 = a case failed, 2 = environmental (key missing on this macOS).

import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ c: String, _ m: String) { print("  ok   \(c): \(m)") }
func fail(_ c: String, _ m: String) { print("  FAIL \(c): \(m)"); bad += 1 }

@MainActor func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}

@MainActor func itemFlag(_ wc: SpaceWindowController) -> Bool? {
    wc.space.splitViewItems.first?.value(forKey: SpaceViewController.sidebarHoverRevealKey) as? Bool
}

@MainActor func controllerFlag(_ wc: SpaceWindowController) -> Bool? {
    wc.space.value(forKey: "_hasItemToRevealOnEdgeHover") as? Bool
}

@MainActor func open(_ config: AppConfig, _ root: URL) -> SpaceWindowController {
    let wc = SpaceWindowController(config: config, root: root)
    wc.window?.setFrame(NSRect(x: -20000, y: -20000, width: 1100, height: 680), display: false)
    wc.window?.orderFront(nil)
    pump(0.3)
    return wc
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

    // H0 — ENV: the accessor exists on this macOS. Without it every other case is meaningless,
    // and the shipped code deliberately degrades to the system behaviour (+ a stderr line).
    let probe = NSSplitViewItem(sidebarWithViewController: NSViewController())
    guard probe.responds(to: NSSelectorFromString("setRevealsOnEdgeHoverInFullscreen:")) else {
        print("  ENV  NSSplitViewItem has no setRevealsOnEdgeHoverInFullscreen: on this macOS")
        exit(2)
    }

    // H1 — DEFAULT: an untouched config keeps AppKit's behaviour (no silent behaviour change).
    let wcDefault = open(.defaults(), root)
    if itemFlag(wcDefault) == true { ok("H1", "default config leaves the item flag true") }
    else { fail("H1", "default config: item flag = \(String(describing: itemFlag(wcDefault))), want true") }
    wcDefault.window?.close()

    // H2 — OFF AT INIT: `"revealOnHover": false` reaches the item through SpaceWindowController's
    // own init path (the harness calls nothing else), and AppKit agrees with the sidebar collapsed.
    var off = AppConfig.defaults(); off.sidebarRevealOnHover = false
    let wc = open(off, root)
    guard let item = wc.space.splitViewItems.first else { print("  ENV  no split items"); exit(2) }
    item.isCollapsed = true
    pump(0.6)
    if itemFlag(wc) == false { ok("H2", "init with revealOnHover=false sets the item flag false") }
    else { fail("H2", "init with revealOnHover=false: item flag = \(String(describing: itemFlag(wc)))") }
    if controllerFlag(wc) == false { ok("H2", "collapsed + off: split controller has no item to reveal") }
    else { fail("H2", "collapsed + off: _hasItemToRevealOnEdgeHover = \(String(describing: controllerFlag(wc)))") }

    // H3 — RELOAD ON, and the CONTROL for H2's controller read: the same observable must be able
    // to read TRUE on this machine, or H2's `false` measures nothing.
    var on = AppConfig.defaults(); on.sidebarRevealOnHover = true
    wc.space.apply(config: on)
    wc.space.applySidebarHoverReveal()  // the call AppDelegate.reloadConfig makes (wiring grep W3)
    pump(0.3)
    if itemFlag(wc) == true && controllerFlag(wc) == true {
        ok("H3", "reload to true: item flag and split controller both true (control is live)")
    } else {
        fail("H3", "reload to true: item = \(String(describing: itemFlag(wc))), controller = \(String(describing: controllerFlag(wc)))")
    }

    // H4 — RELOAD OFF: the live path turns it back off, not just init.
    wc.space.apply(config: off)
    wc.space.applySidebarHoverReveal()
    pump(0.3)
    if itemFlag(wc) == false && controllerFlag(wc) == false { ok("H4", "reload to false turns it off again") }
    else { fail("H4", "reload to false: item = \(String(describing: itemFlag(wc))), controller = \(String(describing: controllerFlag(wc)))") }

    wc.window?.close()
    print(bad == 0 ? "\nall sidebar-hover cases passed" : "\n\(bad) sidebar-hover check(s) FAILED")
    exit(bad == 0 ? 0 : 1)
}
