//
//  SymbolOutlinePanel.swift
//  The floating ⌘⇧O symbol-jump panel for the file viewer.
//
//  Extracted from `SymbolOutline.swift` when that file reached 438 LOC, over the
//  350-line ceiling. The seam is clean:
//
//    · `SymbolOutline.swift` — pure data: the `Symbol` model, `SymbolKind`, and
//      the `extractSymbols(from:family:)` regex engine. No AppKit.
//    · `SymbolOutlinePanel.swift` — AppKit panel: the floating NSPanel, search
//      field, table view, keyboard navigation, and row rendering.
//
//  `SymbolOutlinePanel` is driven by `FileViewerPane+Folding.swift` via
//  `showSymbolOutline(_:)`, which calls `SymbolOutlinePanel.init(pane:symbols:)`
//  then `show(relativeTo:)`.
//

import AppKit

// MARK: - Panel

/// A floating, keyboard-driven ⌘⇧O panel that lists symbols extracted from the
/// currently-open file and jumps to the selected one when Enter or click fires.
///
/// Lifecycle: created on demand and stored weakly on the FileViewerPane (via
/// `+Folding`'s stored-property workaround). Dismissed on Escape or on any click
/// that resolves a line, and destroyed with the pane.
@MainActor
final class SymbolOutlinePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                NSSearchFieldDelegate, NSWindowDelegate {

    // The pane that owns this panel — used to call `scrollToLine(_:)`.
    private weak var pane: FileViewerPane?

    private let window: NSPanel
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    /// Full symbol list from the current file.
    private var allSymbols: [Symbol] = []
    /// Filtered subset matching the current search query.
    private var filteredSymbols: [Symbol] = []

    init(pane: FileViewerPane, symbols: [Symbol]) {
        self.pane = pane
        self.allSymbols = symbols
        self.filteredSymbols = symbols

        let panelWidth: CGFloat = 440
        let panelHeight: CGFloat = 320
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.title = "Jump to Symbol"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        // macOS 26+: clear background lets the glass material show through the
        // titled panel chrome. Pre-26: opaque system colour, same as before.
        if #available(macOS 26, *) {
            window.backgroundColor = .clear
        } else {
            window.backgroundColor = NSColor.windowBackgroundColor
        }
        window.level = .floating

        super.init()
        window.delegate = self

        buildLayout(width: panelWidth, height: panelHeight)
        filter(query: "")
    }

    /// Show the panel centered on the pane's window.
    func show(relativeTo sourceWindow: NSWindow) {
        let origin = sourceWindow.frame.center
        let panelSize = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: origin.x - panelSize.width / 2,
            y: origin.y - panelSize.height / 2 + 60))
        window.makeKeyAndOrderFront(nil)
        sourceWindow.addChildWindow(window, ordered: .above)
        // Select all text in the search field so typing replaces it.
        searchField.selectText(nil)
    }

    // MARK: - Layout

    private func buildLayout(width: CGFloat, height: CGFloat) {
        guard let content = window.contentView else { return }

        // Search field at top.
        let fieldH: CGFloat = 36
        searchField.frame = NSRect(x: 12, y: height - fieldH - 12, width: width - 24, height: fieldH)
        searchField.autoresizingMask = [.width, .minYMargin]
        searchField.placeholderString = "Filter symbols…"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        content.addSubview(searchField)

        // Table view in a scroll view below.
        let tableY: CGFloat = 8
        let tableH = height - fieldH - 12 - 8 - tableY
        scrollView.frame = NSRect(x: 0, y: tableY, width: width, height: tableH)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("symbol"))
        col.title = ""
        col.isEditable = false
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 24
        tableView.selectionHighlightStyle = .sourceList
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.target = self
        scrollView.documentView = tableView
        content.addSubview(scrollView)
    }

    // MARK: - Filtering

    private func filter(query: String) {
        if query.isEmpty {
            filteredSymbols = allSymbols
        } else {
            let q = query.lowercased()
            filteredSymbols = allSymbols.filter { $0.name.lowercased().contains(q) }
        }
        tableView.reloadData()
        if !filteredSymbols.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Jump

    private func jumpToSelected() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredSymbols.count else { return }
        let sym = filteredSymbols[row]
        pane?.scrollToLine(sym.line)
        dismiss()
    }

    func dismiss() {
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { filteredSymbols.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            cell.textField = tf
            cell.addSubview(tf)
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleAxesIndependently
            cell.imageView = icon
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),
                tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        guard row < filteredSymbols.count else { return cell }
        let sym = filteredSymbols[row]
        // Format: "name  ·  Ln N"
        let lineTag = "  ·  Ln \(sym.line)"
        let combined = sym.name + lineTag
        let attributed = NSMutableAttributedString(string: combined)
        let nameRange = NSRange(location: 0, length: (sym.name as NSString).length)
        let tagRange = NSRange(location: nameRange.length, length: (lineTag as NSString).length)
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: nameRange)
        attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: tagRange)
        attributed.addAttribute(
            .font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            range: NSRange(location: 0, length: attributed.length))
        cell.textField?.attributedStringValue = attributed
        cell.imageView?.image = symbolImage(for: sym.kind)
        return cell
    }

    private func symbolImage(for kind: SymbolKind) -> NSImage? {
        let name: String
        switch kind {
        case .function: name = "function"
        case .method:   name = "function"
        case .type:     name = "square.3.layers.3d"
        case .property: name = "p.circle"
        case .heading:  name = "text.alignleft"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // No-op — jump on double-click or Enter, not single-click, to allow
        // keyboard browsing without repositioning the cursor on every arrow press.
    }

    @objc private func rowDoubleClicked() { jumpToSelected() }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        filter(query: searchField.stringValue)
    }

    // Enter in the search field or the table jumps to selected.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            jumpToSelected()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        // Forward arrow keys to the table so the user can navigate with the keyboard
        // while the search field is focused.
        if selector == #selector(NSResponder.moveDown(_:)) {
            let next = min(tableView.selectedRow + 1, filteredSymbols.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
            return true
        }
        if selector == #selector(NSResponder.moveUp(_:)) {
            let prev = max(tableView.selectedRow - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            tableView.scrollRowToVisible(prev)
            return true
        }
        return false
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Auto-dismiss when the panel loses focus (e.g. user clicked elsewhere).
        dismiss()
    }
}

// MARK: - NSRect convenience

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
