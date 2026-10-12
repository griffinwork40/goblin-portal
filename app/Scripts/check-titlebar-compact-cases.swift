//
//  check-titlebar-compact-cases.swift
//  The `"titlebar": "compact"` cases for check-titlebar-layout.sh. Compiled alongside
//  check-titlebar-layout-harness.swift (which owns main, the helpers and C0) and linked
//  against Goblin Portal's own objects.
//
//  Its own file because the PR1 harness plus these cases would cross the 350-LOC ceiling.
//  Same rules as its sibling: every assertion measures the consumer's real frames (terminal
//  view, tab strip) in window coordinates, never `layoutTopInset`'s own return value, and
//  every FAIL line carries its case id so --falsify can attribute a mutant.
//

import AppKit
@testable import GoblinPortal

@MainActor func compactConfig() -> AppConfig {
    var c = AppConfig.defaults(); c.titlebar = .compact; return c
}

/// A root no earlier case has saved a frame under (frame autosave is per root).
func freshRoot(_ base: URL, _ name: String) -> URL {
    let u = base.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@MainActor func termMinX(_ wc: SpaceWindowController) -> CGFloat {
    guard let pane = wc.space.documents[wc.space.activeIndex] as? TerminalPane else { return 0 }
    return pane.view.convert(pane.view.bounds, to: nil).minX
}

@MainActor func setSidebar(_ wc: SpaceWindowController, collapsed: Bool) {
    wc.space.splitViewItems.first?.isCollapsed = collapsed
    pump(0.5)
}

@MainActor func runCompactCases(root: URL, r0: Probe) {
    // ---- M: the measurement table (informational; the assertions below use these windows) ----
    print("\n  M — rows x cols at 1100x712 frame (1100x680 standard content)")
    var grid: [String: Probe] = [:]
    for style in [TitlebarStyle.standard, .compact] {
        for docs in [1, 2] {
            for collapsed in [false, true] {
                var cfg = AppConfig.defaults(); cfg.titlebar = style
                let wc = makeWindow(freshRoot(root, "m-\(style)-\(docs)-\(collapsed)"), fsc: false, config: cfg)
                if docs == 2 { wc.space.addTerminalDocument(start: false); pump(0.4) }
                setSidebar(wc, collapsed: collapsed)
                let p = probe(wc)
                grid["\(style)-\(docs)-\(collapsed)"] = p
                print("  M    \(style) \(docs) doc(s) sidebar \(collapsed ? "collapsed" : "visible"): "
                    + "\(p.rows)x\(p.cols) (Δ \(f1(p.termTop - p.layoutMaxY)))")
                wc.window?.orderOut(nil)
            }
        }
    }

    // ---- C2: compact, sidebar visible, 1 doc --------------------------------------------------
    print("\n  C2 — compact, sidebar visible, 1 document")
    let c2 = makeWindow(freshRoot(root, "c2"), fsc: false, config: compactConfig())
    guard let w2 = c2.window else { env("no window") }
    if !w2.allowsContentInTitleRow { fail("C2", "compact config did not produce a full-size, transparent, title-less window") }
    let p2 = probe(c2), ctl = w2.titleRowControlsMaxX, minX2 = termMinX(c2)
    print("  \(describe(p2)); terminal minX \(f1(minX2)) vs controls maxX \(f1(ctl))")
    if ctl <= 0 { env("no traffic lights / toggle found in the title row — C2 cannot judge") }
    if p2.termTop > p2.layoutMaxY { ok("C2", "terminal entered the title row (+\(f1(p2.termTop - p2.layoutMaxY))pt)") }
    else { fail("C2", "terminal top \(f1(p2.termTop)) did not enter the band (layout maxY \(f1(p2.layoutMaxY)))") }
    if minX2 >= ctl + TitlebarStyle.controlsClearance { ok("C2", "terminal clears the window controls") }
    else { fail("C2", "terminal minX \(f1(minX2)) is under the window controls (maxX \(f1(ctl)))") }
    if p2.rows > r0.rows { ok("C2", "rows \(p2.rows) > standard \(r0.rows)") }
    else { fail("C2", "rows \(p2.rows) not above standard \(r0.rows)") }

    // ---- C3: compact, sidebar collapsed → traffic lights over the terminal, band withheld ------
    print("\n  C3 — compact, sidebar collapsed")
    setSidebar(c2, collapsed: true)
    let p3 = probe(c2), minX3 = termMinX(c2)
    print("  \(describe(p3)); terminal minX \(f1(minX3)) vs controls maxX \(f1(w2.titleRowControlsMaxX))")
    if minX3 >= w2.titleRowControlsMaxX { env("collapsing the sidebar did not put the controls over the terminal") }
    if p3.termTop <= p3.layoutMaxY { ok("C3", "band withheld: row 0 is below the title row") }
    else { fail("C3", "row 0 is \(f1(p3.termTop - p3.layoutMaxY))pt under the traffic lights") }
    setSidebar(c2, collapsed: false)
    if probe(c2).termTop > p2.layoutMaxY { ok("C3", "band returned on re-expand") }
    else { fail("C3", "band not returned after the sidebar re-expanded (stale layout)") }

    // ---- C6: compact, 2 docs, sidebar visible → strip in the band ------------------------------
    print("\n  C6 — compact, 2 documents, sidebar visible")
    c2.space.addTerminalDocument(start: false); pump(0.4)
    let strip = c2.space.documentArea.strip
    let sf = strip.convert(strip.bounds, to: nil), p6 = probe(c2)
    print("  strip \(sf); \(describe(p6))")
    if sf.height <= 0 { env("tab strip not visible with 2 documents") }
    if sf.maxY > p6.layoutMaxY && sf.minX >= ctl + TitlebarStyle.controlsClearance {
        ok("C6", "strip sits in the band, clear of the controls")
    } else { fail("C6", "strip \(sf) not in the band / under the controls (\(f1(ctl)))") }
    if p6.termTop <= sf.minY + 0.5 { ok("C6", "terminal below the strip") }
    else { fail("C6", "terminal top \(f1(p6.termTop)) overlaps the strip (minY \(f1(sf.minY)))") }

    // ---- C4c / C5c: tab bar or banner under compact → full inset, no overlap -------------------
    print("\n  C4c — compact + second Space (native tab bar)")
    let other = SpaceWindowController(config: compactConfig(), root: freshRoot(root, "c4c"))
    guard let wo = other.window else { env("no second window") }
    w2.addTabbedWindow(wo, ordered: .above); w2.orderFront(nil); pump(0.8)
    let p4 = probe(c2), s4 = c2.space.documentArea.strip
    let s4top = s4.convert(s4.bounds, to: nil).maxY
    print("  strip top \(f1(s4top)); \(describe(p4))")
    if p4.layoutMaxY >= p6.layoutMaxY { env("tab bar did not shrink contentLayoutRect — C4c cannot judge") }
    if s4top <= p4.layoutMaxY + 0.5 && p4.termTop <= p4.layoutMaxY { ok("C4c", "strip and terminal below the tab bar") }
    else { fail("C4c", "content overlaps the tab bar (strip top \(f1(s4top)) vs \(f1(p4.layoutMaxY)))") }
    wo.orderOut(nil); pump(0.6)
    print("\n  C5c — compact + .bottom accessory (ConfigWarningBanner)")
    let acc = NSTitlebarAccessoryViewController()
    acc.layoutAttribute = .bottom; acc.automaticallyAdjustsSize = false
    acc.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 36))
    w2.addTitlebarAccessoryViewController(acc); pump(0.6)
    let s5 = c2.space.documentArea.strip, p5 = probe(c2)
    let s5top = s5.convert(s5.bounds, to: nil).maxY
    print("  strip top \(f1(s5top)); \(describe(p5))")
    if s5top <= p5.layoutMaxY + 0.5 && p5.termTop <= p5.layoutMaxY { ok("C5c", "strip and terminal below the banner") }
    else { fail("C5c", "content overlaps the banner (strip top \(f1(s5top)) vs \(f1(p5.layoutMaxY)))") }
    if let i = w2.titlebarAccessoryViewControllers.firstIndex(of: acc) { w2.removeTitlebarAccessoryViewController(at: i) }
    w2.orderOut(nil)

    // ---- C8: first-window frame under compact + poisoned-frame repair --------------------------
    print("\n  C8 — compact first window: same frame as standard; poisoned frame repaired")
    let std = SpaceWindowController(config: .defaults(), root: freshRoot(root, "c8-std"))
    let cmp = SpaceWindowController(config: compactConfig(), root: freshRoot(root, "c8-cmp"))
    guard let ws = std.window, let wcmp = cmp.window, let vis = NSScreen.main?.visibleFrame else { env("no window") }
    print("  standard frame \(ws.frame.size), compact frame \(wcmp.frame.size)")
    if wcmp.frame.size == ws.frame.size { ok("C8", "compact first frame == standard (\(wcmp.frame.size))") }
    else { fail("C8", "compact first frame \(wcmp.frame.size) != standard \(ws.frame.size)") }
    let poisonRoot = freshRoot(root, "c8-poison"), s = NSScreen.main?.frame ?? .zero
    UserDefaults.standard.set("\(Int(vis.minX + 300)) \(Int(vis.minY + 40)) 500 532 "
        + "\(Int(s.minX)) \(Int(s.minY)) \(Int(s.width)) \(Int(s.height)) ",
        forKey: "NSWindow Frame GoblinPortalSpace:\(poisonRoot.path)")
    let pz = SpaceWindowController(config: compactConfig(), root: poisonRoot)
    let pf = pz.window?.frame.size ?? .zero
    if pf == ws.frame.size { ok("C8", "poisoned 500x532 repaired to \(pf)") }
    else { fail("C8", "poisoned frame not repaired under compact (\(pf))") }

    // ---- C10: live reload standard → compact → standard ---------------------------------------
    print("\n  C10 — live reload standard → compact → standard")
    let r = makeWindow(freshRoot(root, "c10"), fsc: false)
    guard let wr = r.window else { env("no window") }
    let f0 = wr.frame, q0 = probe(r)
    let key = "NSWindow Frame GoblinPortalSpace:\(freshRoot(root, "c10").path)"
    let saved0 = UserDefaults.standard.string(forKey: key)
    r.space.apply(config: compactConfig()); r.applyTitlebarStyle(); pump(0.5)
    let q1 = probe(r), f1r = wr.frame
    r.space.apply(config: .defaults()); r.applyTitlebarStyle(); pump(0.5)
    let q2 = probe(r)
    print("  rows \(q0.rows) → \(q1.rows) → \(q2.rows); frame \(f0) → \(f1r) → \(wr.frame)")
    if f1r == f0 && wr.frame == f0 { ok("C10", "frame unchanged across both toggles") }
    else { fail("C10", "frame moved: \(f0) → \(f1r) → \(wr.frame)") }
    if UserDefaults.standard.string(forKey: key) == saved0 { ok("C10", "saved frame unchanged") }
    else { fail("C10", "saved frame changed by the toggle") }
    if q1.rows > q0.rows && q2.rows == q0.rows && !wr.styleMask.contains(.fullSizeContentView) {
        ok("C10", "rows gained under compact and returned under standard")
    } else { fail("C10", "rows \(q0.rows) → \(q1.rows) → \(q2.rows) (expected gain then return)") }
    wr.orderOut(nil)
}
