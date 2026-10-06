//
//  FileTreeViewController+DragDrop.swift
//  Drag-and-drop conformance for the file tree's NSOutlineView.
//
//  Kept separate from +OutlineView.swift because the data-source callbacks for
//  read/display (numberOfChildren, child, viewFor) are a distinct concern from
//  the drag-lifecycle callbacks here. All filesystem work goes through
//  FileOperationPolicy, and every reload through `refreshAfterMutation`.
//
//  INTERNAL DRAGS ONLY. Only `draggedFileURLType` is registered (loadView), and
//  `validateDrop` additionally requires the drag to have started in this outline:
//  a drop from Finder used to be accepted as a MOVE, pulling files out of wherever
//  they lived (S-3).
//

import AppKit

extension FileTreeViewController {
    /// The private pasteboard type carrying a dragged row's file URL string.
    static let draggedFileURLType = NSPasteboard.PasteboardType("com.goblinportal.filetree.fileurl")

    /// Each dragged row writes its URL under the private type (H3). Without this
    /// method NSOutlineView started no drag at all, so drag-and-drop never ran.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(node.url.absoluteString, forType: Self.draggedFileURLType)
        return pbItem
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        // Same-outline drags only: identity, not type, because another Goblin Portal
        // window's tree writes the same private type.
        guard info.draggingSource as AnyObject? === outlineView else { return [] }
        let dirNode = dropDirectory(for: item)
        let urls = draggedURLs(info)
        guard !urls.isEmpty, dropRefusal(urls, into: dirNode?.url ?? root.url) == nil else { return [] }
        // Retarget "between rows" and "onto a file" to the folder that actually
        // receives the drop, so the highlight shows where the files will land.
        outlineView.setDropItem(dirNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        guard info.draggingSource as AnyObject? === outlineView, !isEditingInline else { return false }
        let target = dropDirectory(for: item)?.url ?? root.url
        let urls = draggedURLs(info)
        // Re-checked, not trusted from validateDrop: the disk can change mid-drag.
        if let refusal = dropRefusal(urls, into: target) {
            reportFileOpError(refusal, nil); return false
        }
        var last: URL?
        var moves: [(URL, URL)] = []
        for url in urls {
            do {
                // `move(from:to:)` takes the DIRECTORY and appends the name itself.
                try FileOperationPolicy.move(from: url, to: target)
                let finalURL = target.appendingPathComponent(url.lastPathComponent)
                notifyDelegateOfMutation(oldURL: url, newURL: finalURL)
                moves.append((url, finalURL)); last = finalURL
            } catch {
                reportFileOpError("Could not move “\(url.lastPathComponent)”.", error)
            }
        }
        refreshAfterMutation(select: last, rebasing: moves)
        return last != nil
    }

    /// The directory node a drop on `item` lands in: a directory is itself, a file
    /// means its parent, and nil (or a top-level file) means the root, also nil.
    private func dropDirectory(for item: Any?) -> FileNode? {
        guard let node = item as? FileNode else { return nil }
        if node.isDirectory { return node }
        let parent = outlineView.parent(forItem: node) as? FileNode
        return parent === root ? nil : parent
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: Self.draggedFileURLType) }
            .compactMap { URL(string: $0) }
        return topLevel(urls)
    }

    /// Why dropping `urls` into `target` must be refused, or nil if it is fine (S-4).
    /// Both sides are symlink-resolved before comparison, or `/tmp` vs `/private/tmp`
    /// would let a folder be dropped into itself.
    private func dropRefusal(_ urls: [URL], into target: URL) -> String? {
        let dest = resolvedLocation(target)
        for url in urls {
            let src = resolvedLocation(url)
            if FileOperationPolicy.isDescendant(url: dest, of: src) {
                return "Cannot move “\(url.lastPathComponent)” into itself."
            }
            if src.deletingLastPathComponent().path == dest.path {
                return "“\(url.lastPathComponent)” is already in that folder."
            }
            if FileOperationPolicy.isNameTaken(url.lastPathComponent, in: target) {
                return "An item named “\(url.lastPathComponent)” already exists there."
            }
        }
        return nil
    }
}
