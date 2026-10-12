//
//  check-titlebar-layout-harness.swift
//  The assertions for check-titlebar-layout.sh, which copies this file to main.swift and
//  links it against Goblin Portal's own objects (@testable import), like check-first-window.sh.
//
//  Its own file because the shell half carries the build, link and falsification logic, and
//  the two together would cross the 350-LOC ceiling (AFK.md, "Conventions": find the seam).
//
//  Every assertion measures the CONSUMER's real frames in window coordinates — the terminal
//  view, the sidebar's filter field — never `layoutTopInset`'s own return value, so a policy
//  that computes the right number and a layout that ignores it cannot pass together.
//  Failure lines are prefixed with the case id (`FAIL C1 …`) so --falsify can attribute a
//  mutant to the case that caught it.
//

import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ id: String, _ m: String) { print("  ok   \(id) \(m)") }
func fail(_ id: String, _ m: String) { print("  FAIL \(id) \(m)"); bad += 1 }
func env(_ m: String) -> Never { print("  ENV  \(m)"); exit(2) }
func f1(_ v: CGFloat) -> String { String(format: "%.1f", v) }

@MainActor func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}

let ownDomain = ProcessInfo.processInfo.processName
guard Bundle.main.bundleIdentifier == nil, ownDomain.hasPrefix("gp-titlebar-layout-check-") else {
    env("harness would not be writing to its own throwaway defaults domain (\(ownDomain))")
}
let real = UserDefaults(suiteName: "com.griffinlong.goblin-portal")
func realSnapshot() -> [String: String] {
    var out: [String: String] = [:]
    for (k, v) in real?.dictionaryRepresentation() ?? [:]
        where k.hasPrefix("NSWindow Frame") || k == "GoblinPortal.openSpaceRoots" { out[k] = "\(v)" }
    return out
}
let realBefore = realSnapshot()

/// One measured window: the terminal's top edge against the layout rect, and its grid.
struct Probe { let termTop: CGFloat; let layoutMaxY: CGFloat; let rows: Int; let cols: Int }

@MainActor func makeWindow(_ root: URL, fsc: Bool) -> SpaceWindowController {
    let wc = SpaceWindowController(config: .defaults(), root: root)
    guard let w = wc.window else { env("SpaceWindowController produced no window") }
    // The harness, not shipped code, turns the flag on: PR1 ships no way to reach it, so this
    // is the only route to the configuration the layout fix exists for.
    if fsc { w.styleMask.insert(.fullSizeContentView) }
    // Parked far off-screen; never activated, so no focus theft (check-sidebar-toggle.sh).
    w.setFrame(NSRect(x: -20000, y: -20000, width: 1100, height: 712), display: false)
    w.orderFront(nil); pump(0.4)
    wc.space.addTerminalDocument(start: false)  // no pty: geometry only
    pump(0.4)
    return wc
}

@MainActor func probe(_ wc: SpaceWindowController) -> Probe {
    guard let w = wc.window else { env("window vanished") }
    let space = wc.space
    guard let pane = space.documents[space.activeIndex] as? TerminalPane else {
        env("active document is not a TerminalPane")
    }
    let tv = pane.view
    let top = tv.convert(tv.bounds, to: nil).maxY
    let t = tv.getTerminal()
    return Probe(termTop: top, layoutMaxY: w.contentLayoutRect.maxY, rows: t.rows, cols: t.cols)
}

