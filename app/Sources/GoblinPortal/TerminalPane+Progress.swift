// TerminalPane+Progress.swift
// Wires OSC 9;4 progress reports into TerminalPane's per-pane ProgressPanePolicy
// and forwards changes up to the document delegate.
//
// Why a separate file
// -------------------
// TerminalPane.swift is at 282 LOC and this concern is entirely orthogonal to
// the existing shell-exit and shell-integration files.  A thin extension keeps
// TerminalPane.swift readable and this wiring findable by its name.
//
// How it fits the existing decode path
// -------------------------------------
// GoblinPortalTerminalView+Notify.swift already intercepts OSC 9 payloads that
// begin with "4;" and routes them through a second SwiftTerm Terminal decoder
// (the progressDecoder) rather than reaching the notification path.  That
// decoder fires MacTerminalView.progressReport (SwiftTerm's in-view bar).
// What was missing: a parallel call into this extension so the tab strip and
// Dock can also reflect the same state.
//
// The hook is registered in registerNotifications() (TerminalPane+Notifications.swift)
// by calling registerProgressHandler() below.  The registration happens before
// the shell starts, matching the OSC 133 registration order.
//
// Staleness timer
// ---------------
// A Foundation Timer fires after ProgressPanePolicy.stalenessInterval (90 s) of
// inactivity and calls applyTimeout().  The timer is reset on every progress
// update and cancelled on commandFinished / shellDidExit.  One timer per pane,
// stored via objc_setAssociatedObject (same pattern as shellIntegrationState).
//
import AppKit
import SwiftTerm

@MainActor
extension TerminalPane {

    // MARK: - Stored state via associated objects

    private static var progressPolicyKey: UInt8 = 0
    private static var progressTimerKey:  UInt8 = 0

    var progressPolicy: ProgressPanePolicy {
        get {
            (objc_getAssociatedObject(self, &Self.progressPolicyKey)
                as? ProgressPanePolicyBox)?.value ?? ProgressPanePolicy()
        }
        set {
            objc_setAssociatedObject(self, &Self.progressPolicyKey,
                ProgressPanePolicyBox(newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private var stalenessTimer: Timer? {
        get { objc_getAssociatedObject(self, &Self.progressTimerKey) as? Timer }
        set {
            objc_setAssociatedObject(self, &Self.progressTimerKey,
                newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    // MARK: - Progress update (called from GoblinPortalTerminalView+Progress via +Notify)

    /// Called when SwiftTerm decodes an OSC 9;4 report.
    /// `stateCode` 0-4; `progress` 0-100 (already clamped by SwiftTerm).
    func applyProgressReport(stateCode: Int, progress: Int) {
        var policy = progressPolicy
        let old = policy.state
        policy.apply(stateCode: stateCode, progress: progress)
        progressPolicy = policy

        if policy.state == .none {
            cancelStalenessTimer()
        } else {
            resetStalenessTimer()
        }

        if policy.state != old {
            notifyProgressChanged()
        }
    }

    // MARK: - Staleness integration (OSC 133 D / shell exit)

    /// Called from applyCommandOutcome (TerminalPane+ShellIntegration) when a
    /// command finishes.  Clears progress — a program that dies without 9;4;0
    /// gets cleared at the next OSC 133 D.
    func progressCommandFinished() {
        var policy = progressPolicy
        guard policy.isActive else { return }
        policy.commandFinished()
        progressPolicy = policy
        cancelStalenessTimer()
        notifyProgressChanged()
    }

    /// Called from shellDidExit (TerminalPane+ShellExit) on shell death.
    func progressShellExited() {
        progressCommandFinished()
    }

    // MARK: - Staleness timer

    private func resetStalenessTimer() {
        stalenessTimer?.invalidate()
        // Capture weak self so the timer does not retain the pane.
        let t = Timer.scheduledTimer(
            withTimeInterval: ProgressPanePolicy.stalenessInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fireStalenessTimeout()
            }
        }
        stalenessTimer = t
    }

    private func cancelStalenessTimer() {
        stalenessTimer?.invalidate()
        stalenessTimer = nil
    }

    private func fireStalenessTimeout() {
        var policy = progressPolicy
        guard policy.isActive else { return }
        policy.applyTimeout()
        progressPolicy = policy
        stalenessTimer = nil
        notifyProgressChanged()
    }

    // MARK: - Notification

    private func notifyProgressChanged() {
        // documentDidChangeStatus drives syncDocumentChrome → tab strip reload
        // AND the Dock tile update in AppDelegate+DockProgress.swift.
        documentDelegate?.documentDidChangeStatus(self)
    }
}

// MARK: - Box (value type storage via associated object)

/// Wraps ProgressPanePolicy (a struct) for storage as an AnyObject.
private final class ProgressPanePolicyBox {
    var value: ProgressPanePolicy
    init(_ v: ProgressPanePolicy) { value = v }
}
