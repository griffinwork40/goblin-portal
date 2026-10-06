//
//  FileTreeOutlineView.swift
//  Thin NSOutlineView subclass: routes ⌘⌫, Return, F2 and Escape to the
//  file-ops delegate, leaving everything else to super.
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

    /// `true` while the outline view has an active cell editor.
    ///
    /// `editedColumn` and `editedRow` are both `-1` when no cell is being edited.
    private var isEditingCell: Bool { editedColumn >= 0 && editedRow >= 0 }
}
