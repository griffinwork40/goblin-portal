// check-tree-refresh-baseline-harness.swift
// Offscreen timing harness for FileTreeViewController setRoot/refresh baseline.
//
// WHAT IT MEASURES (issue #158):
//   setRoot(url)  — replaces the tree root and does one reloadChildren() pass
//   refresh()     — reloads already-expanded children in place
//
// Both are called 10 times each; this binary is invoked twice by the shell script —
// once for the synthetic tree, once for node_modules.  Each call emits DIAG lines
// to stderr under GOBLIN_PORTAL_DIAG=1 (TreeRefreshTiming.swift format):
//   [diag] tree-refresh: site=setRoot dirs=0 elapsed=Xms
//   [diag] tree-refresh: site=refresh dirs=N elapsed=Xms
// The shell wrapper parses those lines, computes median/p95/max, and writes the
// markdown report.
//
// EXIT CODES:
//   0  measurements complete
//   2  environmental failure (tree path invalid, window not created)
//
// FILE-SIZE CEILING: 350 lines (check-file-size.sh).

import AppKit
@testable import GoblinPortal

// ---------------------------------------------------------------------------
// MARK: - Helpers

@MainActor
let app: NSApplication = {
    let a = NSApplication.shared
    a.setActivationPolicy(.accessory)
    return a
}()

/// Spin the run loop for `seconds` so AppKit can process offscreen layout.
@MainActor
func pump(_ seconds: Double = 0.15) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

/// Count expanded rows in the outline view.
@MainActor
func expandedCount(in ov: NSOutlineView) -> Int {
    var n = 0
    for row in 0..<ov.numberOfRows {
        if let item = ov.item(atRow: row), ov.isItemExpanded(item) { n += 1 }
    }
    return n
}

/// Expand directories breadth-first up to `max` total, then pump.
@MainActor
func expandMany(vc: FileTreeViewController, ov: NSOutlineView, max: Int) {
    var opened = 0
    var queue: [FileNode] = (vc.root.children ?? []).filter { $0.isDirectory }
    while !queue.isEmpty && opened < max {
        let node = queue.removeFirst()
        ov.expandItem(node)
        opened += 1
        if opened % 50 == 0 { pump(0.02) }
        if let kids = node.children {
            queue.append(contentsOf: kids.filter { $0.isDirectory }.prefix(8))
        }
    }
    pump(0.1)
}

// ---------------------------------------------------------------------------
// MARK: - Entry point

@MainActor
func runBaseline(treePath: String, treeTag: String, expandTarget: Int) -> Int32 {
    let treeURL = URL(fileURLWithPath: treePath, isDirectory: true)
        .resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: treeURL.path) else {
        fputs("error: tree path does not exist: \(treePath)\n", stderr); return 2
    }

    let wc = SpaceWindowController(config: .defaults(), root: treeURL)
    guard let window = wc.window else {
        fputs("error: SpaceWindowController produced no window\n", stderr); return 2
    }
    let vc = wc.space.fileTree
    let ov = vc.outlineView

    window.setFrame(NSRect(x: -20000, y: -20000, width: 900, height: 600), display: false)
    window.orderFront(nil)
    pump(0.5)
    vc.refresh(); pump(0.3)

    // Expand directories so refresh() has real work.
    expandMany(vc: vc, ov: ov, max: expandTarget)
    let expanded = expandedCount(in: ov)
    fputs("baseline: tree=\(treeTag) expanded=\(expanded)\n", stderr)

    // --- setRoot (10 samples) ---
    // Alternate between the real root and its first directory child to bypass
    // the same-path guard in setRoot (which returns immediately for unchanged paths).
    // On even samples we go to the child; on odd samples back to the root.
    let altURL = vc.root.children?.first(where: { $0.isDirectory })?.url ?? treeURL

    for i in 0..<10 {
        let target = (i % 2 == 0) ? altURL : treeURL
        vc.setRoot(target)
        pump(0.05)
    }
    // Restore root for refresh measurement.
    vc.setRoot(treeURL); pump(0.2)
    expandMany(vc: vc, ov: ov, max: expandTarget)

    // --- refresh (10 samples) ---
    for _ in 0..<10 {
        vc.refresh()
        pump(0.05)
    }

    print("DONE treeTag=\(treeTag) expanded=\(expanded)")
    return 0
}

// ---------------------------------------------------------------------------
// MARK: - main

// argv[1]=tree-path  argv[2]=tree-tag  argv[3]=expand-target
guard CommandLine.arguments.count >= 4 else {
    fputs("usage: baseline <tree-path> <tree-tag> <expand-target>\n", stderr)
    exit(2)
}

_ = app  // trigger NSApplication.shared initialization
let treePath     = CommandLine.arguments[1]
let treeTag      = CommandLine.arguments[2]
let expandTarget = Int(CommandLine.arguments[3]) ?? 300

// Top-level @main-less script: RunLoop.main drives the app.
// Schedule the work as the first event so it runs after NSApplication.shared
// initialises, then exit from within the body.
DispatchQueue.main.async {
    let code = runBaseline(treePath: treePath, treeTag: treeTag,
        expandTarget: expandTarget)
    exit(code)
}
RunLoop.main.run()
