//
//  SpaceViewController+SourceControl.swift
//  Wires the Source Control sidebar panel into SpaceViewController.
//
//  Three concerns live here:
//  1. Lazy creation and sidebar installation of `SourceControlViewController`.
//  2. The `SourceControlDelegate` conformance — diff-tab opening and re-poll on change.
//  3. `updateSourceControl(snapshot:repository:)`, called by the git poller's
//     `gitStatusDidChange()` path to push fresh data into the panel.
//
//  Why its own file: `SpaceViewController.swift` is at 343/350 LOC and cannot absorb
//  a new concern. The seam is clean — source control is one cohesive concern with no
//  overlap with the container's existing jobs (document management, split layout,
//  config fan-out), and every method here accesses only `internal` members of
//  `SpaceViewController` (`fileTree`, `documents`, `config`, `add(document:)`,
//  `selectDocument(at:)`) that were already promoted to `internal` for analogous
//  extension files (`+DirectoryFollow`, `+DocumentConstruction`, `+Splits`).
//
//  The stored property for the lazy panel is backed by `objc_setAssociatedObject`
//  so that `SpaceViewController.swift` (at 343/350 LOC) does not need to be touched.
//

import AppKit
import ObjectiveC

// MARK: - Associated-object storage key
//
// Swift extensions cannot add stored properties, and SpaceViewController.swift is
// at 343/350 LOC — adding even one `var` line there risks a ceiling violation. The
// standard workaround is `objc_getAssociatedObject` / `objc_setAssociatedObject`,
// which attaches a value to the instance without touching the class declaration.
nonisolated(unsafe) private var sourceControlPanelKey: UInt8 = 0

// MARK: - SourceControlDelegate protocol

/// Actions the source control panel delegates back to its container.
///
/// Two members only, matching the two directions of data flow: user gesture → tab, and
/// data change → re-poll. The panel is the owner of git write operations; the container
/// is the owner of tabs and the git poller.
@MainActor
protocol SourceControlDelegate: AnyObject {
    /// The user clicked a changed file in the source control panel. Open a diff tab.
    func sourceControl(
        _ panel: SourceControlViewController,
        didRequestDiff entry: GitFileEntry,
        staged: Bool)

    /// A git write operation (stage, commit, push, …) completed. Trigger an immediate
    /// git status re-read so the panel reflects the new state within one tick rather
    /// than waiting out the 2s poller interval.
    func sourceControlDidChange(_ panel: SourceControlViewController)
}

// MARK: - SpaceViewController extension

extension SpaceViewController: SourceControlDelegate {

    // MARK: Lazy panel access

    /// The source control panel, created once and reused.
    ///
    /// Stored via `objc_setAssociatedObject` because Swift extensions cannot add
    /// stored properties, and `SpaceViewController.swift` is at 343/350 LOC.
    var sourceControlPanel: SourceControlViewController {
        if let existing = objc_getAssociatedObject(self, &sourceControlPanelKey) as? SourceControlViewController {
            return existing
        }
        let panel = SourceControlViewController()
        panel.delegate = self
        objc_setAssociatedObject(self, &sourceControlPanelKey, panel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return panel
    }

    // MARK: Sidebar installation

    /// Append the source control panel to the sidebar's root `NSStackView`.
    ///
    /// Called from `FileTreeViewController+SourceControl.swift` after the file tree's
    /// `loadView()` has run and the stack exists. Adds a 1pt section divider with a
    /// "SOURCE CONTROL" label above the panel's view, matching the sidebar section
    /// header pattern used by VS Code and consistent with `GitBranchHeaderView`'s
    /// role at the top of the stack.
    ///
    /// Layout contract after this call:
    ///   stack
    ///   ├── GitBranchHeaderView    (.required vertical hugging)
    ///   ├── NSSearchField          (.required vertical hugging)
    ///   ├── NSScrollView           (.defaultLow — fills remaining space)
    ///   ├── SourceControlDivider   (.required vertical hugging, 28pt)
    ///   └── SourceControlViewController.view  (.defaultLow — can grow)
    ///
    /// The file tree's `.defaultLow` hugging means it still wins the extra space in
    /// a tall sidebar; both sections can grow in a very tall window.
    func installSourceControl(in stack: NSStackView) {
        let divider = makeSourceControlDivider()
        divider.setContentHuggingPriority(.required, for: .vertical)

        let panel = sourceControlPanel
        addChild(panel)

        // The panel's view gets .defaultLow hugging so it can shrink to a sensible
        // floor (set via a height constraint in SourceControlViewController itself)
        // without forcing the file tree to give up space it already has.
        panel.view.setContentHuggingPriority(.defaultLow, for: .vertical)

        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(panel.view)

        // 150pt minimum height keeps the commit input and at least a few file rows
        // visible even in a narrow sidebar. The panel can grow beyond this — the
        // stack distributes any remaining height between the two .defaultLow views.
        panel.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    // MARK: SourceControlDelegate

    /// Open a diff tab for `entry`, staged or unstaged.
    ///
    /// Follows the `openFile(url:)` pattern exactly: checks for an existing diff tab
    /// for the same (path, staged) combination and surfaces it, or creates a new one.
    /// A user clicking the same changed file twice should not open two identical tabs.
    func sourceControl(
        _ panel: SourceControlViewController,
        didRequestDiff entry: GitFileEntry,
        staged: Bool
    ) {
        // Surface an existing tab for this (path, staged) pair if one exists.
        if let index = documents.firstIndex(where: { doc in
            guard let diff = doc as? DiffViewerPane else { return false }
            return diff.filePath == entry.path && diff.staged == staged
        }) {
            selectDocument(at: index)
            return
        }

        // No existing tab — build one. Requires a live repository.
        guard let repo = fileTree.gitFollow?.repository else { return }
        let pane = DiffViewerPane(
            filePath: entry.path, staged: staged, repository: repo, config: config)
        add(document: pane)
    }

    /// An operation mutated git state — re-read immediately.
    ///
    /// The 2s poller keeps the panel current during normal use; this call closes
    /// the latency gap after a write operation so the user sees the result of
    /// staging or committing within one update rather than up to 2s later.
    func sourceControlDidChange(_ panel: SourceControlViewController) {
        fileTree.gitFollowPollNow()
    }

    // MARK: Data push from the git poller

    /// Push a fresh git snapshot into the source control panel.
    ///
    /// Called from `FileTreeViewController+SourceControl.swift` whenever the git
    /// poller's `gitStatusDidChange()` fires, immediately after it repaints the
    /// file tree decorations. The panel receives the same snapshot the tree just
    /// consumed — one read, two consumers, no second subprocess.
    ///
    /// `repository` is passed alongside the snapshot because the panel needs it
    /// to build the `GitOperations` call-sites (stage, unstage, commit, etc.) and
    /// to construct `DiffViewerPane` instances on demand.
    func updateSourceControl(snapshot: GitStatusSnapshot, repository: GitRepository?) {
        // The panel is created lazily; calling `sourceControlPanel` here guarantees
        // it exists before the first data push, without forcing creation on every
        // `gitStatusDidChange` when the panel has never been opened.
        sourceControlPanel.update(snapshot: snapshot, repository: repository)
    }

    // MARK: Private helpers

    /// A 28pt header view: a 1pt separator line on top, then a left-inset
    /// "SOURCE CONTROL" label in the system secondary label colour.
    ///
    /// Kept private because it is layout plumbing — only `installSourceControl`
    /// calls it, and the divider has no identity outside this one call site.
    private func makeSourceControlDivider() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "SOURCE CONTROL")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(line)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),

            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),

            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 4),
        ])

        return container
    }
}
