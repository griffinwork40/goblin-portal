//
//  PasteGuard.swift
//  Guard against accidental multi-line or large pastes into the terminal.
//

import AppKit

/// Policy for whether a paste should be guarded with a confirmation dialog.
///
/// iTerm2 and WezTerm both ship this feature. The failure mode it prevents:
/// pasting a script or multi-command block into a terminal that executes each
/// newline-terminated line immediately. Without bracketed paste (DECSET 2004),
/// every `\n` in the clipboard is a submitted command.
@MainActor
enum PasteGuard {
    /// Newline count above which a confirmation is shown.
    /// 1 means "any multiline paste". Deliberately low: the cost of a dialog
    /// on a legitimate paste is one click; the cost of running an unintended
    /// `rm -rf` is unbounded.
    static let newlineThreshold = 1

    /// Character count above which a confirmation is shown, even without newlines.
    /// Protects against pasting a massive single line that floods the terminal.
    static let characterThreshold = 1_500

    /// Returns true if the paste should proceed, false if the user cancelled.
    /// Shows a confirmation dialog when the text exceeds thresholds.
    @discardableResult
    static func confirmIfNeeded(_ text: String, in view: NSView) -> Bool {
        let newlineCount = text.filter { $0.isNewline }.count
        let charCount = text.count

        guard newlineCount >= newlineThreshold || charCount >= characterThreshold else {
            return true  // Below thresholds — paste without asking
        }

        let alert = NSAlert()
        alert.messageText = "Confirm Paste"

        if newlineCount > 0 {
            let lines = newlineCount + 1
            alert.informativeText = "The clipboard contains \(lines) lines (\(charCount) characters). Pasting into the terminal will execute each line as a command."
        } else {
            alert.informativeText = "The clipboard contains \(charCount) characters. This is a large paste."
        }

        // Show a preview of the first few lines
        let preview = String(text.prefix(200))
        let trimmed = preview.count < text.count ? preview + "…" : preview
        alert.informativeText += "\n\n\(trimmed)"

        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        // Present as a sheet on the view's window if available, otherwise modal
        if let window = view.window {
            var result: NSApplication.ModalResponse = .alertSecondButtonReturn
            alert.beginSheetModal(for: window) { response in
                result = response
                NSApp.stopModal(withCode: response)
            }
            NSApp.runModal(for: window)
            return result == .alertFirstButtonReturn
        } else {
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}
