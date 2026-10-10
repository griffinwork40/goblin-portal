// check-tree-refresh-invariants.swift
// Cases 9-15 of check-tree-refresh: what the user SEES while a listing is in flight,
// and what state survives its landing (#158 review). Compiled alongside
// check-tree-refresh-harness.swift (`pump`, `check`, `fail`) and
// check-tree-refresh-cases.swift (`stalledLister`, `childNames`); its own file because
// the 350-line ceiling would not hold all three.
//
//  9. NO-EMPTY-FRAME     (I1) — between setRoot(B) and B's landing the outline keeps
//                               showing A's rows (A retained), never zero rows; B
//                               replaces them when it lands.
// 10. REVEAL-IN-FLIGHT   (I2) — reveal(x), reveal(y) while B is in flight: y is selected
//                               after B lands (last request wins), and B's own root
//                               listing never ran on main.
// 11. SYNC-ADOPT         (I3) — refreshSynchronously() while B is in flight shows B
//                               immediately and is still on B after the late landing.
// 12. NO-MAIN-LISTING    (I4) — after the stall is released, no lister call comes from
//                               the main thread during a refresh or setRoot landing.
// 13. SELECTION-SURVIVES (I5) — the selected row is reselected by URL after an async
//                               refresh landing, even when rows above it moved.
// 14. SUBFOLDER-REFRESH  (I5) — a file created inside an EXPANDED subfolder appears
//                               after refresh().
// 15. EXPAND-IN-FLIGHT   (I5) — a folder expanded while a refresh is in flight keeps its
//                               children after the landing.

import AppKit
@testable import GoblinPortal

@MainActor
func rowURLs(_ ov: NSOutlineView) -> [URL] {
    (0..<ov.numberOfRows).compactMap { (ov.item(atRow: $0) as? FileNode)?.url }
}

@MainActor
func selectedURL(_ ov: NSOutlineView) -> URL? { (ov.item(atRow: ov.selectedRow) as? FileNode)?.url }

/// Re-root at `url` with a FRESH FileNode: `setRoot` early-returns on an unchanged
/// path, so going through `other` first is the only way to drop loaded state.
@MainActor
func freshRoot(_ vc: FileTreeViewController, _ url: URL, via other: URL) {
    vc.setRoot(other); pump(0.25); vc.setRoot(url); pump(0.3)
}

/// Which directories were listed ON THE MAIN THREAD, and of those, which after the
/// stall was released. Locked because the lister runs on background queues too.
final class ListerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var mainCalls: [(URL, Bool)] = []
    func release() { lock.lock(); released = true; lock.unlock() }
    func record(_ url: URL) {
        guard Thread.isMainThread else { return }
        lock.lock(); mainCalls.append((url, released)); lock.unlock()
    }
    func mainPaths(afterReleaseOnly: Bool) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return mainCalls.filter { !afterReleaseOnly || $0.1 }.map(\.0.path)
    }
}

/// A stalled lister (see `stalledLister`) that also logs main-thread calls.
@MainActor
func recordingLister(_ sem: DispatchSemaphore, _ log: ListerLog) -> @Sendable (URL) -> [DirectoryEntry] {
    let live = DirectoryListing.lister
    return { url in
        log.record(url)
        if !Thread.isMainThread { _ = sem.wait(timeout: .now() + 2); sem.signal() }
        return live(url)
    }
}

