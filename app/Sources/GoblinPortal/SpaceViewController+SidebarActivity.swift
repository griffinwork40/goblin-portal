//
//  SpaceViewController+SidebarActivity.swift
//  Owns the activity switcher installation, the Explorer ↔ SCM view-swap logic,
//  badge push from git snapshots, and the two responder-chain actions wired in
//  `AppMenu.swift`.
//
//  The switcher and activity state are stored via `objc_setAssociatedObject` so
//  `SpaceViewController.swift` (at the 350-LOC ceiling) does not need new fields.
//
//  Integration points (written by Wave 3):
//  - `FileTreeViewController+SourceControl.swift` calls `space.installActivitySwitcher(in:)`
//    from `installSourceControlPanel(from:)`.
//  - `SpaceViewController+SourceControl.swift` calls `pushBadgeCount(_:)` and
//    `updateSwitcherVisibility(hasRepo:)` from `updateSourceControl(snapshot:repository:)`.
//

import AppKit
import ObjectiveC

// MARK: - Sidebar activity enum

enum SidebarActivity { case explorer, scm }

// MARK: - Box wrapper for associated-object storage

/// Boxes a value type so it can be stored via `objc_setAssociatedObject`,
/// which requires an `AnyObject`. Swift enums are value types and cannot be
/// stored directly — `objc_getAssociatedObject` would always return `nil`.
private final class Box<T> { var value: T; init(_ v: T) { value = v } }

// MARK: - Associated-object keys

nonisolated(unsafe) private var activitySwitcherKey: UInt8 = 0
nonisolated(unsafe) private var sidebarActivityKey:  UInt8 = 0
nonisolated(unsafe) private var scmPanelKey:         UInt8 = 0
nonisolated(unsafe) private var scmDividerKey:       UInt8 = 0

// MARK: - SpaceViewController extension

extension SpaceViewController {

    // MARK: Computed properties

    /// The activity switcher view, created once on first access.
    var sidebarActivitySwitcher: SidebarActivitySwitcher {
        if let existing = objc_getAssociatedObject(self, &activitySwitcherKey)
                as? SidebarActivitySwitcher { return existing }
        let sw = SidebarActivitySwitcher()
        sw.onSelect = { [weak self] activity in
            self?.switchSidebarActivity(activity == .explorer ? .explorer : .scm)
        }
        objc_setAssociatedObject(self, &activitySwitcherKey, sw, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return sw
    }

    /// Which activity is currently displayed in the sidebar.
    ///
    /// `SidebarActivity` is a Swift value type and cannot be stored directly via
    /// `objc_setAssociatedObject` (which requires `AnyObject`). We box it so the
    /// round-trip through the ObjC bridge works correctly — without the box,
    /// `objc_getAssociatedObject` would always return `nil` and the property
    /// would always read back `.explorer`.
    var currentSidebarActivity: SidebarActivity {
        get { (objc_getAssociatedObject(self, &sidebarActivityKey) as? Box<SidebarActivity>)?.value ?? .explorer }
        set { objc_setAssociatedObject(self, &sidebarActivityKey, Box(newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The SCM panel view controller, stored by `FileTreeViewController+SourceControl.swift`.
    var scmPanelViewController: NSViewController? {
        get { objc_getAssociatedObject(self, &scmPanelKey) as? NSViewController }
        set { objc_setAssociatedObject(self, &scmPanelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The SCM divider view, stored by `FileTreeViewController+SourceControl.swift`.
    var scmDividerView: NSView? {
        get { objc_getAssociatedObject(self, &scmDividerKey) as? NSView }
        set { objc_setAssociatedObject(self, &scmDividerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // MARK: Installation

    /// Insert the switcher at the top of the sidebar stack.
    ///
    /// Called from `FileTreeViewController+SourceControl.swift` after the source
    /// control panel is appended. Inserts above all other arranged subviews.
    func installActivitySwitcher(in stack: NSStackView) {
        let sw = sidebarActivitySwitcher
        stack.insertArrangedSubview(sw, at: 0)
        sw.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sw.setContentHuggingPriority(.required, for: .vertical)
    }

    // MARK: View swap

    /// Switch the sidebar to `activity`, updating the switcher button and hiding/showing views.
    func switchSidebarActivity(_ activity: SidebarActivity) {
        currentSidebarActivity = activity
        sidebarActivitySwitcher.configure(explorerSelected: activity == .explorer)
        if activity == .explorer {
            showExplorerViews()
        } else {
            showSCMViews()
        }
    }

    /// Show the Explorer section (file tree + filter + branch header); hide SCM.
    func showExplorerViews() {
        fileTree.gitHeader.isHidden   = false
        fileTree.filterField.isHidden = false
        fileTree.sidebarScrollView.isHidden = false
        scmPanelViewController?.view.isHidden = true
        scmDividerView?.isHidden = true
    }

    /// Show the SCM section; hide Explorer views.
    func showSCMViews() {
        fileTree.gitHeader.isHidden   = true
        fileTree.filterField.isHidden = true
        fileTree.sidebarScrollView.isHidden = true   // FALSIFICATION TARGET: removing this line
        scmPanelViewController?.view.isHidden = false  // causes check-sidebar-activity case 1 to fail
        scmDividerView?.isHidden = false
    }

    // MARK: Badge

    /// Called from `SpaceViewController+SourceControl.swift` on every git snapshot.
    func pushBadgeCount(_ count: Int) {
        sidebarActivitySwitcher.updateBadge(count: count)
    }

    /// Hide the switcher entirely when there is no repository.
    func updateSwitcherVisibility(hasRepo: Bool) {
        sidebarActivitySwitcher.isHidden = !hasRepo
    }

    // MARK: Responder actions (wired from AppMenu.swift)

    @objc func showExplorerSidebar(_ sender: Any?) {
        revealSidebarIfCollapsed()
        switchSidebarActivity(.explorer)
    }

    @objc func showSourceControlSidebar(_ sender: Any?) {
        revealSidebarIfCollapsed()
        switchSidebarActivity(.scm)
    }

    // MARK: Private helpers

    private func revealSidebarIfCollapsed() {
        guard let item = splitViewItems.first, item.isCollapsed else { return }
        _ = NSApp.sendAction(
            #selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: self)
    }
}
