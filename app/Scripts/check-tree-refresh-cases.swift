// check-tree-refresh-cases.swift
// Cases 6-8 of check-tree-refresh: the staleness and deferral contract of the async
// loaders in FileTreeViewController+Loading.swift (#158). Compiled alongside
// check-tree-refresh-harness.swift (which owns the app, `pump`, `check`, `pass`,
// `fail`), and its own file because the harness plus these would cross the 350-line
// ceiling.
//
// Every case stalls a listing with a semaphore-gated stub, does something on the main
// thread while it is in flight, then releases it and checks the late landing did what
// the contract says (`land(_:)`, +Loading.swift): dropped if stale, deferred if an
// inline edit is open.
//
//  6. STALE-DROP            — setRoot(A), setRoot(B), A's listing released last:
//                             root is B and none of A's children ever appear.
//  7. EDIT-DEFER            — a refresh landing during an inline edit does not reload
//                             the outline; it is replayed when the edit ends.
//  8. MUTATION-INVALIDATES  — an async refresh in flight, then a file operation's
//                             synchronous refresh: the late async result is dropped.

import AppKit
@testable import GoblinPortal

/// A lister that waits for `sem` and then answers from `frozen` (a listing taken on
/// main BEFORE anything changed), falling back to a live read. `wait(); signal()`
/// lets every call through once released, so a multi-directory listing cannot wedge.
@MainActor
func stalledLister(_ sem: DispatchSemaphore, frozen: [URL: [DirectoryEntry]] = [:])
    -> @Sendable (URL) -> [DirectoryEntry]
{
    let live = DirectoryListing.lister
    return { url in
        sem.wait(); sem.signal()
        return frozen[url] ?? live(url)
    }
}

@MainActor
func childNames(_ node: FileNode) -> [String] { (node.children ?? []).map(\.name) }

@MainActor
func runStalenessCases(vc: FileTreeViewController, treeURL: URL) {
    let ov = vc.outlineView
    let live = DirectoryListing.lister

    // -----------------------------------------------------------------------
    // CASE 6: STALE-DROP
    let dirA = treeURL.appendingPathComponent("a")
    let dirB = treeURL.appendingPathComponent("b")
    let semA = DispatchSemaphore(value: 0)
    DirectoryListing.lister = stalledLister(semA)
    vc.setRoot(dirA)                       // A's listing is now stalled off-main
    DirectoryListing.lister = live
    vc.setRoot(dirB); pump(0.2)            // B lists and lands first
    semA.signal(); pump(0.3)               // A lands last — must be dropped
    let rowURLs = (0..<ov.numberOfRows).compactMap { (ov.item(atRow: $0) as? FileNode)?.url }
    let leaked = rowURLs.filter { $0.path.hasPrefix(dirA.path + "/") }
    check(vc.root.url.path == dirB.path && childNames(vc.root) == ["y.txt"] && leaked.isEmpty,
          case: "STALE-DROP",
          msg: "root=\(vc.root.url.lastPathComponent) children=\(childNames(vc.root)) leakedRows=\(leaked.count)")
    vc.setRoot(treeURL); pump(0.3)

    // -----------------------------------------------------------------------
    // CASE 7: EDIT-DEFER
    let late = treeURL.appendingPathComponent("late.txt")
    let semE = DispatchSemaphore(value: 0)
    DirectoryListing.lister = stalledLister(semE)     // reads disk live AFTER release
    vc.refresh()
    DirectoryListing.lister = live
    guard let bNode = vc.root.children?.first(where: { $0.name == "b" }) else {
        fail("EDIT-DEFER", "setup: b/ not in tree"); return
    }
    vc.beginInlineEdit(for: bNode, isNew: false); pump(0.1)
    FileManager.default.createFile(atPath: late.path, contents: Data("x".utf8))
    semE.signal(); pump(0.3)               // fresh result lands while the editor is open
    let appliedDuringEdit = childNames(vc.root).contains("late.txt")
    let stillEditing = vc.isEditingInline
    let deferred = vc.pendingReload
    vc.cancelInlineEdit(); pump(0.3)       // finishEditReplay must re-read
    let replayed = childNames(vc.root).contains("late.txt")
    check(stillEditing && deferred && !appliedDuringEdit && replayed,
          case: "EDIT-DEFER",
          msg: "editing=\(stillEditing) pendingReload=\(deferred) appliedDuringEdit=\(appliedDuringEdit) replayedAfter=\(replayed)")

    // -----------------------------------------------------------------------
    // CASE 8: MUTATION-INVALIDATES
    let mut = treeURL.appendingPathComponent("mut.txt")
    var frozen: [URL: [DirectoryEntry]] = [:]
    for dir in vc.root.loadedDirectories() { frozen[dir] = live(dir) }   // pre-mutation disk
    let semM = DispatchSemaphore(value: 0)
    DirectoryListing.lister = stalledLister(semM, frozen: frozen)
    vc.refresh()                            // async refresh in flight, frozen pre-mutation
    DirectoryListing.lister = live
    FileManager.default.createFile(atPath: mut.path, contents: Data("m".utf8))
    vc.refreshAfterMutation(select: mut)    // a file op's synchronous refresh
    let afterSync = childNames(vc.root).contains("mut.txt")
    semM.signal(); pump(0.3)                // the stale async result arrives late
    let afterLate = childNames(vc.root).contains("mut.txt")
    check(afterSync && afterLate,
          case: "MUTATION-INVALIDATES",
          msg: "mut.txt after sync refresh=\(afterSync), after late async landing=\(afterLate)")
}
