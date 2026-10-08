//
//  FileTreeViewController+FileOps.swift
//  Inline rename and New File/Folder (the edit lifecycle), plus the responder
//  actions for Move to Trash, Cut/Copy/Paste and Duplicate — all routed through
//  FileOperationPolicy.
//
//  Associated-object storage provides the state this extension needs because
//  Swift extensions cannot add stored properties. The shared helpers these actions
//  lean on (target resolution, post-mutation refresh, error reporting, the trash
//  confirmation seam, the deferred root) live in `+Mutation.swift`.
//
//  isEditingInline is read by guards in refresh() and setRoot(_:) in
//  FileTreeViewController.swift, and by the git guard in +Git.swift.
//

import AppKit
import ObjectiveC

// MARK: - Associated-object keys

nonisolated(unsafe) private var editingInlineKey:  UInt8 = 0
nonisolated(unsafe) private var pendingReloadKey:  UInt8 = 0
nonisolated(unsafe) private var editedRowURLKey:   UInt8 = 0
nonisolated(unsafe) private var editedNodeKey:     UInt8 = 0
nonisolated(unsafe) private var pasteboardItemsKey: UInt8 = 0
nonisolated(unsafe) private var isNewNodeKey:      UInt8 = 0
nonisolated(unsafe) private var isCutOperationKey: UInt8 = 0

extension FileTreeViewController {

    // MARK: Computed properties (associated-object backed)

