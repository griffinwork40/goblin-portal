//
//  CommandNotification.swift
//  Desktop notifications for completed commands in background terminal tabs.
//
//  Ghostty 1.3 shipped this as a flagship feature. The failure mode it fixes:
//  a long build or test run finishes in a background tab and you do not notice
//  for minutes — the exact workflow Umber exists to host.
//
//  Requires: OSC 133 shell integration (Resources/shell-integration.zsh sourced).
//  Without it, the shell never emits the D sequence and nothing fires.
//

import Foundation
import UserNotifications

/// Posts a macOS notification when a command finishes in a background tab.
///
/// Conditions (all must hold):
/// 1. The terminal tab is NOT the active, visible document in a key window.
/// 2. The command ran for at least `minimumDurationSeconds`.
/// 3. Notification permission has been requested.
///
/// Condition 1 prevents noise: a command you are watching does not need a
/// notification. Condition 2 prevents every `ls` from pinging — only long
/// commands earn a notification. Ghostty uses 10s; we match that.
@MainActor
enum CommandNotification {
    /// Minimum command duration (in seconds) before a notification fires.
    /// Below this, the command finishes fast enough that the user likely
    /// noticed, or it was trivial (ls, cd, cat).
    static let minimumDurationSeconds: Double = 10

    /// Request notification permission on first launch. Safe to call multiple
    /// times — `requestAuthorization` is a no-op after the first grant/deny.
    static func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                // Non-fatal: the terminal works fine without notifications.
                // Log under UMBER_DIAG for debuggability.
                if ProcessInfo.processInfo.environment["UMBER_DIAG"] != nil {
                    FileHandle.standardError.write(
                        "[diag] notification permission error: \(error.localizedDescription)\n"
                            .data(using: .utf8)!)
                }
            }
        }
    }

    /// Post a notification for a completed command, if appropriate.
    ///
    /// - Parameters:
    ///   - exitCode: The command's exit code (nil if unknown).
    ///   - durationNanos: How long the command ran, in nanoseconds.
    ///   - title: The terminal tab's title (from OSC 0/2).
    ///   - isActiveDocument: Whether this tab is currently visible and focused.
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

        // Condition 2: only notify for long commands.
        let durationSeconds = Double(durationNanos) / 1_000_000_000
        guard durationSeconds >= minimumDurationSeconds else { return }

        let status = exitCode == 0 ? "completed" : "failed (exit \(exitCode))"
        let durationText = formatDuration(durationSeconds)

        let content = UNMutableNotificationContent()
        content.title = "Command \(status)"
        content.body = "\(title) — \(durationText)"
        content.sound = .default

        // Use a unique identifier so each notification is separate.
        let request = UNNotificationRequest(
            identifier: "umber-command-\(UUID().uuidString)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error,
               ProcessInfo.processInfo.environment["UMBER_DIAG"] != nil {
                FileHandle.standardError.write(
                    "[diag] notification post error: \(error.localizedDescription)\n"
                        .data(using: .utf8)!)
            }
        }
    }

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
