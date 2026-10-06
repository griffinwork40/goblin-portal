// check-file-tree-ops-harness.swift
// Scaffolding, shared helpers, and Cases 1–5 for the file-tree behavioural gate.
// Compiled together with check-file-tree-ops-cases.swift by check-file-tree-ops.sh
// against GoblinPortal's own object files. Same two-file split as
// check-sidebar-activity.sh / check-sidebar-activity-harness.swift.
//
// EXIT CODES:
//   0 = all cases passed
//   1 = a real assertion failed
//   2 = environmental failure (window not created, objects missing, etc.)
//
// HEADLESS CASES EXCLUDED:
//   None. All 11 cases drive the real controller. Case 9 uses a minimal
//   NSObject stub for NSDraggingInfo — constructing a real in-process drag
//   requires synthesised NSEvents and a drag session, which is too fragile
//   for an offscreen gate. The stub exercises pasteboardWriterForItem and
//   the source-identity / descendant checks inside validateDrop.
//
// SEAMS STUBBED BEFORE ANY ACTION:
//   FileTreeViewController.confirmTrash — returns a configurable Bool.
//   FileTreeViewController.presentAlert — records alerts, never runs modals.
//   All trash is safety-checked to only touch paths inside the temp tree.
//
// TEMP TREE (created by the shell wrapper, passed as argv[1]):
//   a/  a/inner/  a/x.txt
//   b/  b/y.txt

import AppKit
@testable import GoblinPortal

// ── Minimal NSDraggingInfo stub for case 9 ───────────────────────────────────
// draggingSource is critical: validateDrop guards identity against the outline
// view, so FakeDraggingInfo carries the real outline view as source.
// draggedImageLocation and draggedImage fulfil the deprecated-but-required ObjC
// protocol members that the compiler still requires a full conformance to declare.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    var draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber: Int = 0
    var draggingLocation: NSPoint = .zero
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 0
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
            options: NSDraggingItemEnumerationOptions, for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
    init(pasteboard: NSPasteboard, source: Any?) {
        self.draggingPasteboard = pasteboard; self.draggingSource = source
    }
}

// ── Gate state ────────────────────────────────────────────────────────────────
// bad is mutated only on the main actor (inside Harness.run).
var gBad: Int32 = 0

// ── @MainActor enum Harness ───────────────────────────────────────────────────
// All harness logic lives here so Swift 6 sees every member as @MainActor-isolated.
// The top-level code only invokes MainActor.assumeIsolated { Harness.run() }.
@MainActor
enum Harness {

    // MARK: — Shared state available to both harness files

    static var vc: FileTreeViewController!
    static var ov: FileTreeOutlineView!
    static var treeRoot: URL!
    // trashConfirmAnswer is read by the confirmTrash closure; written per-case.
    static var trashConfirmAnswer: Bool = false

    // MARK: — Shared helpers

    static func ok(_ m: String)   { print("  ok  \(m)") }
    static func fail(_ m: String) { print("  FAIL \(m)"); gBad += 1 }

