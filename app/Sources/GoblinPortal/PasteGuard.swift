//
//  PasteGuard.swift
//  Guard against accidental multi-line or large pastes into the terminal.
//
//  The threshold policy lives in `PasteGuardPolicy.swift` (Foundation-only, gated by
//  `check-paste-guard.sh`). This file owns the AppKit half — the NSAlert dialog — and
//  delegates every threshold decision to `PasteGuardPolicy.evaluate(_:)`, reusing the
//  pre-computed counts for the dialog message so the string is not traversed twice.
//
//  WHY THE SPLIT. `NSView` and `NSAlert` require AppKit, which makes this file opaque to a
//  standalone `swiftc` invocation. The decision ("should this paste be confirmed?") has no such
//  requirement and lives in `PasteGuardPolicy.swift` so the gate can compile it headlessly.
//  The same split appears in `CommandOutcome.swift` / `SpaceDocument.swift` and
//  `Renderer.swift` / the AppKit panes that call it.
//

import AppKit

/// AppKit-side guard for accidental multi-line or large pastes into the terminal.
///
/// iTerm2 and WezTerm both ship this feature. The failure mode it prevents:
/// pasting a script or multi-command block into a terminal that executes each
/// newline-terminated line immediately. Without bracketed paste (DECSET 2004),
/// every `\n` in the clipboard is a submitted command.
///
/// Threshold logic is in `PasteGuardPolicy` (Foundation-only). This enum owns only
/// the dialog presentation and the `NSView` parameter the alert anchors to.
@MainActor
enum PasteGuard {
    /// Returns true if the paste should proceed, false if the user cancelled.
    ///
    /// Calls `PasteGuardPolicy.evaluate(_:)` once to get the threshold decision and
    /// the pre-computed counts, then shows a confirmation dialog when the text exceeds
    /// either threshold. The counts are reused for the dialog message — the string is
    /// never traversed more than once.
    @discardableResult
    static func confirmIfNeeded(_ text: String, in view: NSView) -> Bool {
        let result = PasteGuardPolicy.evaluate(text)
        guard result.shouldConfirm else {
            return true  // Below thresholds — paste without asking
        }

        let newlineCount = result.newlineCount
        let charCount = result.characterCount

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

        return alert.runModal() == .alertFirstButtonReturn
    }
}
