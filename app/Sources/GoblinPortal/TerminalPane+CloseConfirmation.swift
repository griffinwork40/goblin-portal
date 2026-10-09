// TerminalPane+CloseConfirmation.swift
// Owns the kernel-to-close-policy adapter. Kept out of TerminalPane.swift because
// process lifetime and warning presentation are distinct concerns near its ceiling.

import AppKit

extension TerminalPane: CloseConfirmProviding {
    var runningCloseProcessName: String? {
        // LocalProcess keeps shellPid after reaping (LocalProcess.swift:270,527).
        // Test running FIRST so retained exited panes never inspect a reused PID.
        guard let process = view.process, process.running,
              let foreground = ShellDirectory.foregroundProcess(childfd: process.childfd)
        else { return nil }
        return CloseConfirmPolicy.busyName(
            shellPID: process.shellPid, foregroundGroup: foreground.group,
            processName: foreground.name, shellName: startedShellName, running: process.running)
    }

    func documentShouldClose() -> Bool { CloseConfirmation.confirm([self]) }
}
