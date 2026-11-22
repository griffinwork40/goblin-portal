//
//  FileTreeOutlineView.swift
//  Thin NSOutlineView subclass: routes ⌘⌫, Return, F2 and Escape, and the Edit
//  menu's Cut/Copy/Paste, to the file-ops delegate, leaving everything else to super.
//
//  No logic lives here — only key routing. All file operation logic lives in
//  `FileTreeViewController+FileOps.swift`, which conforms to the protocol below.
//

import AppKit

/// Receives key-routing callbacks from `FileTreeOutlineView`.
///
/// All methods are `@MainActor` because they update UI in response to user events.
/// The protocol is defined here (not in `+FileOps.swift`) to avoid a forward-reference
/// dependency: `FileTreeOutlineView` needs the protocol type before `+FileOps.swift`
/// compiles, but Swift resolves within-module declarations in any order, so the
/// placement is for readability rather than compilation order.
@MainActor
protocol FileTreeOutlineViewKeyDelegate: AnyObject {
    /// ⌘⌫ — Move selected item(s) to Trash.
    func deleteSelectedRows()
    /// Return or F2 while a row is selected but not editing — begin inline rename.
    func beginEditingSelected()
    /// Return while a cell text field is active — commit the current edit.
    func commitEdit()
    /// Escape while a cell text field is active — cancel the current edit.
    func cancelEdit()
    /// True while an inline rename/new-item editor is open.
    var isEditingInline: Bool { get }
    /// True when Cut or Copy has put file URLs on the tree's internal clipboard.
    var hasFileClipboard: Bool { get }
    /// ⌘X / ⌘C / ⌘V, forwarded from the Edit menu through the responder chain.
    func performCut(_ sender: Any?)
    func performCopy(_ sender: Any?)
    func performPaste(_ sender: Any?)
}

/// `NSOutlineView` subclass that routes file-operation key events to a typed delegate.
///
/// Kept intentionally thin: the only override is `keyDown(with:)`. Callers that need
/// the standard key behaviour (arrow navigation, space-bar selection, etc.) get it
/// from `super.keyDown(with:)` on the else path.
final class FileTreeOutlineView: NSOutlineView {
    /// The file-operations delegate. Set by `FileTreeViewController+FileOps.swift`.
    weak var fileOpsDelegate: FileTreeOutlineViewKeyDelegate?

    override func keyDown(with event: NSEvent) {
        let flags  = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars  = event.charactersIgnoringModifiers ?? ""

        // ⌘⌫ (Command + Backspace / Delete) — Move to Trash.
        // keyCode 51 is the Delete/Backspace key on all Mac keyboards.
        if flags == .command && event.keyCode == 51 {
            fileOpsDelegate?.deleteSelectedRows()
            return
        }

        // Return — begin inline rename, or commit if already editing.
        if chars == "\r" {
            if isEditingCell {
                fileOpsDelegate?.commitEdit()
            } else {
                fileOpsDelegate?.beginEditingSelected()
            }
            return
        }

        // F2 (keyCode 120) — begin inline rename (VS Code / Windows Explorer binding).
        if event.keyCode == 120 {
            fileOpsDelegate?.beginEditingSelected()
            return
        }

        // Escape — cancel edit in progress.
        if chars == "\u{1B}" && isEditingCell {
            fileOpsDelegate?.cancelEdit()
            return
        }

        super.keyDown(with: event)
    }

    /// `true` while an inline edit is open. Asked of the delegate, NOT derived from
    /// `editedRow`: on this view-based outline `editedRow` stays -1 for the whole
    /// `editColumn` session (measured), so that test was never true.
    private var isEditingCell: Bool { fileOpsDelegate?.isEditingInline ?? false }

    // MARK: Edit menu (H7)
    //
    // NSTableView answers none of these selectors, so before this the Edit menu's
    // Copy and Paste greyed out over the tree and ⌘C/⌘V did nothing. While a rename
    // field is open the field editor is first responder and gets these first, which
    // is what keeps ⌘C copying TEXT there rather than files.

    @objc func cut(_ sender: Any?) { fileOpsDelegate?.performCut(sender) }
    @objc func copy(_ sender: Any?) { fileOpsDelegate?.performCopy(sender) }
    @objc func paste(_ sender: Any?) { fileOpsDelegate?.performPaste(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action,
              [#selector(cut(_:)), #selector(copy(_:)), #selector(paste(_:))].contains(action)
        else { return super.validateUserInterfaceItem(item) }
        guard let delegate = fileOpsDelegate, !delegate.isEditingInline else { return false }
        // Paste needs something on the clipboard, not a selection: with nothing
        // selected it pastes into the root.
        if action == #selector(paste(_:)) { return delegate.hasFileClipboard }
        return selectedRow >= 0
    }

    // MARK: - Hover tracking
    //
    // A single tracking area on the outline view, with `mouseMoved:` doing
    // row-level hit-testing. One area instead of one per row avoids
    // tracking-area churn during scroll (the OmniFocus lesson).

    /// The row index currently under the cursor, or -1 when outside.
    var hoveredRow: Int = -1

    private var hoverTrackingArea: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited,
                      .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let obs = scrollObserver { NotificationCenter.default.removeObserver(obs) }
        scrollObserver = nil
        guard let clipView = enclosingScrollView?.contentView,
              window != nil else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView, queue: .main
        ) { [weak self] _ in self?.rehoverFromMousePosition() }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveredRow(row(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredRow(-1)
    }

    override func reloadData() {
        super.reloadData()
        // Row views are discarded during reload. Defer re-hover until
        // AppKit creates the new ones during the next layout pass.
        DispatchQueue.main.async { [weak self] in
            self?.rehoverFromMousePosition()
        }
    }

    private func setHoveredRow(_ newRow: Int) {
        guard newRow != hoveredRow else { return }
        (rowView(atRow: hoveredRow, makeIfNecessary: false) as? FileTreeRowView)?
            .isHovered = false
        hoveredRow = newRow
        guard newRow >= 0 else { return }
        (rowView(atRow: newRow, makeIfNecessary: false) as? FileTreeRowView)?
            .isHovered = true
    }

    /// Re-derive hover from the current mouse position. Called after scroll
    /// and after `reloadData` so the highlight follows the cursor even when
    /// `mouseMoved:` has not fired.
    private func rehoverFromMousePosition() {
        guard let window = window else { setHoveredRow(-1); return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInView = convert(mouseInWindow, from: nil)
        setHoveredRow(bounds.contains(mouseInView) ? row(at: mouseInView) : -1)
    }
}
