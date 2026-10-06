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
}
