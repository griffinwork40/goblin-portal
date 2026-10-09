//
//  TerminalPane+ShellExit.swift
//  The kept shell's exit state, inline explanation, and restart in its existing view.
//
//  A separate concern because TerminalPane.swift is near the 350-line ceiling.
//  SwiftTerm's forkpty monitor passes the raw waitpid word to the delegate BEFORE
//  childStopped() clears `running` (LocalProcess.swift:365-370). A restart must
//  happen after that callback unwinds, not synchronously inside it.
//
import AppKit
import SwiftTerm

@MainActor
extension TerminalPane {
    // Extensions cannot add stored properties. The association is owned by this pane
    // and its address is stable for its lifetime, as in +ShellIntegration.swift.
    private static var shellExitedKey: UInt8 = 0

    var isShellExited: Bool {
        get { (objc_getAssociatedObject(self, &Self.shellExitedKey) as? NSNumber)?.boolValue ?? false }
        set {
            objc_setAssociatedObject(self, &Self.shellExitedKey,
                NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    func shellDidExit(waitStatus: Int32?) {
        let decision = ShellExitPolicy.decide(waitStatus: waitStatus, mode: config.closeOnShellExit)
        if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
            FileHandle.standardError.write(Data("[diag] shell-exit: \(ShellExitPolicy.exitDescription(waitStatus: waitStatus)) → \(decision)\n".utf8))
        }
        guard decision == .keep else {
            // The callback precedes childStopped() in LocalProcess.swift:369-370.
            // Closing synchronously would call documentWillClose while `running`
            // is still true and signal a PID that waitpid has already reaped.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.view.process.running else { return }
                self.documentDelegate?.documentDidTerminate(self)
            }
            return
        }

        // Capture the kernel fallback while the old process still has a valid pty
        // and PID. `currentDirectory` prefers the last OSC 7 report, then asks
        // ShellDirectory for the foreground process (ShellHosting.swift:127-135).
        let lastDirectory = currentDirectory?.standardizedFileURL.path
        isShellExited = true
        // Reuse the existing finished-good / finished-bad marks. Unlike a
        // command's mark, an exited shell's mark persists across tab focus.
        status = waitStatus.map { WIFEXITED($0) && WEXITSTATUS($0) == 0 } == true
            ? .succeeded : .failed

        // The fallback root was supplied at construction. A deleted cwd is checked
        // again at restart rather than handed to SwiftTerm's unchecked chdir.
        exitedDirectory = lastDirectory
        // Let SwiftTerm finish processing queued pty output before appending the
        // status line. This does not wait for an arbitrarily large output backlog.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShellExited else { return }
            self.view.feed(text: "\r\n\(ShellExitPolicy.statusLine(waitStatus: waitStatus, canRestart: true))\r\n")
        }
    }

    private static var exitedDirectoryKey: UInt8 = 0
    private var exitedDirectory: String? {
        get { objc_getAssociatedObject(self, &Self.exitedDirectoryKey) as? String }
        set { objc_setAssociatedObject(self, &Self.exitedDirectoryKey,
            newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    /// Return true when a write must not reach the dead pty. SwiftTerm forwards
    /// all terminal input through LocalProcessTerminalView.send(source:data:)
    /// (MacLocalTerminalView.swift:145-148), including paste and programmatic send.
    /// Only an unmodified Return KEY can restart, never a pasted newline.
    func handleSendWhileExited(data: ArraySlice<UInt8>) -> Bool {
        guard isShellExited else { return false }
        if let event = NSApp.currentEvent, event.type == .keyDown,
           (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           data.count == 1, data.first == 13 {
            restartShell()
        }
        return true
    }

    private func restartShell() {
        guard isShellExited else { return }
        // Do not clear exited until the spawn has had a chance to run. Otherwise
        // a second key before the deferred block would slip into the old pty.
        let cwd = exitedDirectory.flatMap { path in
            FileManager.default.isUsableSpaceRoot(atPath: path) ? path : nil
        } ?? resolvedWorkingDirectory()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShellExited, !self.view.process.running else { return }
            self.isShellExited = false
            self.exitedDirectory = nil
            self.status = .idle
            // Same shell/environment as start(), including TERM_PROGRAM and
            // GOBLIN_PORTAL_INTEGRATION. startProcess reuses this SAME view and
            // terminal buffer (MacLocalTerminalView.swift:175-177).
            self.startProcessInDirectory(cwd)
        }
    }
}
