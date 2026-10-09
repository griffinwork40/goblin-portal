//
//  FileTreeViewController+FollowStatus.swift
//  Installs and drives the DirectoryFollowIndicatorView in the sidebar stack.
//
//  WHY ITS OWN FILE. FileTreeViewController.swift is at the 350-LOC ceiling and cannot
//  absorb new code. The seam is clean: "react to follow-status" is one whole concern
//  orthogonal to tree loading, git decoration, file-op routing, and the filter — each of
//  which lives in its own extension file already.
//
//  RESPONSIBILITY.
//  - Lazy idempotent install of one DirectoryFollowIndicatorView into the sidebar's root
//    NSStackView, via associated-object storage so this extension adds no stored property
//    to the main class. The install pattern mirrors FileTreeViewController+SourceControl.swift
//    (lines 66–86).
//  - `updateDirectoryFollowStatus(_:)` is the single writer: it creates the view if absent,
//    configures it, and shows/hides it. Called by the poller every tick.
//
//  WHERE IT SITS IN THE STACK. Between the git branch header and the filter field —
//  inserted at index 1 (after gitHeader at 0, before filterField). The activity switcher
//  (if installed by SourceControl) sits at index 0 above everything; inserting at 1 keeps
//  the indicator below any switcher and above the tree content.
//
//  SOURCE CONTROL VIEW. When `chromeSuppressed` is true on the git header (set by
//  SpaceViewController+SidebarActivity.showSCMViews()), the indicator is also hidden.
//  The SCM panel replaces the Explorer tree entirely; a cwd-follow note is meaningless
//  there and would confuse more than inform.
//
//  IDEMPOTENCY. The install guard (IDEMPOTENT_INSTALL_GUARD comment) ensures a second
//  call updates the existing view in place rather than appending a new one. This is the
//  invariant case 7 of check-directory-indicator.sh verifies.
//

import AppKit
import ObjectiveC

// MARK: - Associated-object key

nonisolated(unsafe) private var followIndicatorKey: UInt8 = 0

// MARK: - Internal accessor (shared with the harness via @testable import)

/// Returns the currently installed indicator view for `tree`, or nil if none exists.
/// Exposed at internal level so check-directory-indicator-harness.swift can read it
/// without going through UI-level view walking.
func followIndicatorView(on tree: FileTreeViewController) -> DirectoryFollowIndicatorView? {
    objc_getAssociatedObject(tree, &followIndicatorKey) as? DirectoryFollowIndicatorView
}

// MARK: - FileTreeViewController extension

extension FileTreeViewController {

    // MARK: Public API (called by the poller)

    /// Update the indicator to reflect `status`.
    ///
    /// Idempotent: calling this many times with the same status is a no-op beyond the
    /// first call. Calling it with different statuses updates in place — the same single
    /// view, never a second one. This is the only path that writes the indicator's state.
    ///
    /// Hides the indicator when `gitHeader.chromeSuppressed` is true (SCM view active)
    /// because the Explorer tree is hidden in that mode and a cwd note there is confusing.
    func updateDirectoryFollowStatus(_ status: DirectoryFollowStatus) {

        // IDEMPOTENT_INSTALL_GUARD — if already installed, update in place.
        if let existing = followIndicatorView(on: self) {
            updateExistingFollowIndicator(existing, status: status)
            return
        }

        // Not yet installed: only install when the status warrants a visible note.
        // For .local and .unavailable we skip install entirely — no-op is correct:
        // the indicator does not exist yet, so there is nothing to hide.
        switch status {
        case .local, .unavailable: return
        case .remote, .paused: break
        }

        // Lazy install into the sidebar's root NSStackView.
        guard let stack = view as? NSStackView else {
            // Should never happen: loadView always sets view to an NSStackView.
            // Failing silently preserves the tree's function even if the indicator
            // cannot be installed (additive concern, not load-bearing).
            return
        }

        let indicator = DirectoryFollowIndicatorView()
        objc_setAssociatedObject(
            self, &followIndicatorKey, indicator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Insert after the git header (index 0) so git → indicator → filter → tree.
        // The activity switcher (if installed) sits at index 0 and pushes everything down;
        // inserting at 1 is correct regardless because NSStackView renumbers on insert.
        let insertAt = min(1, stack.arrangedSubviews.count)
        stack.insertArrangedSubview(indicator, at: insertAt)
        indicator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        indicator.setContentHuggingPriority(.required, for: .vertical)

        updateExistingFollowIndicator(indicator, status: status)
    }

    // MARK: Private helper

    private func updateExistingFollowIndicator(
        _ indicator: DirectoryFollowIndicatorView,
        status: DirectoryFollowStatus
    ) {
        // In SCM view (chromeSuppressed), always hide — the Explorer tree is not visible.
        if gitHeader.chromeSuppressed {
            indicator.isHidden = true
            return
        }
        indicator.configure(status: status)
    }
}
