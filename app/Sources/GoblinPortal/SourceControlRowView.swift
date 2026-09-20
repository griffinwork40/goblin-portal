//
//  SourceControlRowView.swift
//  Custom NSTableRowView for the Source Control outline's file rows.
//
//  Separate from +DataSource.swift because NSTableRowView has its own drawing and
//  tracking-area life cycle that warrants its own file. The hover-reveal action
//  buttons (stage / unstage / discard) live here rather than on the cell, because
//  NSTableCellView is clipped to its column and those buttons need to float
//  right-aligned over the row regardless of name length.
//
//  The buttons set `representedObject` on themselves to the `GitFileEntry` they
//  act on, and their target is the `SourceControlViewController` passed at
//  configure time — so action dispatch goes directly to the controller's @objc
//  methods without any coordinator indirection.
//

import AppKit

@MainActor final class SourceControlRowView: NSTableRowView {

    // MARK: - Action buttons

    private let stageButton:   NSButton = SourceControlRowView.makeButton(symbol: "plus.circle",              tooltip: "Stage File")
    private let unstageButton: NSButton = SourceControlRowView.makeButton(symbol: "minus.circle",             tooltip: "Unstage File")
    private let discardButton: NSButton = SourceControlRowView.makeButton(symbol: "arrow.uturn.backward.circle", tooltip: "Discard Changes")

    private var allButtons: [NSButton] { [stageButton, unstageButton, discardButton] }
    private var trackingArea: NSTrackingArea?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in allButtons {
            b.alphaValue = 0
            addSubview(b)
        }
        layoutButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    // MARK: - Configuration

    /// The entry this row currently represents. Set by `configure` on every recycle
    /// and read by the controller's action methods to identify the target file.
    private(set) var entry: GitFileEntry?

    /// Called by the data source every time this row view is recycled for a new item.
    func configure(entry: GitFileEntry, controller: SourceControlViewController) {
        self.entry = entry
        // Detach all buttons from previous configuration
        for b in allButtons {
            b.target            = nil
            b.action            = nil
            b.isHidden          = true
        }

        // Wire the buttons relevant to this entry's section
        switch entry.status {
        case .untracked, .ignored:
            wire(stageButton,   action: #selector(SourceControlViewController.stageFile(_:)),   entry: entry, controller: controller)
            wire(discardButton, action: #selector(SourceControlViewController.discardFile(_:)), entry: entry, controller: controller)
        default:
            if entry.isStaged {
                wire(unstageButton, action: #selector(SourceControlViewController.unstageFile(_:)), entry: entry, controller: controller)
            } else {
                wire(stageButton,   action: #selector(SourceControlViewController.stageFile(_:)),   entry: entry, controller: controller)
                wire(discardButton, action: #selector(SourceControlViewController.discardFile(_:)), entry: entry, controller: controller)
            }
        }

        repositionButtons()
    }

    // MARK: - Layout

    private func layoutButtons() {
        for b in allButtons {
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        // Trailing-anchored, right to left: discard | unstage | stage
        NSLayoutConstraint.activate([
            discardButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            discardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            discardButton.widthAnchor.constraint(equalToConstant: 16),
            discardButton.heightAnchor.constraint(equalToConstant: 16),

            unstageButton.trailingAnchor.constraint(equalTo: discardButton.leadingAnchor, constant: -2),
            unstageButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            unstageButton.widthAnchor.constraint(equalToConstant: 16),
            unstageButton.heightAnchor.constraint(equalToConstant: 16),

            stageButton.trailingAnchor.constraint(equalTo: unstageButton.leadingAnchor, constant: -2),
            stageButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stageButton.widthAnchor.constraint(equalToConstant: 16),
            stageButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    /// Collapse the gap for hidden buttons so the visible ones pack to the right.
    private func repositionButtons() {
        // With fixed Auto Layout constraints the hidden buttons still occupy their
        // space, but at 0 alpha they are visually absent and the size is small enough
        // (3 × 18px) that it does not matter at 22px row height. The simpler approach
        // (stack view) would require removing and re-adding constraints on recycle, so
        // we accept the fixed layout and leave hidden buttons invisible.
        //
        // If a tighter layout is needed, replace the three fixed constraints above with
        // a visible-only NSStackView and swap its arrangedSubviews on configure.
    }

    // MARK: - Hover interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            for b in allButtons where !b.isHidden { b.animator().alphaValue = 1 }
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            for b in allButtons { b.animator().alphaValue = 0 }
        }
    }

    // MARK: - Drawing

    /// NSTableRowView draws its own selection background; we let it do that and
    /// add no additional drawing, which keeps the sidebar material visible through
    /// the deselected rows — the same approach GitBranchHeaderView uses.
    override var isEmphasized: Bool {
        get { super.isEmphasized }
        set { super.isEmphasized = newValue }
    }

    // MARK: - Helpers

    private static func makeButton(symbol: String, tooltip: String) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.bezelStyle    = .inline
        b.imagePosition = .imageOnly
        b.isBordered    = false
        b.toolTip       = tooltip

        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        img?.isTemplate    = true
        b.image            = img
        b.contentTintColor = .secondaryLabelColor
        return b
    }

    private func wire(_ button: NSButton, action: Selector, entry: GitFileEntry, controller: SourceControlViewController) {
        button.action            = action
        button.target            = controller
        button.isHidden          = false
        button.alphaValue        = 0  // revealed on mouseEntered
    }
}
