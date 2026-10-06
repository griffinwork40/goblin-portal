//
//  FileTreeViewController+FileOps.swift
//  Inline rename, New File/Folder, Move to Trash, Cut/Copy/Paste/Duplicate,
//  and drag-and-drop — all routed through FileOperationPolicy.
//
//  Associated-object storage provides the four pieces of state this extension
//  needs without touching `FileTreeViewController.swift` (at 348/350 LOC).
//
//  isEditingInline is read by guards injected into refresh() and setRoot(_:)
//  in FileTreeViewController.swift, and by the git guard in +Git.swift.
//

import AppKit
import ObjectiveC

// MARK: - Associated-object keys

nonisolated(unsafe) private var editingInlineKey:  UInt8 = 0
nonisolated(unsafe) private var pendingReloadKey:  UInt8 = 0
nonisolated(unsafe) private var editedRowURLKey:   UInt8 = 0
nonisolated(unsafe) private var pasteboardItemsKey: UInt8 = 0
nonisolated(unsafe) private var isNewNodeKey:      UInt8 = 0
nonisolated(unsafe) private var isCutOperationKey: UInt8 = 0

// MARK: - FileTreeViewController extension (computed properties + operations)

extension FileTreeViewController {

    // MARK: Computed properties (associated-object backed)

