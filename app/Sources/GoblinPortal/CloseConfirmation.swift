// CloseConfirmation.swift
// Owns the AppKit close decision for one user action. Separate from the pure
// policy and document containers so quit can aggregate jobs across all Spaces.

import AppKit

@MainActor
protocol CloseConfirmProviding: SpaceDocument {
    var runningCloseProcessName: String? { get }
}

@MainActor
enum CloseConfirmation {
    /// Injectable decision seam for an offscreen harness; production uses the alert.
    static var present: @MainActor (_ names: [String], _ quitting: Bool) -> Bool = showAlert

    static func confirm(_ documents: [SpaceDocument], quitting: Bool = false) -> Bool {
        // Snapshot once before any modal dialog spins the run loop. Keep each
        // document once: split roots and peer traversals may share references.
        var seen = Set<ObjectIdentifier>()
        let unique = documents.filter { seen.insert(ObjectIdentifier($0)).inserted }
        let names = unique.compactMap { ($0 as? CloseConfirmProviding)?.runningCloseProcessName }
        guard names.isEmpty || present(names, quitting) else { return false }
        // Terminal witnesses would re-prompt individually. Other document kinds
        // retain their existing Save/Cancel contract (FileViewerPane+Document:149).
        for document in unique where !(document is CloseConfirmProviding) {
            if !document.documentShouldClose() { return false }
        }
        return true
    }

    private static func showAlert(names: [String], quitting: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = quitting ? "Quit Goblin Portal?" : "Close running processes?"
        alert.informativeText = CloseConfirmPolicy.message(names: names)
            + "\nClosing will interrupt these processes and may lose their work."
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let close = alert.addButton(withTitle: quitting ? "Quit" : "Close")
        close.keyEquivalent = ""
        close.hasDestructiveAction = true
        // Cancel is both Return and Escape, never the destructive first response.
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        return alert.runModal() == .alertSecondButtonReturn
    }
}
