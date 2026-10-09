// TerminalPane+Notifications.swift
// Pane-side notification setup and attention signals, separate from OSC 133 outcomes.
import AppKit

@MainActor
extension TerminalPane {
    func registerNotifications() {
        view.registerNotificationHandlers { [weak self] parsed, kind in
            guard let self, case let .notification(title, body) = parsed else { return }
            self.signalAttention(kind: kind, title: title, body: body)
        }
    }

    func signalAttention(kind: DockAttention.SignalKind, title: String = "", body: String = "") {
        // Reuse the exact predicate passed to CommandNotification in +ShellIntegration.
        // Visible panes do not accumulate unread state; background tabs notify even
        // while another tab in the same app is active (AppDelegate+Notifications.swift).
        let visible = isActiveDocument
        if !visible { status = .attention }
        (NSApp.delegate as? AppDelegate)?.dockAttentionSignal(
            kind: kind, title: title, body: body, isDocumentVisible: visible)
    }
}
