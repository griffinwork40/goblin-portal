//
//  SourceControlViewController+DataSource.swift
//  NSOutlineViewDataSource + NSOutlineViewDelegate for the Source Control panel.
//
//  Separate from the main controller file to keep both under 350 LOC.  The
//  outline view has an unusual structure: group items are plain `String` section
//  headers, and leaf items are `GitFileEntry` values.  The delegate builds each
//  cell from scratch (no .xib, no prototype cell) following the same programmatic
//  discipline as the rest of the app.
//
//  Section header rows include hover-reveal stage-all / unstage-all buttons built
//  via `SourceControlSectionHeaderView`.  Leaf rows use `SourceControlRowView` for
//  the per-file hover-reveal action buttons.
//

import AppKit

// MARK: - Section header cell

/// A cell view used for the group-row headers ('Staged Changes', 'Changes', 'Untracked').
/// Shows a label + file count and, on hover, small stage-all / unstage-all buttons.
final class SourceControlSectionHeaderView: NSTableCellView {

    private let titleLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font      = .systemFont(ofSize: 11, weight: .semibold)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let countLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font      = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        f.textColor = .tertiaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    /// Action button shown on hover, role determined by caller.
    private let actionButton: NSButton = {
        let b = NSButton(title: "", target: nil, action: nil)
        b.bezelStyle    = .inline
        b.imagePosition = .imageOnly
        b.isBordered    = false
        b.alphaValue    = 0
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)

        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 16),
            actionButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    /// Configure the header for a given section. `target` and `action` drive the action button.
    func configure(
        title: String,
        count: Int,
        buttonSymbol: String?,
        buttonTooltip: String?,
        target: AnyObject?,
        action: Selector?
    ) {
        titleLabel.stringValue = title
        countLabel.stringValue = count > 0 ? "(\(count))" : ""

        if let sym = buttonSymbol, let act = action {
            let img = NSImage(systemSymbolName: sym, accessibilityDescription: buttonTooltip)
            img?.isTemplate = true
            actionButton.image   = img
            actionButton.toolTip = buttonTooltip
            actionButton.target  = target
            actionButton.action  = act
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { actionButton.alphaValue = 1 }
    override func mouseExited(with event: NSEvent)  { actionButton.alphaValue = 0 }
}

// MARK: - Leaf cell

/// A plain cell view for individual file entries; the hover action buttons
/// live on `SourceControlRowView` (the row, not the cell).
final class SourceControlFileCellView: NSTableCellView {

    private let icon: NSImageView = {
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let nameLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: 12)
        f.lineBreakMode = .byTruncatingMiddle
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let badge: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font      = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        f.alignment = .center
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(icon)
        addSubview(nameLabel)
        addSubview(badge)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    func configure(entry: GitFileEntry) {
        let filename = (entry.path as NSString).lastPathComponent
        nameLabel.stringValue = filename

        badge.stringValue = entry.status.letter
        badge.textColor   = entry.status.decorationColour

        let img = NSImage(systemSymbolName: "doc", accessibilityDescription: filename)
        img?.isTemplate    = true
        icon.image         = img
        icon.contentTintColor = .secondaryLabelColor
    }
}

// MARK: - NSOutlineViewDataSource

extension SourceControlViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        guard let title = item as? String,
              let sec = section(for: title) else { return 0 }
        return entries(for: sec).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sections[index] }
        guard let title = item as? String,
              let sec = section(for: title) else { return index }
        return entries(for: sec)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is String
    }
}

// MARK: - NSOutlineViewDelegate

extension SourceControlViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is String
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let title = item as? String {
            return headerCell(outlineView, title: title)
        }
        if let entry = item as? GitFileEntry {
            return fileCell(outlineView, entry: entry)
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if item is GitFileEntry {
            return rowView(outlineView, item: item)
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is GitFileEntry
    }

    // MARK: Cell builders

    private func headerCell(_ outlineView: NSOutlineView, title: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("header")
        let cell: SourceControlSectionHeaderView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? SourceControlSectionHeaderView {
            cell = reused
        } else {
            cell = SourceControlSectionHeaderView(frame: .zero)
            cell.identifier = id
        }

        guard let sec = section(for: title) else { return cell }
        let count = entries(for: sec).count

        switch sec {
        case .staged:
            cell.configure(title: title, count: count,
                           buttonSymbol: "minus.circle",
                           buttonTooltip: "Unstage All",
                           target: self, action: #selector(unstageAll(_:)))
        case .changes:
            cell.configure(title: title, count: count,
                           buttonSymbol: "plus.circle",
                           buttonTooltip: "Stage All",
                           target: self, action: #selector(stageAll(_:)))
        case .untracked:
            cell.configure(title: title, count: count,
                           buttonSymbol: "plus.circle",
                           buttonTooltip: "Stage All Untracked",
                           target: self, action: #selector(stageAll(_:)))
        }
        return cell
    }

    private func fileCell(_ outlineView: NSOutlineView, entry: GitFileEntry) -> NSView {
        let id = NSUserInterfaceItemIdentifier("file")
        let cell: SourceControlFileCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? SourceControlFileCellView {
            cell = reused
        } else {
            cell = SourceControlFileCellView(frame: .zero)
            cell.identifier = id
        }
        cell.configure(entry: entry)
        return cell
    }

    private func rowView(_ outlineView: NSOutlineView, item: Any) -> SourceControlRowView {
        let id = NSUserInterfaceItemIdentifier("row")
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? SourceControlRowView {
            if let entry = item as? GitFileEntry {
                reused.configure(entry: entry, controller: self)
            }
            return reused
        }
        let row = SourceControlRowView()
        row.identifier = id
        if let entry = item as? GitFileEntry {
            row.configure(entry: entry, controller: self)
        }
        return row
    }
}

// MARK: - NSMenuDelegate

extension SourceControlViewController: NSMenuDelegate {
    /// Rebuild the context menu just before it is shown, using `clickedRow` to
    /// identify which file entry was right-clicked. This is the correct AppKit
    /// pattern (mirrors FileTreeViewController+ContextMenu.swift): assigning
    /// `outlineView.menu` with a delegate is what triggers right-click menus —
    /// there is no real `NSOutlineViewDelegate.menuFor:` method.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outlineView.clickedRow >= 0,
              let entry = outlineView.item(atRow: outlineView.clickedRow) as? GitFileEntry
        else { return }
        // Resolve the section from the outline view's own parent link rather than
        // relying solely on entry.isStaged. For a partially-staged (MM) file, the
        // same GitFileEntry (with isStaged=true) appears in both the Staged and
        // Changes sections. Without this, contextMenu(for:) branches on isStaged
        // alone and shows "Unstage" for the Changes row — the same fix the
        // double-click handler already applies at SourceControlViewController.swift:279.
        let parentTitle = outlineView.parent(forItem: entry) as? String
        let inStagedSection = parentTitle == SourceControlSection.staged.title
        for item in contextMenu(for: entry, inStagedSection: inStagedSection).items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
    }
}
