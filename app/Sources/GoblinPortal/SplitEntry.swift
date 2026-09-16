//
//  SplitEntry.swift
//  The data model for a split-peer relationship within one tab.
//
//  Its own file for two reasons. First, SpaceViewController.swift is at the 350-LOC
//  ceiling and cannot absorb a new type. Second, the struct is the seam between
//  +Splits.swift (which writes it), +Closing.swift (which tears it down), and
//  ShellHosting.swift (which queries it for focused-shell resolution) -- a shared
//  type in its own file is readable from all three without coupling them.
//
//  v2 model: a primary document may have a split peer, AND that peer may itself be
//  split into two sub-peers inside a nested SplitContainerView. This gives up to
//  4 panes per tab (quarters) with depth capped at 2. The nested container holds
//  two sub-peer documents and its own direction, independent of the outer split.
//

import AppKit

/// One split-peer entry, keyed by its primary document's `ObjectIdentifier` in
/// `SpaceViewController.splitPeers`.
///
/// v1 was a plain tuple `(document, direction)`. v2 adds an optional `subSplit`
/// that tracks a second level of nesting: the primary itself may be split (via
/// `primarySubSplit`), and the peer may be split (via `peerSubSplit`). Each sub-split
/// creates a nested `SplitContainerView` that replaces the leaf pane's slot in the
/// outer container.
@MainActor
struct SplitEntry {
    let document: SpaceDocument
    let direction: SplitContainerView.Direction

    /// Sub-split of the PRIMARY pane (left/top in the outer split).
    var primarySubSplit: SubSplit?
    /// Sub-split of the PEER pane (right/bottom in the outer split).
    var peerSubSplit: SubSplit?

    /// A second-level split inside one half of the outer split.
    struct SubSplit {
        let document: SpaceDocument
        let container: SplitContainerView
        let direction: SplitContainerView.Direction
    }

    /// Every peer document in this entry (the main peer + any sub-split documents).
    var allPeerDocuments: [SpaceDocument] {
        var result = [document]
        if let sub = primarySubSplit { result.append(sub.document) }
        if let sub = peerSubSplit { result.append(sub.document) }
        return result
    }

    /// How many panes this tab currently has (including the primary).
    /// 2 = simple split, 3 = one sub-split, 4 = both sub-splits (quarters).
    var paneCount: Int {
        2 + (primarySubSplit != nil ? 1 : 0) + (peerSubSplit != nil ? 1 : 0)
    }
}