func describe(_ p: Probe) -> String {
    "terminal top \(f1(p.termTop)) vs contentLayoutRect.maxY \(f1(p.layoutMaxY)) "
        + "(Δ \(f1(p.termTop - p.layoutMaxY))), \(p.rows)x\(p.cols)"
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    defer { UserDefaults.standard.removePersistentDomain(forName: ownDomain) }
    guard NSScreen.main != nil else { env("no main screen — needs a window server") }
    print("  os = \(ProcessInfo.processInfo.operatingSystemVersionString)")

    // ---- C0: control, the shipped style mask -------------------------------------------------
    print("\n  C0 — control: default window (no fullSizeContentView)")
    let c0 = makeWindow(root, fsc: false)
    guard let w0 = c0.window else { env("no window") }
    let p0 = probe(c0)
    print("  \(describe(p0))")
    if w0.styleMask.contains(.fullSizeContentView) {
        fail("C0", "shipped style mask contains .fullSizeContentView — PR1 must not enable it")
    } else { ok("C0", "shipped style mask has no .fullSizeContentView") }
    if let cv = w0.contentView, cv.bounds.height == w0.contentLayoutRect.height {
        ok("C0", "contentLayoutRect == contentView bounds (\(f1(cv.bounds.height))pt): inset is 0")
    } else { fail("C0", "content view extends under the titlebar on the default mask") }
    if c0.space.documentArea.layoutTopInset == 0 { ok("C0", "layoutTopInset == 0 by default") }
    else { fail("C0", "layoutTopInset \(c0.space.documentArea.layoutTopInset) on the default mask") }
    if p0.termTop <= p0.layoutMaxY { ok("C0", "row 0 is below the titlebar") }
    else { fail("C0", "row 0 is under the titlebar on the DEFAULT window") }
    if p0.rows < 10 { env("control produced \(p0.rows) rows — the window did not lay out") }
    w0.orderOut(nil)

    // ---- C1: forced fullSizeContentView, same window size ------------------------------------
    print("\n  C1 — harness-forced .fullSizeContentView on a real SpaceWindowController")
    let c1 = makeWindow(root, fsc: true)
    guard let w1 = c1.window else { env("no window") }
    let p1 = probe(c1)
    print("  \(describe(p1)); docArea safeArea.top \(f1(c1.space.documentArea.view.safeAreaInsets.top))")
    if let cv = w1.contentView, cv.bounds.height <= w1.contentLayoutRect.height {
        env("forcing .fullSizeContentView did not extend the content view — nothing to test")
    }
    if p1.termTop <= p1.layoutMaxY { ok("C1", "row 0 stays below the titlebar band") }
    else { fail("C1", "row 0 is \(f1(p1.termTop - p1.layoutMaxY))pt under the titlebar") }
    if p1.rows == p0.rows && p1.cols == p0.cols { ok("C1", "grid \(p1.rows)x\(p1.cols) == control") }
    else { fail("C1", "grid \(p1.rows)x\(p1.cols) != control \(p0.rows)x\(p0.cols)") }

    // ---- C4: a second Space's native tab bar appears (no manual relayout) --------------------
    print("\n  C4 — second Space joins: native tab bar appears under .fullSizeContentView")
    let before4 = w1.contentLayoutRect.maxY
    let c4b = SpaceWindowController(config: .defaults(), root: root)
    guard let w4b = c4b.window else { env("no second window") }
    w4b.styleMask.insert(.fullSizeContentView)
    w1.addTabbedWindow(w4b, ordered: .above)
    w1.orderFront(nil); pump(0.8)   // NO layoutSubtreeIfNeeded: the fix must trigger itself
    let p4 = probe(c1)
    print("  contentLayoutRect.maxY \(f1(before4)) -> \(f1(p4.layoutMaxY)); \(describe(p4))")
    if p4.layoutMaxY >= before4 {
        env("the tab bar did not shrink contentLayoutRect (tab bar not shown?) — C4 cannot judge")
    }
    if p4.termTop <= p4.layoutMaxY { ok("C4", "row 0 moved below the tab bar without a resize") }
    else { fail("C4", "row 0 is \(f1(p4.termTop - p4.layoutMaxY))pt under the tab bar (stale layout)") }
    w4b.orderOut(nil); pump(0.6)    // removes the tab; the layout rect grows back

    // ---- C5: a .bottom titlebar accessory (ConfigWarningBanner's attachment) ------------------
    print("\n  C5 — a 36pt .bottom titlebar accessory appears under .fullSizeContentView")
    let before5 = w1.contentLayoutRect.maxY
    let acc = NSTitlebarAccessoryViewController()
    acc.layoutAttribute = .bottom          // ConfigWarningBanner.swift:48
    acc.automaticallyAdjustsSize = false   // ConfigWarningBanner.swift:53
    acc.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 36))
    w1.addTitlebarAccessoryViewController(acc); pump(0.6)
    let p5 = probe(c1)
    print("  contentLayoutRect.maxY \(f1(before5)) -> \(f1(p5.layoutMaxY)); \(describe(p5))")
    if p5.layoutMaxY >= before5 { env("the accessory did not shrink contentLayoutRect — C5 cannot judge") }
    if p5.termTop <= p5.layoutMaxY { ok("C5", "row 0 moved below the accessory without a resize") }
    else { fail("C5", "row 0 is \(f1(p5.termTop - p5.layoutMaxY))pt under the accessory (stale layout)") }
    if let i = w1.titlebarAccessoryViewControllers.firstIndex(of: acc) {
        w1.removeTitlebarAccessoryViewController(at: i); pump(0.4)
    }

    // ---- C7: sidebar controls clear the traffic lights ---------------------------------------
    print("\n  C7 — sidebar's first control sits below its safe area under .fullSizeContentView")
    let tree = c1.space.fileTree
    let field = tree.filterField
    let fieldTop = field.convert(field.bounds, to: nil).maxY
    let safeTop = tree.view.convert(tree.view.safeAreaRect, to: nil).maxY
    var lightsMinY = CGFloat.greatestFiniteMagnitude
    for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
        if let v = w1.standardWindowButton(b), !v.isHidden { lightsMinY = min(lightsMinY, v.convert(v.bounds, to: nil).minY) }
    }
    print("  filter field top \(f1(fieldTop)), sidebar safe-area top \(f1(safeTop)), traffic lights minY \(f1(lightsMinY))")
    if safeTop >= tree.view.convert(tree.view.bounds, to: nil).maxY {
        env("the sidebar has no top safe-area inset under .fullSizeContentView — C7 cannot judge")
    }
    if fieldTop <= safeTop && fieldTop <= lightsMinY { ok("C7", "filter field is below the titlebar band") }
    else { fail("C7", "filter field top \(f1(fieldTop)) is inside the titlebar band (safe top \(f1(safeTop)))") }
    w1.orderOut(nil)

    // ---- ISOLATION ---------------------------------------------------------------------------
    print("\n  ISO — real defaults domain")
    if realSnapshot() == realBefore { ok("ISO", "real com.griffinlong.goblin-portal frame keys + open roots unchanged") }
    else { fail("ISO", "the REAL com.griffinlong.goblin-portal domain changed during this run") }

    print(bad == 0 ? "\nall titlebar-layout cases passed" : "\n\(bad) titlebar-layout case(s) FAILED")
    exit(bad == 0 ? 0 : 1)
}
