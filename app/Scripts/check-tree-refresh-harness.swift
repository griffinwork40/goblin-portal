// check-tree-refresh-harness.swift
// Offscreen gate: main-thread-blocking detector for setRoot/refresh (#158).
//
// WHY THIS GATE EXISTS
//   After the DirectoryListing seam (step 1), the test harness can inject a lister
//   that blocks on a semaphore.  If reloadChildren() is synchronous (today's code),
//   calling setRoot/refresh blocks the main thread and the run-loop heartbeat timer
//   cannot fire.  This gate detects that: it measures whether a 10ms repeating timer
//   advances during a 300ms listing window.  If the heartbeat did NOT advance, the
//   case reports FAIL (exit 1).
//
// EXIT CODES
//   0  all cases pass (BLOCKING cases must be made non-blocking before this is green)
//   1  one or more assertion failures
//   2  environmental failure (tree not found, window not created)
//
// CASES
//   1. IDENTITY   — unchanged children reuse the same FileNode object after refresh
//   2. EXPANSION  — expanded dirs survive a refresh (NSOutlineView keeps state)
//   3. SAME-PATH  — setRoot with the same path does no listing at all
//   4. BLOCKING-SETROOT  — main-thread heartbeat must keep firing while lister blocks
//   5. BLOCKING-REFRESH  — same for refresh()
//   6-8. STALE-DROP, EDIT-DEFER, MUTATION-INVALIDATES — check-tree-refresh-cases.swift
//   9-15. NO-EMPTY-FRAME, REVEAL-IN-FLIGHT, SYNC-ADOPT, NO-MAIN-LISTING,
//         SELECTION-SURVIVES, SUBFOLDER-REFRESH, EXPAND-IN-FLIGHT —
//         check-tree-refresh-invariants.swift
//
// DESIGN: AVOIDING A HANG
//   The blocking lister releases its semaphore after 300ms from a background thread,
//   so the harness always terminates.  The heartbeat timer counts ticks in a shared
//   Int (no synchronisation needed: all increments happen on main).  After the
//   release, the harness measures how many ticks fired; 0 ticks means main was
//   blocked for the full window.
//
// FILE-SIZE CEILING: 350 lines.

import AppKit
@testable import GoblinPortal

// ---------------------------------------------------------------------------
// MARK: - App / pump

@MainActor
let app: NSApplication = {
    let a = NSApplication.shared; a.setActivationPolicy(.accessory); return a
}()