    /// True while an inline cell editor is open. Read by refresh() and setRoot(_:) guards.
    var isEditingInline: Bool {
        get { objc_getAssociatedObject(self, &editingInlineKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &editingInlineKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// When true, a reload was requested while editing; replayed on commit/cancel.
    var pendingReload: Bool {
        get { objc_getAssociatedObject(self, &pendingReloadKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &pendingReloadKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// URL of the node whose cell is being edited. Set at edit start, cleared on finish.
    var editedRowURL: URL? {
        get { objc_getAssociatedObject(self, &editedRowURLKey) as? URL }
        set { objc_setAssociatedObject(self, &editedRowURLKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The node being edited. Kept as well as its URL because `outlineView.editedRow`
    /// is -1 throughout a view-based `editColumn` session (measured), so the row is
    /// found with `row(forItem:)` on this, never through `editedRow`.
    private var editedNode: FileNode? {
        get { objc_getAssociatedObject(self, &editedNodeKey) as? FileNode }
        set { objc_setAssociatedObject(self, &editedNodeKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// URLs placed on the internal clipboard by Cut or Copy.
    var pasteboardItems: [URL]? {
        get { objc_getAssociatedObject(self, &pasteboardItemsKey) as? [URL] }
        set { objc_setAssociatedObject(self, &pasteboardItemsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// True when the clipboard was populated by Cut (pending move), false for Copy.
    private var isCutOperation: Bool {
        get { objc_getAssociatedObject(self, &isCutOperationKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &isCutOperationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// True when the row being edited is a brand-new placeholder (not yet on disk).
    private var isNewNode: Bool {
        get { objc_getAssociatedObject(self, &isNewNodeKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &isNewNodeKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Exposes `scrollView` to `SpaceViewController+SidebarActivity.swift`.
    var sidebarScrollView: NSScrollView { scrollView }

    // MARK: Inline edit lifecycle

    /// Begin inline rename for `node`. If `isNew` is true, a placeholder row was already
    /// inserted into the tree and the file does not yet exist on disk.
    func beginInlineEdit(for node: FileNode, isNew: Bool) {
        // One edit at a time: a second begin would orphan the first field's state.
        guard !isEditingInline else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        // `makeIfNecessary: true` because a just-inserted placeholder may not have a
        // cell view yet; without one there is nothing to edit.
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? NSTableCellView,
              let tf = cell.textField else { return }

        tf.isEditable = true
        tf.isSelectable = true
        tf.delegate = self

        isEditingInline = true
        isNewNode = isNew
        editedRowURL = node.url
        editedNode = node
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.editColumn(0, row: row, with: nil, select: true)
    }

    /// Commit the current inline edit to `name`.
    func commitEditedName(_ name: String) {
        guard isEditingInline, let oldURL = editedRowURL else { return }
        // Captured BEFORE endEditSession() clears them (C1): reading them after made
        // every commit look like a rename and every placeholder look like a file.
        let wasNew = isNewNode
        let wasDirectory = editedNode?.isDirectory ?? false
        endEditSession()

        let parent = oldURL.deletingLastPathComponent()
        // Unchanged name on an existing item: nothing to do, and attempting the
        // rename would only report a collision with itself.
        if !wasNew && name == oldURL.lastPathComponent {
            finishEditReplay(select: oldURL); return
        }
        guard FileOperationPolicy.isValidName(name) else {
            reportFileOpError("“\(name)” is not a valid name.", nil)
            finishEditReplay(select: wasNew ? nil : oldURL); return
        }
        let newURL = parent.appendingPathComponent(name)
        do {
            if wasNew {
                if wasDirectory {
                    try FileOperationPolicy.createDirectory(at: newURL)
                } else {
                    try FileOperationPolicy.createFile(at: newURL)
                }
                // R1.3: notify on creation so that a stale tab at this path (left open
                // by a sole-pane trash, PR #157) is refreshed when the file is recreated.
                // oldURL == newURL signals creation — no prior location, just an arrival.
                // The delegate no-ops for a tab it cannot find, so this is safe when
                // no stale tab exists.
                notifyDelegateOfMutation(oldURL: newURL, newURL: newURL)
                finishEditReplay(select: newURL)
            } else {
                try FileOperationPolicy.rename(from: oldURL, to: newURL)
                notifyDelegateOfMutation(oldURL: oldURL, newURL: newURL)
                finishEditReplay(select: newURL, rebasing: [(oldURL, newURL)])
            }
        } catch {
            reportFileOpError(wasNew ? "Could not create “\(name)”." : "Could not rename to “\(name)”.", error)
            finishEditReplay(select: wasNew ? nil : oldURL)
        }
    }

    /// Cancel the current inline edit. A new-node placeholder vanishes with the
    /// refresh (it never reached disk, and `reloadChildren()` reads disk); nothing
    /// is created.
    func cancelInlineEdit() {
        guard isEditingInline, let oldURL = editedRowURL else { return }
        let wasNew = isNewNode  // captured before endEditSession() clears it (C1)
        endEditSession()
        finishEditReplay(select: wasNew ? nil : oldURL)
    }

    /// The edited row's text field, found through the node (fact: `editedRow` is -1).
    fileprivate func editedTextField() -> NSTextField? {
        guard let node = editedNode else { return nil }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return nil }
        return (outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? NSTableCellView)?.textField
    }

    /// Clear the edit state FIRST, then end the field editor: `abortEditing()` posts
    /// `controlTextDidEndEditing`, and that handler must see `isEditingInline == false`
    /// or it would commit/cancel a second time.
    private func endEditSession() {
        let tf = editedTextField()
        isEditingInline = false
        isNewNode = false
        editedRowURL = nil
        editedNode = nil
        tf?.isEditable = false
        tf?.isSelectable = false
        outlineView.abortEditing()
    }

    // MARK: File operation responder actions

    @objc func performNewFile(_ sender: Any? = nil) {
        guard !isEditingInline else { return }
        let target = targetDirectory(sender)
        insertPlaceholder(url: target.appendingPathComponent(freeName("untitled", in: target)),
                          isDirectory: false)
    }

    @objc func performNewFolder(_ sender: Any? = nil) {
        guard !isEditingInline else { return }
        let target = targetDirectory(sender)
        insertPlaceholder(url: target.appendingPathComponent(freeName("untitled folder", in: target)),
                          isDirectory: true)
    }

    /// Asks first (S-1/H8), through the `confirmTrash` seam. Trash, never delete:
    /// nothing in the file-ops path deletes permanently.
    @objc func performTrash(_ sender: Any? = nil) {
        guard !isEditingInline else { return }
        let urls = topLevel(targetNodes(sender).map(\.url))
        guard !urls.isEmpty, Self.confirmTrash(urls) else { return }
        for url in urls {
            do {
                try FileOperationPolicy.trashItem(at: url)
                notifyDelegateOfMutation(oldURL: url, newURL: nil)
            } catch {
                reportFileOpError("Could not move “\(url.lastPathComponent)” to the Trash.", error)
            }
        }
        refreshAfterMutation(select: nil)
    }

    @objc func performCut(_ sender: Any? = nil) {
        pasteboardItems = topLevel(targetNodes(sender).map(\.url))
        isCutOperation = true
    }

    @objc func performCopy(_ sender: Any? = nil) {
        pasteboardItems = topLevel(targetNodes(sender).map(\.url))
        isCutOperation = false
    }

    @objc func performPaste(_ sender: Any? = nil) {
        guard !isEditingInline, let items = pasteboardItems, !items.isEmpty else { return }
        let dest = targetDirectory(sender)
        let wasCut = isCutOperation
        var last: URL?
        var rebase: [(URL, URL)] = []
        for url in items {
            // Into itself or below itself is a cycle for a move and an unbounded
            // recursion risk for a copy; refuse both rather than let FileManager decide.
            if FileOperationPolicy.isDescendant(url: resolvedLocation(dest), of: resolvedLocation(url)) {
                reportFileOpError("Cannot paste “\(url.lastPathComponent)” into itself.", nil)
                continue
            }
            do {
                if wasCut {
                    // Cutting and pasting into the same folder is a no-op, not a collision.
                    if resolvedLocation(url.deletingLastPathComponent()).path == resolvedLocation(dest).path { continue }
                    let finalURL = dest.appendingPathComponent(url.lastPathComponent)
                    try FileOperationPolicy.move(from: url, to: dest)
                    notifyDelegateOfMutation(oldURL: url, newURL: finalURL)
                    rebase.append((url, finalURL)); last = finalURL
                } else {
                    // Free-or-suffix: keeps the name when the destination lacks it (M1).
                    last = try FileOperationPolicy.copy(from: url, into: dest)
                }
            } catch {
                reportFileOpError("Could not paste “\(url.lastPathComponent)”.", error)
            }
        }
        if wasCut { pasteboardItems = nil; isCutOperation = false }  // a cut is consumed once
        refreshAfterMutation(select: last, rebasing: rebase)
    }

    @objc func performDuplicate(_ sender: Any? = nil) {
        guard !isEditingInline else { return }
        var last: URL?
        for url in topLevel(targetNodes(sender).map(\.url)) {
            do {
                // ALWAYS suffixes: a duplicate lands beside its original by definition.
                last = try FileOperationPolicy.copy(
                    from: url, into: url.deletingLastPathComponent(), alwaysSuffix: true)
            } catch {
                reportFileOpError("Could not duplicate “\(url.lastPathComponent)”.", error)
            }
        }
        refreshAfterMutation(select: last)
    }

    func notifyDelegateOfMutation(oldURL: URL, newURL: URL?) {
        delegate?.fileTree(self, didMutate: oldURL, newURL: newURL)
    }
}

// MARK: - FileTreeOutlineViewKeyDelegate conformance

extension FileTreeViewController: FileTreeOutlineViewKeyDelegate {
    func deleteSelectedRows() { performTrash() }
    func beginEditingSelected() {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode else { return }
        beginInlineEdit(for: node, isNew: false)
    }
    func commitEdit() {
        guard let tf = editedTextField() else { return }
        commitEditedName(tf.stringValue)
    }
    func cancelEdit() { cancelInlineEdit() }
    var hasFileClipboard: Bool { !(pasteboardItems ?? []).isEmpty }
}

// MARK: - NSTextFieldDelegate conformance

extension FileTreeViewController: NSTextFieldDelegate {
    /// Focus left the field without Return or Escape (a click elsewhere, Tab):
    /// commit, as Finder does. Return and Escape are consumed by `doCommandBy` below
    /// and by then `isEditingInline` is false, so they never reach this twice.
    ///
    /// IMPORTANT: `editColumn(_:row:with:select:)` steals focus from any other text
    /// field in the window (e.g. the NSSearchField filter), which fires that field's
    /// `textDidEndEditing` notification — and FileTreeViewController is that field's
    /// delegate too. The `obj.object === editedTextField()` guard prevents the filter
    /// field's notification from being mistaken for the inline-edit ending.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditingInline,
              let tf = obj.object as? NSTextField,
              tf === editedTextField() else { return }
        commitEditedName(tf.stringValue)
    }

    /// The typed text is read from `control`, the field being edited (M3) — the
    /// only reliable handle, since `editedRow` is -1 during the session.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard isEditingInline else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitEditedName((control as? NSTextField)?.stringValue ?? textView.string)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelInlineEdit(); return true }
        return false
    }
}
