//
//  FileTreeViewController+SourceControl.swift
//  Appends the Source Control panel to the sidebar's root NSStackView.
//
//  Why its own file: `FileTreeViewController.swift` is at 343/350 LOC and cannot
//  absorb new code. The seam is clean — sidebar layout augmentation is one whole
//  concern separate from the tree's own data loading, cwd-follow, and filter logic.
//
//  Responsibility split:
//  - `FileTreeViewController+SourceControl.swift` (this file): sidebar layout —
//    appending the panel to the existing stack, pushing git snapshots to the panel.
//  - `SpaceViewController+SourceControl.swift`: panel creation, `SourceControlDelegate`
//    conformance, and diff-tab routing.
//
//  The call site lives in `SpaceViewController`, which holds the panel and owns the
//  delegate. After `viewDidLoad()` has run on the file tree (which builds the stack as
//  a local variable and assigns it to `self.view`), the Space calls
//  `installSourceControlPanel(_:in:)` with the already-created panel and the stack that
//  is now `fileTree.view`. This two-step avoids the file tree needing to know about
//  `SourceControlViewController` at all — it only knows about `NSStackView`.
//
//  Data push path:
//    GitStatusFollow.finish() → FileTreeViewController.gitStatusDidChange()
//                             → [this file] pushSnapshotToSourceControl()
//                             → SpaceViewController.updateSourceControl(snapshot:repository:)
//                             → SourceControlViewController.update(snapshot:repository:)
//
//  This keeps the poller's one snapshot as the single source of truth — one git
//  subprocess read, consumed by both the file tree decorations and the source control
//  panel, with no second read.
//

import AppKit
import ObjectiveC

nonisolated(unsafe) private var scInstalledKey: UInt8 = 0

extension FileTreeViewController {

    // MARK: Panel installation

    /// Append `panel`'s view to the sidebar's root `NSStackView` via `space`.
    ///
    /// Must be called after `loadView()` has run on this controller (i.e. after the
    /// first access to `self.view`), because `loadView()` builds the stack as a
    /// local variable and assigns it to `view` at the end — before that call, `view`
    /// does not exist and accessing it would trigger an unwanted `loadView()`.
    ///
    /// The Space passes itself in as the delegate, which is the only object that can
    /// install the source control panel (it holds the `SourceControlViewController`
    /// and conforms to `SourceControlDelegate`). The file tree stays agnostic about
    /// who is responsible for the panel — it delegates the layout call through the
    /// `space` parameter.
    ///
    /// - Parameters:
    ///   - space: The `SpaceViewController` that owns the panel and the delegate.
    ///            Called to do the actual `stack.addArrangedSubview` work so the
    ///            panel installation logic stays in one place.
    func installSourceControlPanel(from space: SpaceViewController) {
        // Trigger `loadView()` if needed — the first `view` access runs it.
        // After this call, `view` is the NSStackView that `loadView()` built.
        guard let stack = view as? NSStackView else {
            // Should never happen: `loadView()` always sets `view` to an NSStackView.
            // If it somehow does not, fail silently rather than crashing — source
            // control is additive, not load-bearing.
            return
        }
        space.installSourceControl(in: stack)
    }

    // MARK: Git snapshot push

    /// Called from `gitStatusDidChange()` to forward the snapshot to the source
    /// control panel. On first call, also installs the panel into the sidebar stack.
    ///
    /// Walks the delegate chain (`self.delegate` → `SpaceViewController`) to find the
    /// Space. The first time a valid Space is found, the panel is installed into the
    /// sidebar stack. On every call, the latest snapshot is pushed.
    func notifySourceControlOfChange() {
        guard let space = delegate as? SpaceViewController else { return }

        // Lazy install: the first snapshot arrival triggers panel installation.
        if !sourceControlInstalled {
            installSourceControlPanel(from: space)
            sourceControlInstalled = true
        }

        let snapshot = gitFollow?.snapshot ?? .empty
        let repository = gitFollow?.repository
        space.updateSourceControl(snapshot: snapshot, repository: repository)
    }

    /// Whether `installSourceControlPanel(from:)` has run for this tree.
    /// Cannot be a stored property on an extension, but the delegate cast above
    /// guarantees this runs on a concrete `FileTreeViewController`, so we use a
    /// simple associated-object flag.
    private var sourceControlInstalled: Bool {
        get { objc_getAssociatedObject(self, &scInstalledKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &scInstalledKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