@MainActor
func pump(_ s: Double = 0.15) {
    let d = Date().addingTimeInterval(s)
    while Date() < d { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

// ---------------------------------------------------------------------------
// MARK: - Reporting

var gBad = 0

@MainActor
func pass(_ name: String) { print("  PASS \(name)") }

@MainActor
func fail(_ name: String, _ msg: String) { print("  FAIL \(name): \(msg)"); gBad += 1 }

@MainActor
func check(_ cond: Bool, case name: String, msg: String) {
    if cond { pass(name) } else { fail(name, msg) }
}

// ---------------------------------------------------------------------------
// MARK: - Helpers

@MainActor
func countExpanded(in ov: NSOutlineView) -> Int {
    (0..<ov.numberOfRows).filter { row in
        if let item = ov.item(atRow: row) { return ov.isItemExpanded(item) }
        return false
    }.count
}

@MainActor
func expandItem(_ node: FileNode, ov: NSOutlineView) { ov.expandItem(node); pump(0.05) }

// ---------------------------------------------------------------------------
// MARK: - Heartbeat test
//
// Installs a repeating timer that increments a counter on the main run loop.
// Returns (tick count during window, total window ms).
// The lister is assumed already stubbed before this is called.
// A background thread releases `sem` after `releaseAfter` seconds.

@MainActor
func measureHeartbeat(
    releaseAfter: Double,
    timerInterval: Double = 0.01,
    action: @escaping @MainActor () -> Void
) -> Int {
    // Ticks are counted only INSIDE the blocked window [t0, t0+releaseAfter): a
    // synchronous listing holds main for the whole window, so its first tick lands
    // after the release and counts 0. An async one returns at once; the harness then
    // pumps through the window, and the ticks that fire there are the proof.
    var ticks = 0
    let t0 = Date()
    let windowEnd = t0.addingTimeInterval(releaseAfter - 0.02)
    let timer = Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { _ in
        MainActor.assumeIsolated { if Date() < windowEnd { ticks += 1 } }
    }
    RunLoop.main.add(timer, forMode: .common)

    // Released from a background thread so the harness always terminates.
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + releaseAfter) { sem.signal() }

    // Every listing call blocks until the release; `wait(); signal()` chains it so a
    // multi-directory refresh does not wedge its second call forever.
    let original = DirectoryListing.lister
    DirectoryListing.lister = { url in
        sem.wait(); sem.signal()
        return original(url)
    }

    action()   // blocks main for the whole window if listing is synchronous

    DirectoryListing.lister = original   // in-flight listings keep the stub they captured
    let remaining = t0.addingTimeInterval(releaseAfter + 0.05).timeIntervalSinceNow
    if remaining > 0 { pump(remaining) }
    timer.invalidate()
    pump(0.1)   // let the released listing land
    return ticks
}

// ---------------------------------------------------------------------------
// MARK: - Entry point

@MainActor
func runGate(treePath: String) -> Int32 {
    let treeURL = URL(fileURLWithPath: treePath, isDirectory: true).resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: treeURL.path) else {
        fputs("error: tree not found: \(treePath)\n", stderr); return 2
    }

    let wc = SpaceWindowController(config: .defaults(), root: treeURL)
    guard let window = wc.window else {
        fputs("error: SpaceWindowController produced no window\n", stderr); return 2
    }
    let vc  = wc.space.fileTree
    let ov  = vc.outlineView
    window.setFrame(NSRect(x: -20000, y: -20000, width: 900, height: 600), display: false)
    window.orderFront(nil)
    pump(0.5)
    vc.refresh(); pump(0.3)

    // Expand 'a' directory if present.
    if let aNode = vc.root.children?.first(where: { $0.isDirectory }) {
        expandItem(aNode, ov: ov)
    }

    // -----------------------------------------------------------------------
    // CASE 1: IDENTITY — FileNode objects reused across refresh
    let beforeNodes = Set(vc.root.children?.map { ObjectIdentifier($0) } ?? [])
    vc.refresh(); pump(0.2)
    let afterNodes  = Set(vc.root.children?.map { ObjectIdentifier($0) } ?? [])
    check(!beforeNodes.isEmpty && beforeNodes == afterNodes,
          case: "IDENTITY", msg: "child node identities changed after refresh")

    // -----------------------------------------------------------------------
    // CASE 2: EXPANSION — expanded rows survive refresh
    let expandedBefore = countExpanded(in: ov)
    vc.refresh(); pump(0.2)
    let expandedAfter  = countExpanded(in: ov)
    check(expandedBefore > 0 && expandedAfter == expandedBefore,
          case: "EXPANSION", msg: "expanded=\(expandedBefore) before, \(expandedAfter) after")

    // -----------------------------------------------------------------------
    // CASE 3: SAME-PATH — setRoot with same path does no listing
    var listCount = 0
    let origLister = DirectoryListing.lister
    DirectoryListing.lister = { url in listCount += 1; return origLister(url) }
    vc.setRoot(treeURL)   // same path — guard in setRoot should skip
    pump(0.1)
    DirectoryListing.lister = origLister
    check(listCount == 0,
          case: "SAME-PATH", msg: "lister called \(listCount) time(s) for same path")

    // -----------------------------------------------------------------------
    // CASE 4: BLOCKING-SETROOT — heartbeat must advance while lister blocks
    // Synchronous listing: ticks == 0 → FAIL. Async (#158): ticks > 5 → PASS.
    let altURL = vc.root.children?.first(where: { $0.isDirectory })?.url
        ?? treeURL.appendingPathComponent("__nonexistent__")
    let ticksSetRoot = measureHeartbeat(releaseAfter: 0.30) {
        vc.setRoot(altURL)
    }
    pump(0.1)
    // Restore root for next case.
    DirectoryListing.lister = { url in origLister(url) }  // ensure clean
    DirectoryListing.lister = origLister
    vc.setRoot(treeURL); pump(0.2)

    let setRootPassed = ticksSetRoot > 5   // >5 ticks in 300ms @ 10ms interval
    if setRootPassed { pass("BLOCKING-SETROOT (ticks=\(ticksSetRoot))") }
    else { fail("BLOCKING-SETROOT", "main blocked during listing: ticks=\(ticksSetRoot)/~30 expected") }

    // -----------------------------------------------------------------------
    // CASE 5: BLOCKING-REFRESH — heartbeat must advance while lister blocks
    let ticksRefresh = measureHeartbeat(releaseAfter: 0.30) {
        vc.refresh()
    }
    pump(0.1)
    DirectoryListing.lister = origLister

    let refreshPassed = ticksRefresh > 5
    if refreshPassed { pass("BLOCKING-REFRESH (ticks=\(ticksRefresh))") }
    else { fail("BLOCKING-REFRESH", "main blocked during listing: ticks=\(ticksRefresh)/~30 expected") }

    // CASES 6-8: staleness and deferral (check-tree-refresh-cases.swift).
    runStalenessCases(vc: vc, treeURL: treeURL)

    // CASES 9-15: what the outline shows mid-flight, and what survives a landing
    // (check-tree-refresh-invariants.swift).
    runInvariantCases(vc: vc, treeURL: treeURL)

    // -----------------------------------------------------------------------
    print()
    if gBad == 0 { print("all tree-refresh gate cases passed (15 cases)") }
    else { print("\(gBad) tree-refresh gate case(s) FAILED") }
    return gBad == 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// MARK: - main

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: check-tree-refresh <tree-path>\n", stderr); exit(2)
}

_ = app
// A run-loop block, NOT `DispatchQueue.main.async`: the async loaders land through
// `Task { @MainActor }`, i.e. the main dispatch queue, and a nested `RunLoop.run`
// (`pump`) inside a main-QUEUE block can never drain that queue — every landing
// would wait until the gate exited. A run-loop block leaves the queue drainable.
RunLoop.main.perform {
    MainActor.assumeIsolated { exit(runGate(treePath: CommandLine.arguments[1])) }
}
RunLoop.main.run()
