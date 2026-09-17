//
//  DocumentTabStrip+Drag.swift
//  Drag-to-reorder for document tabs.
//
//  Space-level tabs (native NSWindow tabs) get drag-to-reorder free from AppKit.
//  Document tabs do not — they are a hand-rolled strip, so the drag state machine
//  lives here. The visual design roadmap (Tier 1 §4) lists this as a user
//  expectation: "Users expect it."
//
//  Shape: mouseDown captures a candidate index. mouseDragged detects a threshold
//  (4pt) before entering drag mode. While dragging, the strip draws the dragged
//  tab at the cursor position; when the tab's center crosses a neighbour's center,
//  the two swap in the items array and the delegate is told. mouseUp commits.
//
//  The drag state is stored here and read by `+Drawing.swift` (to offset the
//  dragged tab) and `+Mouse.swift` (to suppress hover updates during a drag).
//

import AppKit

/// Drag state for tab reordering. Nil when no drag is in progress.
@MainActor
struct TabDragState {
    /// Index of the tab being dragged (updated as swaps happen).
    var dragIndex: Int
    /// The x-coordinate where the drag started (in strip coordinates).
    let originX: CGFloat
    /// Current x-offset from the tab's natural position.
    var offsetX: CGFloat = 0
}

extension DocumentTabStrip {

    /// Begin tracking a potential drag. Called from `mouseDown` in `+Mouse.swift`
    /// when the click lands on a tab (not the close box, not a button).
    func dragBegin(index: Int, locationX: CGFloat) {
        dragCandidate = (index: index, startX: locationX)
    }

    /// Cancel any in-progress or pending drag without committing.
    func dragCancel() {
        dragCandidate = nil
        if dragState != nil {
            dragState = nil
            needsDisplay = true
        }
    }

    /// Process a mouseDragged event. Promotes the candidate to a live drag once
    /// the threshold is exceeded, then tracks the tab under the cursor.
    func dragUpdate(locationX: CGFloat) {
        // Phase 1: candidate -> live drag once threshold exceeded.
        if let candidate = dragCandidate, dragState == nil {
            let delta = abs(locationX - candidate.startX)
            guard delta > 4 else { return }
            dragState = TabDragState(dragIndex: candidate.index, originX: candidate.startX)
            dragCandidate = nil
        }

        guard var state = dragState else { return }
        let layout = self.layout

        // The offset is the distance from the tab's natural center to the cursor.
        guard let naturalRect = tabRect(state.dragIndex, layout) else { return }
        state.offsetX = locationX - naturalRect.midX

        // Swap detection: if the dragged tab's displaced center crosses a
        // neighbour's natural center, swap them.
        let displacedCenter = naturalRect.midX + state.offsetX

        // Check left neighbour.
        let leftIndex = state.dragIndex - 1
        if leftIndex >= 0, let leftRect = tabRect(leftIndex, layout) {
            if displacedCenter < leftRect.midX {
                swapItems(leftIndex, state.dragIndex)
                state.dragIndex = leftIndex
            }
        }
        // Check right neighbour.
        let rightIndex = state.dragIndex + 1
        if rightIndex < items.count, let rightRect = tabRect(rightIndex, layout) {
            if displacedCenter > rightRect.midX {
                swapItems(state.dragIndex, rightIndex)
                state.dragIndex = rightIndex
            }
        }

        dragState = state
        needsDisplay = true
    }

    /// Commit the drag. Tells the delegate the final position and cleans up.
    func dragEnd() {
        dragCandidate = nil
        guard let state = dragState else { return }
        dragState = nil
        // The items array was already reordered during swaps — the delegate just
        // needs the final index so it can reorder its own document list to match.
        delegate?.tabStrip(self, didReorder: state.dragIndex)
        needsDisplay = true
    }

    /// Swap two items in the strip's own array. The delegate is NOT told per-swap
    /// (only on dragEnd) because intermediate states are transient — the user sees
    /// the tab sliding, not a series of discrete reorders.
    private func swapItems(_ a: Int, _ b: Int) {
        items.swapAt(a, b)
        // Keep activeIndex in sync: if the active tab was one of the swapped pair,
        // its index just changed.
        if activeIndex == a { activeIndex = b }
        else if activeIndex == b { activeIndex = a }
    }
}