    /// True while an inline cell editor is open. Read by refresh() and setRoot(_:) guards.
    var isEditingInline: Bool {
        get { objc_getAssociatedObject(self, &editingInlineKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &editingInlineKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// When true, a reload was requested while editing; fires on commit/cancel.
    var pendingReload: Bool {
        get { objc_getAssociatedObject(self, &pendingReloadKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &pendingReloadKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// URL of the node whose cell is being edited. Set at edit start, cleared on finish.
    var editedRowURL: URL? {
        get { objc_getAssociatedObject(self, &editedRowURLKey) as? URL }
        set { objc_setAssociatedObject(self, &editedRowURLKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
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

    /// Exposes the private `scrollView` to `SpaceViewController+SidebarActivity.swift`.
    /// (scrollView was changed from `private` to `internal` in FileTreeViewController.swift.)
    var sidebarScrollView: NSScrollView { scrollView }

    // MARK: Inline edit lifecycle

    /// Begin inline rename for `node`. If `isNew` is true, a placeholder row was already
    /// inserted into the tree and the file does not yet exist on disk.
    func beginInlineEdit(for node: FileNode, isNew: Bool) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        // Make the cell's text field editable.
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? NSTableCellView,
              let tf = cell.textField else { return }

        tf.isEditable = true
        tf.isSelectable = true
        tf.delegate = self

        isEditingInline = true
        isNewNode = isNew
        editedRowURL = node.url
        // Wire the key delegate so Return/Escape reach us.
        outlineView.fileOpsDelegate = self
        outlineView.editColumn(0, row: row, with: nil, select: true)
    }

    /// Commit the current inline edit to `name`.
    func commitEditedName(_ name: String) {
        guard isEditingInline, let oldURL = editedRowURL else { return }
        endEditSession()

        guard FileOperationPolicy.isValidName(name) else { NSSound.beep(); reloadAfterEdit(); return }
        let parent = oldURL.deletingLastPathComponent()
        let newURL  = parent.appendingPathComponent(name)

        do {
            if isNewNode {
                // Placeholder — actually create the file or directory now.
                // Use the FileNode's `isDirectory` flag, not a path-extension heuristic
                // (which misidentifies extensionless files like Makefile or LICENSE).
                let wasDirectory = (nodeForURL(oldURL) ?? nodeForURL(oldURL.deletingLastPathComponent())
                    .flatMap { $0.children?.first { $0.url == oldURL } })?.isDirectory ?? false
                if wasDirectory {
                    try FileOperationPolicy.createDirectory(at: newURL)
                } else {
                    try FileOperationPolicy.createFile(at: newURL)
                }
            } else {
                try FileOperationPolicy.rename(from: oldURL, to: newURL)
            }
            notifyDelegateOfMutation(oldURL: oldURL, newURL: newURL)
        } catch {
            NSSound.beep()
        }
        reloadAfterEdit()
    }

    /// Cancel the current inline edit. If a new-node placeholder, remove it.
    func cancelInlineEdit() {
        guard isEditingInline, let oldURL = editedRowURL else { return }
        endEditSession()
        if isNewNode {
            // Remove the placeholder: it was never committed to disk.
            let parent = oldURL.deletingLastPathComponent()
            let parentNode = nodeForURL(parent)
            parentNode?.reloadChildren()
            outlineView.reloadItem(parentNode, reloadChildren: true)
        }
        reloadAfterEdit()
    }

    // MARK: File operation responder actions

    @objc func performNewFile(_ sender: Any? = nil) {
        let target = selectedDirectoryURL() ?? root.url
        let name = collisionFreeName(base: "untitled", in: target, isDirectory: false)
        let url = target.appendingPathComponent(name)
        insertPlaceholder(url: url, isDirectory: false)
    }

    @objc func performNewFolder(_ sender: Any? = nil) {
        let target = selectedDirectoryURL() ?? root.url
        let name = collisionFreeName(base: "untitled folder", in: target, isDirectory: true)
        let url = target.appendingPathComponent(name)
        insertPlaceholder(url: url, isDirectory: true)
    }

    @objc func performTrash(_ sender: Any? = nil) {
        let rows = outlineView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let nodes = rows.compactMap { outlineView.item(atRow: $0) as? FileNode }
        guard !nodes.isEmpty else { return }
        for node in nodes {
            do {
                let old = node.url
                try FileOperationPolicy.trashItem(at: node.url)
                notifyDelegateOfMutation(oldURL: old, newURL: nil)
            } catch { NSSound.beep() }
        }
        root.reloadChildren()
        outlineView.reloadData()
    }

    @objc func performCut(_ sender: Any? = nil) {
        let rows = outlineView.selectedRowIndexes
        pasteboardItems = rows.compactMap { (outlineView.item(atRow: $0) as? FileNode)?.url }
        isCutOperation = true
    }

    @objc func performCopy(_ sender: Any? = nil) {
        let rows = outlineView.selectedRowIndexes
        pasteboardItems = rows.compactMap { (outlineView.item(atRow: $0) as? FileNode)?.url }
        isCutOperation = false
    }

    @objc func performPaste(_ sender: Any? = nil) {
        guard let items = pasteboardItems, !items.isEmpty else { return }
        let dest = selectedDirectoryURL() ?? root.url
        let wascut = isCutOperation
        for url in items {
            do {
                if wascut {
                    try FileOperationPolicy.move(from: url, to: dest.appendingPathComponent(url.lastPathComponent))
                    notifyDelegateOfMutation(oldURL: url, newURL: dest.appendingPathComponent(url.lastPathComponent))
                } else {
                    try FileOperationPolicy.copy(from: url, into: dest)
                }
            } catch { NSSound.beep() }
        }
        if wascut { pasteboardItems = nil; isCutOperation = false }  // clipboard consumed
        root.reloadChildren()
        outlineView.reloadData()
    }

    @objc func performDuplicate(_ sender: Any? = nil) {
        let rows = outlineView.selectedRowIndexes
        let urls = rows.compactMap { (outlineView.item(atRow: $0) as? FileNode)?.url }
        for url in urls {
            let parent = url.deletingLastPathComponent()
            do { try FileOperationPolicy.copy(from: url, into: parent) } catch { NSSound.beep() }
        }
        root.reloadChildren()
        outlineView.reloadData()
    }

    // MARK: Delegate notification

    func notifyDelegateOfMutation(oldURL: URL, newURL: URL?) {
        delegate?.fileTree(self, didMutate: oldURL, newURL: newURL)
    }

    // MARK: Private helpers

    private func endEditSession() {
        isEditingInline = false
        isNewNode = false
        editedRowURL = nil
        // Restore text field to read-only after the editor resigns.
        if outlineView.editedRow >= 0,
           let cell = outlineView.view(atColumn: 0, row: outlineView.editedRow, makeIfNecessary: false)
               as? NSTableCellView {
            cell.textField?.isEditable = false
            cell.textField?.isSelectable = false
        }
        outlineView.abortEditing()
    }

    private func reloadAfterEdit() {
        root.reloadChildren()
        outlineView.reloadData()
        pendingReload = false
    }

    private func selectedDirectoryURL() -> URL? {
        guard outlineView.selectedRow >= 0 else { return nil }
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode else { return nil }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func nodeForURL(_ url: URL) -> FileNode? {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, node.url == url { return node }
        }
        return nil
    }

    private func collisionFreeName(base: String, in directory: URL, isDirectory: Bool) -> String {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return FileOperationPolicy.collisionSafeNewName(base: base, existingNames: existing)
    }

    private func insertPlaceholder(url: URL, isDirectory: Bool) {
        let parentURL = url.deletingLastPathComponent()
        // Expand parent if needed.
        if let parentNode = nodeForURL(parentURL) {
            outlineView.expandItem(parentNode)
            parentNode.reloadChildren()
            // Insert a transient placeholder node.
            let placeholder = FileNode(url: url, isDirectory: isDirectory)
            parentNode.insertChild(placeholder)
            outlineView.reloadItem(parentNode, reloadChildren: true)
            beginInlineEdit(for: placeholder, isNew: true)
        } else {
            // Fallback: create at root level.
            root.reloadChildren()
            let placeholder = FileNode(url: url, isDirectory: isDirectory)
            root.insertChild(placeholder)
            outlineView.reloadData()
            beginInlineEdit(for: placeholder, isNew: true)
        }
    }
}

// MARK: - FileTreeOutlineViewKeyDelegate conformance

extension FileTreeViewController: FileTreeOutlineViewKeyDelegate {
    func deleteSelectedRows() { performTrash() }
    func beginEditingSelected() {
        guard outlineView.selectedRow >= 0 else { return }
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode else { return }
        beginInlineEdit(for: node, isNew: false)
    }
    func commitEdit() {
        guard let tf = activeTextField() else { return }
        commitEditedName(tf.stringValue)
    }
    func cancelEdit() { cancelInlineEdit() }

    private func activeTextField() -> NSTextField? {
        guard outlineView.editedRow >= 0,
              let cell = outlineView.view(atColumn: 0, row: outlineView.editedRow,
                                         makeIfNecessary: false) as? NSTableCellView
        else { return nil }
        return cell.textField
    }
}

// MARK: - NSTextFieldDelegate conformance

extension FileTreeViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, isEditingInline else { return }
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        // NSReturnTextMovement = 16, NSCancelTextMovement = 0 (after ESC)
        if movement == 16 {
            commitEditedName(tf.stringValue)
        } else {
            cancelInlineEdit()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commitEdit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelInlineEdit(); return true }
        return false
    }
}

// MARK: - Default implementation of new delegate method

extension FileTreeViewControllerDelegate {
    func fileTree(_ controller: FileTreeViewController, didMutate oldURL: URL, newURL: URL?) {}
}