@MainActor
func runInvariantCases(vc: FileTreeViewController, treeURL: URL) {
    let ov = vc.outlineView
    let live = DirectoryListing.lister
    let dirA = treeURL.appendingPathComponent("b")   // the tree on screen: [y.txt]
    let dirB = treeURL.appendingPathComponent("a")   // the tree arriving: [inner, x.txt]

    // -----------------------------------------------------------------------
    // CASE 9: NO-EMPTY-FRAME (I1)
    freshRoot(vc, dirA, via: treeURL)
    weak var shownA = vc.root
    let rowsBefore = rowURLs(ov)
    var samples: [Int] = []
    let sem9 = DispatchSemaphore(value: 0)
    DirectoryListing.lister = stalledLister(sem9)
    vc.setRoot(dirB)
    DirectoryListing.lister = live
    samples.append(ov.numberOfRows)                  // the frame right after setRoot
    let rowsDuring = rowURLs(ov)
    let sampler = Timer(timeInterval: 0.01, repeats: true) { _ in
        MainActor.assumeIsolated { samples.append(ov.numberOfRows) }
    }
    RunLoop.main.add(sampler, forMode: .common)
    pump(0.15)
    let aRetained = shownA != nil
    sem9.signal(); pump(0.3)
    sampler.invalidate()
    let namesAfter = rowURLs(ov).map(\.lastPathComponent)
    let duringIsA = !rowsDuring.isEmpty && rowsDuring.allSatisfy { $0.path.hasPrefix(dirA.path + "/") }
    check(!rowsBefore.isEmpty && samples.allSatisfy { $0 > 0 } && duringIsA && aRetained
          && namesAfter.contains("x.txt") && !namesAfter.contains("y.txt"),
          case: "NO-EMPTY-FRAME",
          msg: "minRows=\(samples.min() ?? -1) duringIsA=\(duringIsA) aRetained=\(aRetained) after=\(namesAfter)")

    // -----------------------------------------------------------------------
    // CASE 10: REVEAL-IN-FLIGHT (I2). The real trigger is a file-viewer tab selected
    // just after the shell cd'd (selectDocument → directoryFollowPollNow → setRoot, then
    // revealActiveFileInTree, same turn); that needs a live shell, so this drives the
    // same two calls in the same order directly.
    let deep = dirB.appendingPathComponent("inner/z.txt")
    FileManager.default.createFile(atPath: deep.path, contents: Data("z".utf8))
    freshRoot(vc, dirA, via: treeURL)
    let log10 = ListerLog()
    let sem10 = DispatchSemaphore(value: 0)
    DirectoryListing.lister = recordingLister(sem10, log10)
    vc.setRoot(dirB)
    vc.reveal(dirB.appendingPathComponent("x.txt"))  // superseded…
    vc.reveal(deep)                                    // …by this one
    sem10.signal(); pump(0.3)
    DirectoryListing.lister = live
    let revealed = selectedURL(ov)
    let rootOnMain = log10.mainPaths(afterReleaseOnly: false).contains(dirB.path)
    check(revealed?.path == deep.path && !rootOnMain,
          case: "REVEAL-IN-FLIGHT",
          msg: "selected=\(revealed?.path ?? "nil") rootListedOnMain=\(rootOnMain)")

    // -----------------------------------------------------------------------
    // CASE 11: SYNC-ADOPT (I3)
    freshRoot(vc, dirA, via: treeURL)
    let sem11 = DispatchSemaphore(value: 0)
    DirectoryListing.lister = stalledLister(sem11)
    vc.setRoot(dirB)
    DirectoryListing.lister = live
    vc.refreshSynchronously()                        // e.g. a file operation, same turn
    let syncNames = rowURLs(ov).map(\.lastPathComponent)
    sem11.signal(); pump(0.3)
    let lateNames = rowURLs(ov).map(\.lastPathComponent)
    check(syncNames.contains("x.txt") && lateNames.contains("x.txt") && vc.root.url.path == dirB.path,
          case: "SYNC-ADOPT", msg: "afterSync=\(syncNames) afterLate=\(lateNames)")

    // -----------------------------------------------------------------------
    // CASE 12: NO-MAIN-LISTING (I4) — a refresh landing with expanded folders, then a
    // setRoot landing, both under a lister that logs which thread called it.
    freshRoot(vc, treeURL, via: dirA)
    if let a = vc.root.children?.first(where: { $0.name == "a" }) { expandItem(a, ov: ov) }
    let log12 = ListerLog()
    let sem12 = DispatchSemaphore(value: 0)
    DirectoryListing.lister = recordingLister(sem12, log12)
    vc.refresh()
    log12.release(); sem12.signal(); pump(0.3)
    vc.setRoot(dirB); pump(0.3)
    DirectoryListing.lister = live
    let mainAfter = log12.mainPaths(afterReleaseOnly: true)
    check(mainAfter.isEmpty, case: "NO-MAIN-LISTING",
          msg: "listed on main during landing: \(mainAfter.map { URL(fileURLWithPath: $0).lastPathComponent })")

    // -----------------------------------------------------------------------
    // CASES 13 + 14: one refresh. x.txt is selected inside the expanded a/; a new file
    // that sorts ABOVE it appears in a/, so a selection kept by row index would move.
    freshRoot(vc, treeURL, via: dirA)
    guard let aNode = vc.root.children?.first(where: { $0.name == "a" }) else {
        fail("SELECTION-SURVIVES", "setup: a/ not in tree"); return
    }
    expandItem(aNode, ov: ov)
    let xURL = dirB.appendingPathComponent("x.txt")
    let xRow = ov.row(forItem: aNode.children?.first { $0.name == "x.txt" })
    ov.selectRowIndexes([xRow], byExtendingSelection: false)
    let sel0 = dirB.appendingPathComponent("sel-0.txt")
    FileManager.default.createFile(atPath: sel0.path, contents: Data("s".utf8))
    vc.refresh(); pump(0.3)
    check(xRow >= 0 && selectedURL(ov)?.path == xURL.path, case: "SELECTION-SURVIVES",
          msg: "selected before=row \(xRow), after=\(selectedURL(ov)?.lastPathComponent ?? "nil")")
    let subRows = rowURLs(ov).map(\.path)
    check(childNames(aNode).contains("sel-0.txt") && subRows.contains(sel0.path),
          case: "SUBFOLDER-REFRESH", msg: "a/ children after refresh=\(childNames(aNode))")

    // -----------------------------------------------------------------------
    // CASE 15: EXPAND-IN-FLIGHT (I5). Fresh root: b/ is unloaded, so the refresh lists
    // only the root and b/ is loaded on main by the disclosure while it is in flight.
    freshRoot(vc, treeURL, via: dirA)
    let sem15 = DispatchSemaphore(value: 0)
    DirectoryListing.lister = stalledLister(sem15)
    vc.refresh()
    DirectoryListing.lister = live
    guard let bNode = vc.root.children?.first(where: { $0.name == "b" }) else {
        fail("EXPAND-IN-FLIGHT", "setup: b/ not in tree"); return
    }
    expandItem(bNode, ov: ov)
    sem15.signal(); pump(0.3)
    let yShown = rowURLs(ov).contains { $0.lastPathComponent == "y.txt" }
    check(childNames(bNode) == ["y.txt"] && ov.isItemExpanded(bNode) && yShown,
          case: "EXPAND-IN-FLIGHT",
          msg: "b/ children=\(childNames(bNode)) expanded=\(ov.isItemExpanded(bNode)) yRow=\(yShown)")
}
