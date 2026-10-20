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
        // ⌘W then Return must finish what ⌘W started: Return answers Close/Quit
        // (Terminal.app's "Terminate" and iTerm2's "OK" are default the same
        // way), Escape answers Cancel. Cancel-as-default made Return dismiss the
        // alert the user had just asked for, so the window never closed.
        // NOT `hasDestructiveAction`: measured on macOS 27.0.1, NSAlert strips
        // the key equivalent and default status from a destructive button when
        // it runs, so Return reached NO button at all. The `.warning` style and
        // the "interrupt these processes" text carry the danger instead.
        let close = alert.addButton(withTitle: quitting ? "Quit" : "Close")
        close.keyEquivalent = "\r"
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
