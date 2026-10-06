//
//  SidebarActivitySwitcher.swift
//  A two-button strip that switches the sidebar between Explorer and SCM views.
//
//  Installed at the top of the sidebar's NSStackView by
//  `SpaceViewController+SidebarActivity.swift`. Hidden entirely when no git
//  repository is active in the Space. The badge overlaid on the SCM button
//  shows the count of changed files (dirty + untracked).
//
//  Pure AppKit — no Foundation imports beyond what AppKit already brings.
//

import AppKit

/// A horizontal two-button strip: Explorer (folder icon) | SCM (branch icon).
///
/// The selected button appears in an `.on` push state; the other is `.off`.
/// A small badge in the SCM button corner shows the changed-file count when > 0.
final class SidebarActivitySwitcher: NSView {

    // MARK: - Public API

    enum Activity { case explorer, scm }

    /// The currently selected activity. Updated by `configure(explorerSelected:)`.
    private(set) var selectedActivity: Activity = .explorer

    /// Switch visual selected state. Does NOT call `onSelect`.
    func configure(explorerSelected: Bool) {
        selectedActivity = explorerSelected ? .explorer : .scm
        explorerButton.state = explorerSelected ? .on : .off
        scmButton.state      = explorerSelected ? .off : .on
    }

    /// Update the SCM badge. Badge hidden when `count == 0`.
    func updateBadge(count: Int) {
        badge.isHidden = count == 0
        badge.stringValue = count > 99 ? "99+" : "\(count)"
    }

    /// Called when the user taps a button. Set by the installing controller.
    var onSelect: ((Activity) -> Void)?

    // MARK: - Subviews

    private let explorerButton = NSButton()
    private let scmButton      = NSButton()
    private let badge          = NSTextField(labelWithString: "")

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        configureButton(explorerButton,
                        symbolName: "folder",
                        tooltip: "Explorer (⌘⇧E)",
                        action: #selector(tappedExplorer))
        configureButton(scmButton,
                        symbolName: "arrow.triangle.branch",
                        tooltip: "Source Control (⌃⇧G)",
                        action: #selector(tappedSCM))

        explorerButton.state = .on
        scmButton.state      = .off

        setupBadge()

        let stack = NSStackView(views: [explorerButton, scmButton])
        stack.orientation  = .horizontal
        stack.spacing      = 0
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(badge)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),

            badge.trailingAnchor.constraint(equalTo: scmButton.trailingAnchor, constant: -4),
            badge.topAnchor.constraint(equalTo: scmButton.topAnchor, constant: 2),
        ])
    }

    private func configureButton(_ button: NSButton, symbolName: String,
                                 tooltip: String, action: Selector) {
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.image             = img
        button.imageScaling      = .scaleProportionallyDown
        button.bezelStyle        = .texturedRounded
        button.setButtonType(.toggle)
        button.toolTip           = tooltip
        button.target            = self
        button.action            = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupBadge() {
        badge.font            = .systemFont(ofSize: 9, weight: .semibold)
        badge.textColor       = .white
        badge.backgroundColor = .systemBlue
        badge.drawsBackground = true
        badge.isEditable      = false
        badge.isSelectable    = false
        badge.isBezeled       = false
        badge.alignment       = .center
        badge.isHidden        = true
        badge.wantsLayer      = true
        badge.layer?.cornerRadius = 6
        badge.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Actions

    @objc private func tappedExplorer() {
        configure(explorerSelected: true)
        onSelect?(.explorer)
    }

    @objc private func tappedSCM() {
        configure(explorerSelected: false)
        onSelect?(.scm)
    }
}
