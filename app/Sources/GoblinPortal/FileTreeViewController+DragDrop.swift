//
//  FileTreeViewController+DragDrop.swift
//  Drag-and-drop conformance for the file tree's NSOutlineView.
//
//  Kept separate from +OutlineView.swift because the data-source callbacks for
//  read/display (numberOfChildren, child, viewFor) are a distinct concern from
//  the three drag-lifecycle callbacks here, and both files would exceed the
//  350-LOC ceiling if merged. The drag methods delegate all filesystem work to
//  FileOperationPolicy so no raw FileManager calls appear here.
//

import AppKit

extension FileTreeViewController {
    // UTType registered in loadView() and written into the drag pasteboard by
    // draggingSession(willBeginAt:forItems:). The system .fileURL type is also
    // registered so Finder → tree drops work without a UTType round-trip.
    static let draggedFileURLType = NSPasteboard.PasteboardType("com.goblinportal.filetree.fileurl")
}

// MARK: - NSOutlineViewDataSource drag methods

extension FileTreeViewController {
    func outlineView(_ outlineView: NSOutlineView,
                     draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        let urls = draggedItems.compactMap { ($0 as? FileNode)?.url }
        session.draggingPasteboard.clearContents()
        session.draggingPasteboard.writeObjects(urls as [NSURL])
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else { return [] }
        // Resolve the proposed drop target to a directory URL.
        let target: URL
        if let node = item as? FileNode {
            target = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        } else {
            target = root.url
        }
        // Reject drops that would create a descendant cycle or a no-op self-move.
        let cycle = urls.contains { FileOperationPolicy.isDescendant(url: target, of: $0) || target == $0 }
        return cycle ? [] : .move
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else { return false }
        let target: URL
        if let node = item as? FileNode {
            target = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        } else {
            target = root.url
        }
        var moved = false
        for url in urls {
            do {
                // FileOperationPolicy.move(from:to:) treats `to` as a directory and
                // appends url.lastPathComponent internally — pass the directory, not the
                // final path. Compute finalURL locally for the delegate notification.
                let finalURL = target.appendingPathComponent(url.lastPathComponent)
                try FileOperationPolicy.move(from: url, to: target)
                notifyDelegateOfMutation(oldURL: url, newURL: finalURL)
                moved = true
            } catch { NSSound.beep() }
        }
        if moved {
            root.reloadChildren()
            outlineView.reloadData()
        }
        return moved
    }
}
