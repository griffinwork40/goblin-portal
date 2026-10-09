// CloseConfirmPolicy.swift
// Owns foreground-job classification and consolidated warning text, separate from
// AppKit so check-close-confirm.sh compiles the shipped decisions standalone.

import Foundation

@MainActor
enum CloseConfirmPolicy {
    /// A foreground group distinct from the login shell is a job, even if its
    /// leader is another shell or a tmux/screen client. Disconnecting those clients
    /// still discards the visible session, so there is deliberately no ignore list.
    /// An exec-replaced shell keeps its PID/group: compare its executable name too,
    /// rather than silently treating `exec vim` as an idle prompt (A1c UX audit #4).
    /// Background jobs are deliberately outside this foreground-only contract.
    static func busyName(
        shellPID: Int32, foregroundGroup: Int32?, processName: String?,
        shellName: String, running: Bool
    ) -> String? {
        guard running, shellPID > 0, let group = foregroundGroup, group > 0 else { return nil }
        let name = processName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if group == shellPID, name == shellName { return nil }
        // Unknown names must not turn a known foreground job into permission to
        // destroy it. The kernel can lose the leader between the two observations.
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? "foreground process"
    }

    static func message(names: [String]) -> String {
        guard names.count != 1 else { return "1 process is running: \(names[0])" }
        // Count jobs, not distinct names: two vim panes are two things to lose.
        let unique = names.reduce(into: [String]()) { result, name in
            if !result.contains(name) { result.append(name) }
        }
        return "\(names.count) processes are running: \(unique.joined(separator: ", "))"
    }
}
