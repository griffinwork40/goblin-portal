//
//  SpaceViewController+FileMutation.swift
//  Handles `fileTree(_:didMutate:newURL:)` — the delegate callback that fires when
//  the file tree renames, moves, or trashes a path.
//
//  WHY THIS IS A SEPARATE FILE. The concern was extracted from
//  `SpaceViewController+Delegates.swift` (which reached the 350-LOC ceiling once the
//  corrected logic was added) and from the fix for a correctness bug documented below.
//
//  THE BUG (PR #157 finding). The original code called `closeDocument(at: idx)` BEFORE
//  `openFile(url: dest)`. If the matched pane was the Space's only document,
//  `closeDocument` emptied `documents[]`, which triggered
//  `spaceDelegate?.spaceViewControllerDidCloseLastDocument(self)`, which closed the
//  window — so renaming or trashing the sole open file destroyed the whole Space
//  (SpaceWindowController.swift:286-289, SpaceViewController.swift:253-255).
//
//  THE FIX. Two cases:
//
//  - Rename / move (`newURL != nil`): open at the rebased destination FIRST, then
//    close the old tab. The new tab is always present before the old one goes away, so
//    `documents[]` never empties and the Space survives. Tab order is then restored by
//    re-ordering the now-appended new tab back to the original index.
//
//  - Trash (`newURL == nil`): skip close when the pane is the Space's only document.
//    Leaving an orphan-URL tab open is the same contract already applied to dirty
//    panes — surprising on its own, but far less surprising than the window vanishing.
//    When other documents exist the tab is closed normally.
//

import AppKit

extension SpaceViewController {

    // Called by `SpaceViewController+Delegates.swift` (the FileTreeViewControllerDelegate
    // conformance) to keep the conformance extension thin and the logic here auditable.
    func handleFileMutation(oldURL: URL, newURL: URL?) {
        // Resolve symlinks on the source URL once — /tmp and /private/tmp must
        // be treated as the same path (H6).
        let resolvedOld = oldURL.resolvingSymlinksInPath()
        var dirtyNames: [String] = []

        // Collect matched panes first to avoid mutating documents[] mid-iteration.
        // Each entry is (viewer, rebased destination URL or nil for trash).
        var matched: [(viewer: FileViewerPane, dest: URL?)] = []
        for document in documents {
            guard let viewer = document as? FileViewerPane else { continue }
            let resolvedViewer = viewer.url.resolvingSymlinksInPath()
            // Match an exact rename/trash OR any file inside a renamed directory.
            let isExact = resolvedViewer == resolvedOld
            let isChild = !isExact && FileOperationPolicy.isDescendant(
                url: resolvedViewer, of: resolvedOld)
            guard isExact || isChild else { continue }

            if let newURL {
                // Rebase: for an exact match the destination is newURL itself;
                // for a descendant, append the relative path suffix.
                if isExact {
                    matched.append((viewer, newURL))
                } else {
                    // Compute the path suffix after oldURL and graft it onto newURL.
                    let oldPath = resolvedOld.path
                    let viewPath = resolvedViewer.path
                    let suffix = String(viewPath.dropFirst(oldPath.count))
                    let rebased = URL(fileURLWithPath: newURL.path + suffix)
                    matched.append((viewer, rebased))
                }
            } else {
                matched.append((viewer, nil))
            }
        }

        for (viewer, dest) in matched {
            if viewer.isDirty {
                // Never close a dirty pane — that path offers Save/Cancel which
                // would write to the now-invalid old path. Just inform the user.
                dirtyNames.append(viewer.url.lastPathComponent)
                continue
            }
            guard let idx = documents.firstIndex(where: { $0 === viewer }) else { continue }

            if let dest {
                // Rename / move path: open the replacement BEFORE closing the original.
                //
                // Opening first means documents[] is never empty between the two
                // operations, so `closeDocument` cannot trigger
                // `spaceViewControllerDidCloseLastDocument` and close the window
                // (SpaceViewController.swift:253-255). The new tab lands at
                // documents.endIndex; we reorder it back to `idx` afterwards.
                openFile(url: dest)
                // `openFile` appended; `idx` is still valid for the original viewer
                // because no removal has happened yet.
                closeDocument(at: idx)
                // Move the newly-appended tab back to the original position so the
                // tab strip does not jump. After closeDocument the old slot is gone,
                // so the new tab is at documents.count - 1 (endIndex - 1).
                let newIdx = documents.count - 1
                if newIdx != idx && idx <= documents.endIndex {
                    // Re-derive indices from the current array — documents[] was mutated
                    // by selectDocument indirectly. A simple re-order is sufficient;
                    // applyDocumentOrder handles the strip repaint.
                    var reordered = documents
                    let moved = reordered.remove(at: newIdx)
                    reordered.insert(moved, at: min(idx, reordered.endIndex))
                    applyDocumentOrder(reordered, landedAt: min(idx, reordered.indices.last ?? 0))
                }
            } else {
                // Trash path: only close when other documents exist.
                //
                // If this pane is the Space's sole document, closing it would empty
                // documents[] and fire `spaceViewControllerDidCloseLastDocument`, which
                // closes the window (SpaceWindowController.swift:286-289). An orphan-URL
                // tab is the least-surprising outcome — the same contract already applied
                // to dirty panes, which are also deliberately left open after a trash.
                // The user can close the stale tab manually with ⌘W.
                guard documents.count > 1 else { continue }
                closeDocument(at: idx)
            }
        }

        if !dirtyNames.isEmpty {
            let destination: String
            if let newURL {
                destination = newURL.path
            } else {
                destination = "the Trash"
            }
            let names = dirtyNames.joined(separator: "\n• ")
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = dirtyNames.count == 1
                ? "\u{201c}\(dirtyNames[0])\u{201d} has unsaved changes"
                : "\(dirtyNames.count) open files have unsaved changes"
            alert.informativeText = "The file\(dirtyNames.count == 1 ? "" : "s") "
                + "\u{2014} \u{2022} \(names) \u{2014} "
                + "\(dirtyNames.count == 1 ? "was" : "were") moved to \(destination). "
                + "Save or close the tab\(dirtyNames.count == 1 ? "" : "s") manually "
                + "before saving to avoid writing to the old path."
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}
