//
//  check-session-marker-harness.swift
//  Assertions for check-session-marker.sh: does a Source Control row whose path is in
//  the session actually DRAW the accent marker (#298, T5.5)?
//
//  A real file rather than a heredoc, the same split check-sidebar-activity.sh makes:
//  the shell half (build, link, APFS-clone mutants, exit codes) and this half (cases)
//  together would cross the 350-line ceiling. Linked against Goblin Portal's own
//  object files (or a mutated clone's), so every call below is the shipped code.
//
//  WHY PIXELS. `SourceControlRowView.isSessionTouched` being true says nothing about
//  the screen: the marker is drawn in `drawBackground(in:)` of a row on a source-list
//  outline, which AppKit could skip or paint over. Each row view is rendered to a
//  bitmap with `cacheDisplay(in:to:)`, which runs the row's own draw methods into its
//  backing store, and the left 8 points (indentation, no cell content) are averaged.
//  Measured 2026-11-16 on a 2x display: a session row averages alpha ~0.08 there
//  (the 8% fill) and a non-session row 0.0.
//
//  Every session change goes through the REAL fanout,
//  `SpaceViewController.updateSourceControl(snapshot:repository:)`, so case M4 catches
//  the fanout no longer handing the panel its set. The Space's own poller is detached
//  (`fileTree.gitFollow = nil`) so it cannot race the harness's snapshots.
//
//  Every label prints as `FAIL  <label>:` on failure so the script can attribute a
//  mutant to its declared case. Exit 0 = pass, 1 = a case failed, 2 = environmental.
//

import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var failed = 0  // main-actor isolated: top-level code in main.swift
@MainActor func expect(_ label: String, _ ok: Bool, _ detail: String) {
    if ok { print("  ok  \(label)  (\(detail))") } else { print("  FAIL  \(label): \(detail)"); failed += 1 }
}
@MainActor func envFail(_ why: String) -> Never { print("ENV: \(why)"); exit(2) }

@MainActor func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}

/// Average alpha and un-premultiplied colour of the row's left 8-point strip, as drawn.
@MainActor func strip(_ row: NSView) -> (alpha: Double, colour: NSColor?) {
    guard let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { return (0, nil) }
    row.cacheDisplay(in: row.bounds, to: rep)
    let scale = Double(rep.pixelsWide) / max(1, Double(row.bounds.width))
    var a = 0.0, r = 0.0, g = 0.0, b = 0.0, n = 0.0
    for x in 1..<Int(8 * scale) {
        for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            a += Double(c.alphaComponent); n += 1
            // colorAt returns un-premultiplied components; weight them by alpha.
            r += Double(c.redComponent * c.alphaComponent)
            g += Double(c.greenComponent * c.alphaComponent)
            b += Double(c.blueComponent * c.alphaComponent)
        }
    }
    guard n > 0, a > 0 else { return (0, nil) }
    return (a / n, NSColor(srgbRed: r / a, green: g / a, blue: b / a, alpha: 1))
}

