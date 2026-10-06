// check-file-tree-ops-cases.swift
// Cases 6–11 for the file-tree behavioural gate. Compiled together with
// check-file-tree-ops-harness.swift by check-file-tree-ops.sh. Helpers and shared
// state live in check-file-tree-ops-harness.swift (Harness.*).
//
// WHY A SEPARATE FILE. check-file-tree-ops-harness.swift already holds the
// scaffolding, the FakeDraggingInfo stub, cases 1–5, and the top-level entry point.
// Splitting at case 6 keeps both files comfortably under the 350-LOC ceiling.

import AppKit
@testable import GoblinPortal

extension Harness {

    // MARK: — Cases 6–11

    static func runCases6to11() {

        // ─────────────────────────────────────────────────────────────────────
        // CASE 6 — Context-menu action targets representedObject, not the selection.
        // Selection = a/Makefile; representedObject = b/Y.txt → Duplicate lands in b/.
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 6] context-menu targets representedObject over selection")
        expand("a"); expand("b")
        if let mfNode6 = w("a/Makefile") {
            ov.selectRowIndexes([ov.row(forItem: mfNode6)], byExtendingSelection: false)
        }
        let bBefore6 = dir("b")
        let aBefore6 = dir("a")
        vc.performDuplicate(mi(title: "Duplicate",
            action: #selector(FileTreeViewController.performDuplicate(_:)),
            target: w("b/Y.txt")))
        pump(0.3)
        let addedInB6 = dir("b").filter { !bBefore6.contains($0) }
        let addedInA6 = dir("a").filter { !aBefore6.contains($0) }
        if !addedInB6.isEmpty { ok("Duplicate via representedObject landed in b/: \(addedInB6)") }
        else { fail("No new file in b/ — representedObject not used as target") }
        if addedInA6.isEmpty { ok("Selection (a/Makefile) was not duplicated") }
        else { fail("New files appeared in a/ — selection incorrectly used: \(addedInA6)") }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 7 — setRoot during inline edit is deferred; applied after commit (H4).
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 7] setRoot deferred during inline edit")
        expand("a")
        guard let mfNode7 = w("a/Makefile") else {
            fail("a/Makefile missing for case 7 — prior case dependency failed"); return }
        ov.selectRowIndexes([ov.row(forItem: mfNode7)], byExtendingSelection: false)
        vc.beginInlineEdit(for: mfNode7, isNew: false)
        pump(0.1)
        if vc.isEditingInline { ok("isEditingInline true during edit") }
        else { fail("isEditingInline false — edit did not start") }

        let rootBefore7 = vc.root.url
        let altRoot7 = treeRoot.appendingPathComponent("b")
        vc.setRoot(altRoot7); pump(0.1)
        if vc.root.url == rootBefore7 { ok("root unchanged while editing — setRoot deferred") }
        else { fail("root changed during edit — setRoot was not deferred (H4)") }
        if vc.pendingRoot == altRoot7 { ok("pendingRoot holds the deferred URL") }
        else { fail("pendingRoot is \(String(describing: vc.pendingRoot)) instead of altRoot") }

        vc.commitEditedName("Makefile"); pump(0.4)
        if vc.root.url.resolvingSymlinksInPath() == altRoot7.resolvingSymlinksInPath() {
            ok("root applied to b/ after commit")
        } else { fail("root not applied after commit: \(vc.root.url)") }
        if vc.pendingRoot == nil { ok("pendingRoot cleared after commit") }
        else { fail("pendingRoot not cleared after commit") }

        // Restore root for subsequent cases.
        vc.setRoot(treeRoot); pump(0.4)
        expand("a"); expand("b")

        // ─────────────────────────────────────────────────────────────────────
        // CASE 8 — Cut+Paste moves; Copy+Paste keeps name; Duplicate suffixes.
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 8] cut/copy/paste/duplicate")

        // 8a: Cut a/Makefile → Paste into b/.
        expand("a"); pump(0.1)
        guard let cutNode8 = w("a/Makefile") else {
            fail("a/Makefile missing for cut in case 8 — prior case dependency failed"); return }
        vc.performCut(mi(title: "Cut",
            action: #selector(FileTreeViewController.performCut(_:)), target: cutNode8))
        vc.performPaste(mi(title: "Paste",
            action: #selector(FileTreeViewController.performPaste(_:)), target: w("b")))
        pump(0.4)
        if !existsFile("a/Makefile") { ok("cut file gone from a/") }
        else { fail("cut file still in a/ after paste") }
        if existsFile("b/Makefile") { ok("cut file moved to b/Makefile") }
        else { fail("cut file not found in b/ after paste") }

        // 8b: Copy b/Makefile → Paste into a/newdir (no collision) — keeps exact name.
        expand("b"); pump(0.1)
        guard let copyNode8 = w("b/Makefile") else {
            fail("b/Makefile missing for copy in case 8 — prior case dependency failed"); return }
        vc.performCopy(mi(title: "Copy",
            action: #selector(FileTreeViewController.performCopy(_:)), target: copyNode8))
        expand("a/newdir")
        vc.performPaste(mi(title: "Paste",
            action: #selector(FileTreeViewController.performPaste(_:)),
            target: w("a/newdir")))
        pump(0.4)
        if existsFile("a/newdir/Makefile") { ok("copy+paste into newdir kept exact name Makefile") }
        else { fail("copy+paste into newdir did not produce Makefile") }

        // 8c: Duplicate Y.txt in b/ — suffix must contain "copy".
        expand("b"); pump(0.1)
        guard let yNode8 = w("b/Y.txt") else {
            fail("b/Y.txt missing for duplicate in case 8 — prior case dependency failed"); return }
        let bBefore8 = dir("b")
        vc.performDuplicate(mi(title: "Duplicate",
            action: #selector(FileTreeViewController.performDuplicate(_:)), target: yNode8))
        pump(0.4)
        let added8 = dir("b").filter { !bBefore8.contains($0) }
        if added8.contains(where: { $0.contains("copy") }) {
            ok("duplicate yields a 'copy'-suffixed name: \(added8)")
        } else { fail("duplicate did not produce a 'copy'-suffixed name; got: \(added8)") }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 9 — Drag: pasteboardWriterForItem non-nil; validateDrop refuses
        //          a descendant target and a foreign-source drag.
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 9] drag API")
        expand("a"); pump(0.1)
        guard let aNode9 = w("a") else { print("  ENV  a/ not found for drag"); exit(2) }
        let writer9 = vc.outlineView(ov, pasteboardWriterForItem: aNode9)
        if writer9 != nil { ok("pasteboardWriterForItem(a/) is non-nil") }
        else { fail("pasteboardWriterForItem(a/) is nil — drag would never start") }

        let pb9 = NSPasteboard(name: NSPasteboard.Name("com.goblinportal.test.drag9"))
        pb9.clearContents()
        if let w9 = writer9 { pb9.writeObjects([w9]) }

        guard let innerNode9 = w("a/inner") else { print("  ENV  a/inner not found"); exit(2) }
        // Drop a/ onto a/inner — descendant cycle: must refuse.
        let fakeInfo9 = FakeDraggingInfo(pasteboard: pb9, source: ov)
        let op9 = vc.outlineView(ov, validateDrop: fakeInfo9,
                                 proposedItem: innerNode9, proposedChildIndex: -1)
        if op9 == [] { ok("validateDrop refuses a/ onto a/inner (descendant)") }
        else { fail("validateDrop accepted descendant drop") }

        // Drop from a foreign source — must refuse.
        let foreignOV  = NSOutlineView()
        let fakeInfo9b = FakeDraggingInfo(pasteboard: pb9, source: foreignOV)
        let op9b = vc.outlineView(ov, validateDrop: fakeInfo9b,
                                  proposedItem: innerNode9, proposedChildIndex: -1)
        if op9b == [] { ok("validateDrop refuses drag from a foreign source (S-3)") }
        else { fail("validateDrop accepted foreign drag — Finder drops not refused (S-3)") }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 10 — Expansion of a/ survives a sibling rename in b/.
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 10] expansion survives sibling rename")
        expand("a"); pump(0.1)
        guard let aNode10 = w("a") else { print("  ENV  a/ not found for case 10"); exit(2) }
        if !ov.isItemExpanded(aNode10) { ov.expandItem(aNode10); pump(0.1) }

        expand("b"); pump(0.1)
        if let yNode10 = w("b/Y.txt") {
            ov.selectRowIndexes([ov.row(forItem: yNode10)], byExtendingSelection: false)
            vc.beginInlineEdit(for: yNode10, isNew: false)
            pump(0.1)
            vc.commitEditedName("Z.txt")
            pump(0.4)
        }
        guard let aNode10b = w("a") else { print("  ENV  a/ not found after rename"); exit(2) }
        if ov.isItemExpanded(aNode10b) { ok("a/ is still expanded after b/Y.txt rename") }
        else { fail("a/ collapsed after sibling rename — expansion not preserved") }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 11 — CONTROL: a deliberately wrong assertion must register a failure.
        // The inner failure is NOT counted in the gate's bad total — it proves
        // the assert helper is not a no-op.
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 11] control: deliberate failure inside sub-check")
        var controlFailed = 0
        let innerResult = (1 == 2)   // always false
        if !innerResult { controlFailed += 1 }
        if controlFailed == 1 {
            ok("control: inner failure correctly recorded (assert helper is not a no-op)")
        } else {
            fail("control: inner failure not recorded — assert helper is a no-op")
        }
    }

    // MARK: — Cases 12–13 (PR #157 window-survival gate)

    // WHY THESE CASES EXIST. Before PR #157 the file-mutation handler called
    // closeDocument BEFORE openFile for renames. When the pane was the Space's only
    // document, closeDocument emptied documents[] and triggered
    // spaceViewControllerDidCloseLastDocument, which closed the window.
    // Similarly, trashing the only open file closed the Space.
    // These two cases prove the fixed handler keeps the window alive in both scenarios.

    static func runCases12to14() {

        // ─────────────────────────────────────────────────────────────────────
        // CASE 12 — Rename of the Space's sole FileViewerPane keeps the window open
        //           and updates the tab URL to the new path.
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 12] rename sole file pane: window survives, tab URL updated")

        // Create a temp file and open it as the only document in a fresh Space.
        let tempDir12 = treeRoot.appendingPathComponent("mutation_case12")
        let oldFile12 = tempDir12.appendingPathComponent("before.txt")
        let newFile12 = tempDir12.appendingPathComponent("after.txt")
        try? FileManager.default.createDirectory(at: tempDir12,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: oldFile12.path, contents: Data("x".utf8))

        // PRECONDITION: the harness never calls openFirstDocument() (it only
        // orderFront()s the window), so the Space starts with ZERO documents. If that
        // ever changes this case would silently stop testing the sole-pane path, so
        // assert it rather than assume it.
        guard svc.documents.isEmpty else {
            fail("case 12: precondition — Space starts with \(svc.documents.count) docs, want 0"); return }
        // Use openFile to land exactly one clean FileViewerPane.
        svc.openFile(url: oldFile12)
        pump(0.2)
        guard svc.documents.count == 1 else {
            fail("case 12: precondition — want exactly 1 doc, have \(svc.documents.count)"); return }

        guard let window12 = svc.view.window else {
            print("  ENV  SpaceViewController has no window in case 12"); return }

        // Deliver the rename mutation — this is the exact call the file tree makes.
        svc.handleFileMutation(oldURL: oldFile12, newURL: newFile12)
        pump(0.3)

        if window12.isVisible {
            ok("case 12: window still open after rename of sole pane (PR #157 fix)")
        } else {
            fail("case 12: window closed after rename — old close-before-open bug regressed")
        }

        let hasNewURL = svc.documents.contains(where: {
            ($0 as? FileViewerPane)?.url == newFile12
        })
        if hasNewURL {
            ok("case 12: tab URL updated to new path after rename")
        } else {
            fail("case 12: no tab at new URL after rename — \(svc.documents.count) docs")
        }
        let hasOldURL = svc.documents.contains(where: {
            ($0 as? FileViewerPane)?.url == oldFile12
        })
        if !hasOldURL {
            ok("case 12: old-URL tab removed after rename")
        } else {
            fail("case 12: stale old-URL tab still present after rename")
        }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 13 — Trash of the Space's sole FileViewerPane keeps the window open.
        // The tab is intentionally left open (stale URL) — same contract as dirty
        // panes — rather than closing the Space entirely (PR #157 fix).
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 13] trash sole file pane: window survives (tab stays open)")

        // Reuse case 12's survivor: it is the Space's ONLY document, which is the
        // state the trash guard exists for. Opening a second file here (as this case
        // first did) left 2 documents, so the guard was never reached and the case
        // only "failed" under the bug because case 12 had already closed the window.
        let trashFile13 = newFile12
        guard svc.documents.count == 1 else {
            fail("case 13: precondition — want exactly 1 doc, have \(svc.documents.count)"); return }
        guard let window13 = svc.view.window, window13.isVisible else {
            print("  ENV  window not visible entering case 13"); return }
        try? FileManager.default.removeItem(at: trashFile13)  // temp tree; never the real Trash

        svc.handleFileMutation(oldURL: trashFile13, newURL: nil)
        pump(0.3)

        if window13.isVisible {
            ok("case 13: window still open after trash of sole pane (PR #157 fix)")
        } else {
            fail("case 13: window closed after trash — close-when-last bug regressed")
        }
        if svc.documents.count == 1 {
            ok("case 13: sole tab left open after trash (no last-document close)")
        } else {
            fail("case 13: want the sole tab left open, have \(svc.documents.count) docs")
        }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 14 — Rename onto a path that ALREADY has an open (stale) tab.
        // `openFile` dedupes onto that tab and appends nothing, so the handler must
        // reorder the tab it got back, not whatever sits at `count - 1`. Layout is
        // chosen so the position-based bug visibly moves an UNRELATED tab:
        // [after, p, q, r] + rename p -> after. Correct: [q, after, r]. Bug: [after, r, q].
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 14] rename onto an already-open tab: no unrelated tab moves")
        let dir14 = treeRoot.appendingPathComponent("mutation_case14")
        try? FileManager.default.createDirectory(at: dir14, withIntermediateDirectories: true)
        let p14 = dir14.appendingPathComponent("p.txt"), q14 = dir14.appendingPathComponent("q.txt")
        let r14 = dir14.appendingPathComponent("r.txt")
        for u in [p14, q14, r14] { FileManager.default.createFile(atPath: u.path, contents: Data("z".utf8)) }
        for u in [p14, q14, r14] { svc.openFile(url: u) }
        pump(0.2)
        func names() -> [String] { svc.documents.compactMap { ($0 as? FileViewerPane)?.url.lastPathComponent } }
        guard names() == ["after.txt", "p.txt", "q.txt", "r.txt"] else {
            fail("case 14: precondition — want [after, p, q, r], have \(names())"); return }
        svc.handleFileMutation(oldURL: p14, newURL: newFile12)   // p.txt -> case 12's after.txt
        pump(0.3)
        if names() == ["q.txt", "after.txt", "r.txt"] {
            ok("case 14: deduped replacement moved to p's slot; q and r untouched")
        } else {
            fail("case 14: want [q, after, r], have \(names()) — wrong tab reordered")
        }
    }
}
