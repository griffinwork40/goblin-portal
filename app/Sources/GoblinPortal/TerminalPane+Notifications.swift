// TerminalPane+Notifications.swift
// Pane-side notification setup and attention signals, separate from OSC 133 outcomes.
import AppKit
import QuartzCore  // CACurrentMediaTime

@MainActor
extension TerminalPane {
    func registerNotifications() {
        view.registerNotificationHandlers { [weak self] parsed, kind in
            guard let self, case let .notification(title, body) = parsed else { return }
            self.signalAttention(kind: kind, title: title, body: body)
        }
        // Wire the OSC 9;4 progress callback so +Notify.swift can forward decoded
        // 9;4 payloads here after feeding the progressDecoder for the native bar.
        // Defined in GoblinPortalTerminalView+Progress.swift.
        view.progressCallback = { [weak self] code, pct in
            self?.applyProgressReport(stateCode: code, progress: pct)
        }
        // Update lastDrawTimestamp on every output batch so the agent-activity
        // timer (TerminalPane+AgentActivity.swift) detects output regardless of
        // renderer.  With Metal, draw() returns immediately (MacTerminalView.swift:1848)
        // and AppKit rarely calls it, so the timestamp set there goes stale; this
        // callback fires on every parse batch, including under Metal.
        // The callback runs on the swiftterm-io-reader thread; capture the
        // timestamp there (accurate) and dispatch the write to main (safe).
        view.setProcessOutputHandler { [weak view] in
            let now = CACurrentMediaTime()
            DispatchQueue.main.async { view?.lastDrawTimestamp = now }
        }
        startAgentActivityTimer()  // output-activity heuristic — see TerminalPane+AgentActivity
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