    /// Pump the main run loop for `seconds` so view-layout side-effects propagate.
    static func pump(_ seconds: Double = 0.15) {
        let dl = Date().addingTimeInterval(seconds)
        while Date() < dl {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Walk the displayed tree from root to the node for `url`.
    static func treeWalk(to url: URL) -> FileNode? {
        let root = vc.root
        let rootCount = root.url.pathComponents.count
        guard url.pathComponents.count >= rootCount,
              url.path.hasPrefix(root.url.path) else { return nil }
        if url.path == root.url.path { return root }
        var current: FileNode = root
        for component in url.pathComponents.dropFirst(rootCount) {
            if current.children == nil { current.reloadChildren() }
            guard let child = current.children?.first(where: { $0.name == component })
            else { return nil }
            current = child
        }
        return current
    }

    /// Walk to `treeRoot`-relative path.
    static func w(_ rel: String) -> FileNode? {
        treeWalk(to: treeRoot.appendingPathComponent(rel))
    }

    /// Expand the node at `rel` and pump.
    static func expand(_ rel: String) {
        let url = treeRoot.appendingPathComponent(rel)
        guard let node = treeWalk(to: url) else { return }
        ov.expandItem(node); pump(0.1)
    }

    /// Directory contents at `rel`, sorted.
    static func dir(_ rel: String) -> [String] {
        let url = treeRoot.appendingPathComponent(rel)
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
    }

    /// True if `rel` is a regular file (not a directory) inside treeRoot.
    static func existsFile(_ rel: String) -> Bool {
        var isDir: ObjCBool = false
        let p = treeRoot.appendingPathComponent(rel).path
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue
    }

    /// True if `rel` is a directory inside treeRoot.
    static func existsDir(_ rel: String) -> Bool {
        var isDir: ObjCBool = false
        let p = treeRoot.appendingPathComponent(rel).path
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    /// Build an NSMenuItem with a `representedObject` node — mirrors how the context
    /// menu sends actions (H2): representedObject wins over the selection.
    static func mi(title: String, action: Selector, target node: FileNode?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = node; return item
    }

    // MARK: — Entry point

    static func run() -> Int32 {
        // Resolve symlinks so treeRoot matches what FileManager returns for children.
        // On macOS, /var/folders is a symlink to /private/var/folders; walk(to:)
        // uses a hasPrefix check that fails if root.url.path and child URL paths
        // have different symlink resolution states (measured: insertPlaceholder
        // silently returned nil parent when the shell did not resolve the path).
        treeRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .resolvingSymlinksInPath()

        // Stub the seams BEFORE any action so no modal can block the gate.
        FileTreeViewController.confirmTrash = { urls in
            for u in urls {
                let r  = u.resolvingSymlinksInPath().path
                let rt = Harness.treeRoot.resolvingSymlinksInPath().path
                guard r.hasPrefix(rt + "/") || r == rt else {
                    fatalError("SAFETY: trash path outside temp tree: \(u.path)")
                }
            }
            return Harness.trashConfirmAnswer
        }
        FileTreeViewController.presentAlert = { _ in }   // suppress all modals

        // Build a SpaceWindowController rooted at the temp tree.
        let wc = SpaceWindowController(config: .defaults(), root: treeRoot)
        guard let window = wc.window else {
            print("  ENV  SpaceWindowController produced no window"); return 2 }
        vc = wc.space.fileTree
        ov = vc.outlineView
        window.setFrame(NSRect(x: -20000, y: -20000, width: 900, height: 600), display: false)
        window.orderFront(nil)
        pump(0.5)
        // Force a full tree reload so all nodes are in the outline before any case runs.
        vc.refresh(); pump(0.3)

        expand("a"); expand("b")

        runCases1to5()
        runCases6to11()   // defined in check-file-tree-ops-cases.swift

        print()
        if gBad == 0 { print("all file-tree-ops cases passed (11 cases)") }
        else { print("\(gBad) file-tree-ops case(s) FAILED") }
        return gBad == 0 ? 0 : 1
    }

    // MARK: — Cases 1–5

    static func runCases1to5() {

        // ─────────────────────────────────────────────────────────────────────
        // CASE 1 — fileOpsDelegate set after loadView (H1).
        // Falsification target F2: delete `outlineView.fileOpsDelegate = self`.
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 1] fileOpsDelegate set after loadView")
        if ov.fileOpsDelegate != nil { ok("fileOpsDelegate is non-nil (H1)") }
        else { fail("fileOpsDelegate is nil — ⌘⌫/Return/F2 are dead (H1)") }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 2 — New File committed as "Makefile" creates a regular file (C1).
        // Falsification target F1: move wasNew capture below endEditSession().
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 2] New File committed as 'Makefile'")
        expand("a")
        vc.performNewFile(mi(title: "New File",
            action: #selector(FileTreeViewController.performNewFile(_:)), target: w("a")))
        pump(0.2)
        vc.commitEditedName("Makefile")
        pump(0.3)
        if existsFile("a/Makefile") { ok("a/Makefile is a regular file (C1 + extension heuristic)") }
        else { fail("a/Makefile not created — wasNew capture before endEditSession failed (C1)") }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 3 — New Folder creates dir; cancelled New File creates nothing.
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 3] New Folder + cancelled New File")
        expand("a")
        vc.performNewFolder(mi(title: "New Folder",
            action: #selector(FileTreeViewController.performNewFolder(_:)), target: w("a")))
        pump(0.2)
        vc.commitEditedName("newdir")
        pump(0.3)
        if existsDir("a/newdir") { ok("a/newdir is a directory") }
        else { fail("a/newdir not created") }

        let before3 = dir("a")
        expand("a")
        vc.performNewFile(mi(title: "New File",
            action: #selector(FileTreeViewController.performNewFile(_:)), target: w("a")))
        pump(0.2)
        vc.cancelInlineEdit()
        pump(0.2)
        if dir("a") == before3 { ok("cancelled New File creates nothing new on disk") }
        else { fail("cancelled New File left a file: \(dir("a").filter { !before3.contains($0) })") }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 4 — Case-only rename b/y.txt → Y.txt.
        // contentsOfDirectory is the only reliable witness for a case-only rename
        // because fileExists(atPath:) on HFS+ is case-insensitive (measured fact).
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 4] case-only rename b/y.txt → Y.txt")
        expand("b")
        guard let yNode4 = w("b/y.txt") else { print("  ENV  b/y.txt not found"); exit(2) }
        ov.selectRowIndexes([ov.row(forItem: yNode4)], byExtendingSelection: false)
        vc.beginInlineEdit(for: yNode4, isNew: false)
        pump(0.1)
        vc.commitEditedName("Y.txt")
        pump(0.3)
        let bDir4 = dir("b")
        if bDir4.contains("Y.txt") { ok("b/ contains Y.txt after case-only rename") }
        else { fail("b/ missing Y.txt — two-step rename failed: \(bDir4)") }
        if !bDir4.contains("y.txt") { ok("b/ no longer contains y.txt") }
        else { fail("b/ still contains y.txt after case-only rename") }

        // ─────────────────────────────────────────────────────────────────────
        // CASE 5 — Trash: false → file survives; true → file gone.
        // Falsification target F3: make performTrash skip confirmTrash.
        // ─────────────────────────────────────────────────────────────────────
        print("\n  [case 5] trash confirmation seam")
        let throwPath = treeRoot.appendingPathComponent("b/throwaway.tmp")
        FileManager.default.createFile(atPath: throwPath.path, contents: nil)
        // Refresh the tree so the newly-created file appears as a node.
        vc.refresh(); pump(0.3)
        expand("b"); pump(0.1)
        guard let throwNode = w("b/throwaway.tmp") else {
            print("  ENV  throwaway.tmp node not found"); exit(2) }
        let trashMI = mi(title: "Move to Trash",
            action: #selector(FileTreeViewController.performTrash(_:)), target: throwNode)
        trashConfirmAnswer = false
        vc.performTrash(trashMI); pump(0.2)
        if FileManager.default.fileExists(atPath: throwPath.path) {
            ok("trash refused when confirmTrash=false: file still exists")
        } else { fail("file trashed despite confirmTrash returning false") }
        trashConfirmAnswer = true
        vc.performTrash(trashMI); pump(0.3)
        if !FileManager.default.fileExists(atPath: throwPath.path) {
            ok("trash proceeds when confirmTrash=true: file gone")
        } else { fail("file still exists after confirmTrash=true") }
    }
}

// ── Top-level entry point ─────────────────────────────────────────────────────
// Minimal top-level code: hand off to Harness immediately. All logic lives in the
// @MainActor enum above so Swift 6 sees full main-actor isolation on every member.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let code = MainActor.assumeIsolated { Harness.run() }
exit(code)
