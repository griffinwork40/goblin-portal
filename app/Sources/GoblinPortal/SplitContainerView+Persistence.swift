//
//  SplitContainerView+Persistence.swift
//  Read and write the divider ratio for split state persistence.
//
//  `SplitContainerView.swift` is at 347/350 LOC, so any API addition goes in
//  an extension file rather than inline. This follows the pattern established
//  by `SpaceViewController+SplitPresentation.swift` and `+SplitFocus.swift`.
//
//  `currentDividerRatio` exposes the ratio for serialization without making it
//  publicly settable (drag remains the only way to change it during normal use).
//  `applyDividerRatio(_:)` sets it and re-runs layout, used only during
//  restoration when replaying a saved split state.
//

import AppKit

extension SplitContainerView {
    /// The current divider position as a fraction of the container, 0...1.
    /// Read-only for serialization; drag and `applyDividerRatio` are the writers.
    var currentDividerRatio: CGFloat { dividerRatio }

    /// Set the divider ratio and re-run layout. Used during split state
    /// restoration to replay a saved position.
    ///
    /// Requires the container to have non-zero bounds (call after
    /// `layoutSubtreeIfNeeded()`). The ratio is clamped to keep both panes
    /// above `minPaneSize` by `layout()` itself, so out-of-range values
    /// degrade rather than break.
    func applyDividerRatio(_ ratio: CGFloat) {
        dividerRatio = ratio
        needsLayout = true
        layout()
    }
}
