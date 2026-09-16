//
//  SpaceViewController+Closing.swift
//  Closing a whole Space: whether it may, and releasing what its documents hold when it does.
//
//  Its own file because `SpaceViewController.swift` reached 348 lines against a hard 350-line
//  ceiling (`Scripts/check-file-size.sh`) when `tearDownAllDocuments()` landed, and the rule for
//  that is to pull one whole concern out rather than shave comments. This is that concern:
//  Space-level lifecycle, as distinct from the per-document list operations that stay behind.
//
//  WHY `closeDocument(at:)` IS NOT HERE, since it is obviously the same subject. It mutates
//  `documents`, whose setter is deliberately `private` — file-scoped in Swift — so that every
//  write to the document list stays in one file (see the note on `documents` in
//  `SpaceViewController.swift`, which argues the one-writer discipline is the part worth
//  keeping). Moving it would mean widening that setter to `internal(set)` and trading a real
//  invariant for a formatting preference. Everything in THIS file only reads the list, or
//  delegates to a verb that owns the write — which is exactly why this is the half that could
//  move.
//

import AppKit

extension SpaceViewController {
    /// ⌘W routing: if the active tab has a split peer, collapse the split first rather
    /// than closing the tab. Closing the tab when split would discard both panes in one
    /// keystroke, which is one action too many — the user pressed the "close one pane"
    /// chord, not "close the tab and all its panes". The second ⌘W (or ⌘W when unsplit)
    /// reaches the original `closeDocument(at:)` path.
    func closeActiveDocument() {
        if let active = activeDocument, hasSplit(for: active) {
            closeSplitPane()
        } else {
            closeDocument(at: activeIndex)
        }
    }

    /// Can this whole Space go away? Asks each document in turn and stops at the
    /// first refusal, so closing a window with three dirty files prompts three times
    /// rather than discarding the other two behind one answer.
    func spaceShouldClose() -> Bool {
        for document in documents where !document.documentShouldClose() { return false }
        return true
    }

    /// The Space is closing for real (⌘⇧W, or the window's own close button). Release every
    /// document's unmanaged resources.
    ///
    /// This exists because `spaceShouldClose()` above is **veto-only** and nothing else ever
    /// iterated the documents on this path: `windowShouldClose` asked permission,
    /// `windowWillClose` persisted the root list, and the documents themselves were left to
    /// ARC. That was invisible while every document held only AppKit views and a pty the OS
    /// reclaims — and became a real leak once documents held resources that need explicit
    /// teardown (the shell process, for one: SwiftTerm's `terminate()` must send SIGHUP).
    ///
    /// Deliberately NOT routed through `closeDocument(at:)` in a loop. That function re-asks
    /// `documentShouldClose()`, which `spaceShouldClose()` has already asked and had answered
    /// — a second prompt per dirty file on the way out is precisely the bug the single choke
    /// point was built to avoid. It also mutates `documents` while selecting a neighbour and
    /// would fire `spaceViewControllerDidCloseLastDocument` mid-teardown, asking the delegate
    /// to close a window that is already closing.
    func tearDownAllDocuments() {
        // Close split peers first (including any sub-split peers), before their
        // primary documents, so the splitPeers dictionary is cleared while the
        // primary identity is still valid as a key. teardownSplit(for:) is
        // idempotent — tabs without a peer produce the guard-nil early return
        // in +Splits.swift. Sub-split peers are closed inside teardownSplit.
        for document in documents { teardownSplit(for: document) }
        for document in documents { document.documentWillClose() }
    }

    var hasEditedDocuments: Bool { documents.contains { $0.documentIsEdited } }
}
