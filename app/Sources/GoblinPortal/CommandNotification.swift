//
//  CommandNotification.swift
//  Desktop notifications for completed commands in background terminal tabs.
//
//  Ghostty 1.3 shipped this as a flagship feature. The failure mode it fixes:
//  a long build or test run finishes in a background tab and you do not notice
//  for minutes — the exact workflow Goblin Portal exists to host.
//
//  Requires: OSC 133 shell integration (Resources/shell-integration.zsh sourced).
//  Without it, the shell never emits the D sequence and nothing fires.
//
//  T2.5 (2026-10-09): permission is now deferred to the first relevant use.
//  The `requestPermissionIfNeeded()` that used to fire in `applicationDidFinish
//  Launching` is gone. Instead every call to `post(title:body:)` consults
//  `NotificationPermissionPolicy` and takes one of four actions:
//   · .requestThenPost — first-ever notification; ask the system, then post
//                         from the completion handler so the first event is not
//                         lost (macOS drops notifications added before the grant).
//   · .post            — already authorized; post immediately.
//   · .enqueue         — request in flight; store (cap: maxQueued) for delivery
//                         once the user answers the dialog.
//   · .drop            — denied; do nothing, do not re-ask.
//

import Foundation
import UserNotifications

/// Posts a macOS notification when a command finishes in a background tab.
///
/// Conditions (all must hold):
/// 1. The terminal tab is NOT the active, visible document in a key window.
/// 2. The command ran for at least `CommandOutcome.longRunningThreshold`.
/// 3. Notification permission has been granted (lazily, at first relevant use).
///
/// Condition 1 prevents noise: a command you are watching does not need a
/// notification. Condition 2 prevents every `ls` from pinging — only long
/// commands earn a notification. Ghostty uses 10s; we match that.
///
/// **Policy divergence from `CommandOutcome`:** a non-zero exit in under
/// `CommandOutcome.longRunningThreshold` seconds produces a red tab dot
/// (via `CommandOutcome.of`) but no desktop notification. This is intentional
/// — a fast failure is a typo or a missing binary the user almost certainly
/// saw; a desktop ping for every `gti status` would be noise that trains users
/// to dismiss notifications.
@MainActor
enum CommandNotification {

    /// Lazily-initialized permission policy. Shared by both public entry points.
    private static var policy = NotificationPermissionPolicy()

    /// Post a notification for a completed command, if appropriate.
    ///
    /// - Parameters:
    ///   - exitCode: The command's exit code (nil if unknown).
    ///   - durationNanos: How long the command ran, in nanoseconds.
    ///   - title: The terminal tab's title (from OSC 0/2).
    ///   - isActiveDocument: Whether this tab is currently visible and focused.
    ///
    /// Note: a non-zero exit in under `CommandOutcome.longRunningThreshold`
    /// seconds will produce a red tab dot (see `CommandOutcome.of`) but no
    /// desktop notification. See the type-level doc comment for the rationale.
    static func postIfNeeded(
        exitCode: Int?,
        durationNanos: UInt64,
        title: String,
        isActiveDocument: Bool
    ) {
        // Match CommandOutcome: nil exitCode is not actionable evidence.
        // It means the shell emitted 'D' without an exit code field, which
        // happens on the first prompt after sourcing (before any command ran).
        guard let exitCode = exitCode else { return }

        // Condition 1: only notify for background tabs.
        guard !isActiveDocument else { return }

        // Condition 2: only notify for commands that ran at least as long as
        // the tab-dot threshold — the two surfaces share one policy.
        let durationSeconds = Double(durationNanos) / 1_000_000_000
        guard durationSeconds >= CommandOutcome.longRunningThreshold else { return }

        let status = exitCode == 0 ? "completed" : "failed (exit \(exitCode))"
        let durationText = formatDuration(durationSeconds)

        post(title: "Command \(status)", body: "\(title) — \(durationText)")
    }

    /// Explicit OSC requests have no command-duration threshold, but share the
    /// visibility guard, permission policy, and delivery path with command completion.
    static func postEscapeNotification(title: String, body: String, isActiveDocument: Bool) {
        guard !isActiveDocument else { return }
        post(title: title, body: body)
    }

    // MARK: - Permission-aware delivery

    /// Single delivery funnel used by both public entry points.
    ///
    /// Consults `NotificationPermissionPolicy` and takes one of four actions:
    /// request-then-post, post-immediately, enqueue, or drop.
    private static func post(title: String, body: String) {
        let action = policy.notificationRequested(title: title, body: body)
        switch action {

        case .requestThenPost(let t, let b):
            // First notification ever. Ask for authorization; if granted, post
            // this notification AND flush any that arrived during the dialog.
            // If denied, the policy's state transitions to .denied and the
            // completion handler drops the queue — no re-ask, no silent loop.
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            ) { [t, b] granted, error in
                if let error = error,
                   ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
                    FileHandle.standardError.write(
                        "[diag] notification permission error: \(error.localizedDescription)\n"
                            .data(using: .utf8)!)
                }
                // Hop to MainActor: policy is @MainActor-guarded, and
                // UNUserNotificationCenter callbacks come on an arbitrary thread.
                DispatchQueue.main.async {
                    let queued = policy.authorizationCompleted(granted: granted)
                    if granted {
                        // Post the trigger notification first, then the burst queue.
                        actuallyPost(title: t, body: b)
                        for item in queued {
                            actuallyPost(title: item.title, body: item.body)
                        }
                    }
                    // granted == false: policy is now .denied; queue was discarded.
                }
            }

        case .post(let t, let b):
            actuallyPost(title: t, body: b)

        case .enqueue:
            // Already stored inside policy.pendingQueue by notificationRequested.
            // Nothing to do here; the requestThenPost completion handler will
            // deliver when the dialog is answered.
            break

        case .drop:
            break
        }
    }

    /// Unconditionally submits one notification to UNUserNotificationCenter.
    private static func actuallyPost(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Use a unique identifier so each notification is separate.
        let request = UNNotificationRequest(
            identifier: "goblin-portal-command-\(UUID().uuidString)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error,
               ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
                FileHandle.standardError.write(
                    "[diag] notification post error: \(error.localizedDescription)\n"
                        .data(using: .utf8)!)
            }
        }
    }

    // MARK: - Helpers

    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m)m \(s)s"
        } else {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return "\(h)h \(m)m"
        }
    }
}
