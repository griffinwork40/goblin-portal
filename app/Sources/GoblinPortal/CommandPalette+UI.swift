//
//  CommandPalette+UI.swift
//  Delegate conformances and the row view for the ⌘⇧P command palette.
//
//  Extracted from `CommandPalette.swift` when that file reached 400 LOC, over
//  the 350-line ceiling. The seam is clean:
//
//    · `CommandPalette.swift` — panel construction, show/hide, filtering, execution.
//    · `CommandPalette+UI.swift` — NSTableView/Search/Window delegate conformances
//      and `PaletteRowView` (the single-row cell with title + key-hint labels).
//
//  `PaletteRowView` is `fileprivate` in its own file but needs to be referenced
//  by `CommandPalette.tableView(_:viewFor:row:)` in the other file; Swift's
//  access control is file-scoped, so it is declared `internal` here so the
//  companion file can reach it within the same module.
//

import AppKit

// MARK: - NSTableViewDataSource / Delegate

extension CommandPalette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let cmd = filtered[row]

        let id = NSUserInterfaceItemIdentifier("PaletteRow")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? PaletteRowView
        if cell == nil {
            cell = PaletteRowView()
            cell?.identifier = id
        }
        cell?.configure(title: cmd.title, key: cmd.keyHint)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // No side effects needed — selection alone is enough.
    }
}

// MARK: - NSSearchFieldDelegate (key interception)

extension CommandPalette: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        // Use `self.tableView` to avoid shadowing by the delegate method name.
        let tv = self.tableView
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let next = min((tv?.selectedRow ?? 0) + 1, filtered.count - 1)
            tv?.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tv?.scrollRowToVisible(next)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            let prev = max((tv?.selectedRow ?? 0) - 1, 0)
            tv?.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            tv?.scrollRowToVisible(prev)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitSelection(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }
}

// MARK: - NSPanelDelegate

extension CommandPalette: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // Auto-dismiss when the user clicks elsewhere.
        panel?.orderOut(nil)
    }
}

// MARK: - Row view

/// A single row in the command palette: title on the left, key hint on the right.
@MainActor
final class PaletteRowView: NSTableRowView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        addSubview(titleLabel)
        addSubview(keyLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: keyLabel.leadingAnchor, constant: -8),
            keyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            keyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, key: String) {
        titleLabel.stringValue = title
        keyLabel.stringValue = key
    }

    // Selection background is drawn by NSTableView; dim text on selection.
    override var isSelected: Bool {
        didSet { titleLabel.textColor = isSelected ? .white : .labelColor
                 keyLabel.textColor   = isSelected ? .white.withAlphaComponent(0.7) : .secondaryLabelColor }
    }
}