func shell(_ line: String, in dir: URL) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", line]
    p.currentDirectoryURL = dir
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    guard args.count == 3 else { envFail("usage: harness <space-root> <repo-root>") }
    let spaceRoot = URL(fileURLWithPath: args[1], isDirectory: true)
    let repoRoot = URL(fileURLWithPath: args[2], isDirectory: true)

    // A real repository for the GitRepository value the fanout keys the session on.
    guard shell("git init -q -b main . && printf 'a\\n' > a.txt && printf 'b\\n' > b.txt && "
                + "git add -A && git commit -q -m init", in: repoRoot),
          let repo = GitStatusReader.discoverRepository(at: repoRoot)
    else { envFail("fixture repository would not build") }

    let wc = SpaceWindowController(config: .defaults(), root: spaceRoot)
    guard let window = wc.window else { envFail("SpaceWindowController produced no window") }
    let space = wc.space
    space.fileTree.gitFollow = nil
    space.fileTree.installSourceControlPanel(from: space)
    space.switchSidebarActivity(.scm)
    window.setFrame(NSRect(x: -20000, y: -20000, width: 1100, height: 680), display: false)
    window.orderFront(nil)
    pump(0.5)

    func entry(_ p: String) -> GitFileEntry {
        GitFileEntry(path: p, status: .modified, isStaged: false, hasWorkingTreeChange: true, originalPath: nil)
    }
    func snap(_ paths: [String]) -> GitStatusSnapshot {
        GitStatusSnapshot(branch: "main", isDetached: false, ahead: nil, behind: nil, hasUpstream: false,
                          entries: Dictionary(uniqueKeysWithValues: paths.map { ($0, entry($0)) }),
                          directories: [:])
    }
    let panel = space.sourceControlPanel
    let ov = panel.outlineView
    @MainActor func rowView(_ path: String) -> SourceControlRowView? {
        for r in 0..<ov.numberOfRows where (ov.item(atRow: r) as? GitFileEntry)?.path == path {
            return ov.rowView(atRow: r, makeIfNecessary: true) as? SourceControlRowView
        }
        return nil
    }
    @MainActor func marked(_ path: String) -> (Bool, String) {
        guard let row = rowView(path) else { return (false, "no row for \(path)") }
        let s = strip(row)
        return (s.alpha > 0.04, String(format: "%@ alpha %.3f", path, s.alpha))
    }

    // Tick 1 is the baseline (b.txt already dirty); tick 2 adds a.txt, so the session is
    // {a.txt}.
    space.updateSourceControl(snapshot: snap(["b.txt"]), repository: repo)
    pump(0.3)
    space.updateSourceControl(snapshot: snap(["a.txt", "b.txt"]), repository: repo)
    for t in panel.sections { ov.expandItem(t) }
    print("fanout")
    expect("M4 fanout hands the panel the session", panel.sessionTouchedPaths == ["a.txt"],
           "panel set \(panel.sessionTouchedPaths.sorted())")

    pump(0.4)
    print("pixels")
    let (aMarked, aDetail) = marked("a.txt")
    let (bMarked, bDetail) = marked("b.txt")
    expect("M1 session row draws the marker", aMarked, aDetail)
    expect("M1b non-session row draws none", !bMarked, bDetail)
    if let row = rowView("a.txt"), let c = strip(row).colour,
       let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
        // Hue, not RGB distance: at 8% alpha the 8-bit backing store quantises each
        // premultiplied channel to ~20 levels, so the un-premultiplied colour lands
        // ~0.3 off in RGB while keeping the accent's hue (measured: drawn 0.25/0.59/1.00
        // against accent 0.00/0.48/1.00, hue 213° vs 211°). A grey accent has no hue.
        let dh = min(abs(c.hueComponent - accent.hueComponent), 1 - abs(c.hueComponent - accent.hueComponent)) * 360
        let detail = String(format: "hue %.0f° vs accent %.0f°", c.hueComponent * 360, accent.hueComponent * 360)
        if accent.saturationComponent < 0.3 {
            print("  skip  M1c marker is the accent colour (accent is unsaturated: \(detail))")
        } else {
            expect("M1c marker is the accent colour", dh < 20, detail)
        }
    } else {
        expect("M1c marker is the accent colour", false, "no colour sampled")
    }

    // The selection pill owns the selected row; the marker yields, as in the file tree.
    if let r = (0..<ov.numberOfRows).first(where: { (ov.item(atRow: $0) as? GitFileEntry)?.path == "a.txt" }) {
        ov.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        pump(0.3)
        let (selMarked, selDetail) = marked("a.txt")
        expect("M2 selected session row yields", !selMarked, selDetail)
        ov.deselectAll(nil)
        pump(0.3)
    }

    // Clear: `resetSessionHighlights` resets the store AND calls
    // `fileTree.gitStatusDidChange()` synchronously, which re-enters the fanout
    // (`notifySourceControlOfChange` → `updateSourceControl` → `updateSessionHighlight`)
    // with the poller's cached snapshot so those paths become the new baseline in the
    // SAME TURN. The immediately-following `updateSourceControl` with the same snapshot
    // must therefore produce an empty session set — not re-mark a.txt.
    // Rows are recycled by the reload, so a row that held the marker must lose it.
    // `resetSessionHighlights` calls `fileTree.gitStatusDidChange()` synchronously, which
    // re-enters the fanout and triggers `panel.reloadData` — the only repaint between Clear
    // and this pixel check. Without that call the existing row views keep their old
    // `isSessionTouched = true` state and the marker pixel survives. The two lines that
    // set `sessionTouchedPaths = []` before `gitStatusDidChange()` are necessary but not
    // sufficient: they clear the flag for future configures but do not repaint live rows.
    space.resetSessionHighlights(nil)
    for t in panel.sections { ov.expandItem(t) }
    pump(0.4)
    print("after clear")
    let (aCleared, clearDetail) = marked("a.txt")
    expect("M3 cleared row loses the marker", !aCleared, clearDetail)

    // Recycling, driven directly: AppKit's reuse pool is not deterministic across a
    // reload (measured: the reloaded a.txt row was a different view), so one row view
    // is configured for a session file and then RE-configured for a non-session file,
    // which is what a recycle does. The second configure must take the marker away.
    let lone = SourceControlRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
    panel.sessionTouchedPaths = ["a.txt"]
    lone.configure(entry: entry("a.txt"), controller: panel)
    let first = strip(lone).alpha
    lone.configure(entry: entry("b.txt"), controller: panel)
    let second = strip(lone).alpha
    expect("M3b recycled row loses the marker", first > 0.04 && second < 0.04 && !lone.isSessionTouched,
           String(format: "a.txt alpha %.3f, then b.txt alpha %.3f, flag %@", first, second,
                  lone.isSessionTouched ? "true" : "false"))

    print("\n\(failed) failed")
    exit(failed > 0 ? 1 : 0)
}
