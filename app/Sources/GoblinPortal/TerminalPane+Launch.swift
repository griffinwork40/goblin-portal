//
//  TerminalPane+Launch.swift
//  Starting (and, since T2.2, RE-starting) the pane's login shell: the launch
//  environment, the cwd handed to SwiftTerm, and the check that cwd is still usable.
//
//  Its own file because launching gained a second caller (Return-to-restart in
//  `TerminalPane+ShellExit.swift`) in the same change that took `TerminalPane.swift`
//  past the 350-line ceiling. Moved verbatim apart from that one access note; the
//  stored state it reads (`workingDirectory`, `config`, `startedShellName`) stays on
//  the class because extensions cannot add stored properties.
//

import AppKit
import SwiftTerm

extension TerminalPane {
    /// Start the user's login shell in `workingDirectory`. `-l` so their real PATH and
    /// rc files load — without it, tools installed via Homebrew or a node version
    /// manager are missing and the terminal is useless for actual work.
    ///
    /// The working directory goes through SwiftTerm's own `currentDirectory:`
    /// parameter, which it has: `MacLocalTerminalView.swift:175` forwards it to
    /// `LocalProcess.startProcess` (`LocalProcess.swift:383`) and on into
    /// `PseudoTerminalHelpers.fork` (`Pty.swift:60`), which `chdir()`s **inside the
    /// forked child, between `forkpty` and `execve`** (`Pty.swift:101-106`). So this
    /// is a real per-process cwd, not a `cd` typed into the shell: nothing is written
    /// to the user's scrollback or shell history, and there is no window where the
    /// prompt shows the wrong directory. The rejected alternatives were feeding
    /// `cd '<path>'\n` (visible, racy against rc-file output, and it would land in
    /// `HISTFILE`) and setting `PWD` in the environment (a lie — `PWD` is a shell
    /// convention, the process cwd would still be wrong, so `$(pwd)` and every
    /// relative path would disagree with the prompt).
    ///
    /// Passing `nil` reproduces the old behaviour exactly — SwiftTerm skips the
    /// `chdir` entirely when the parameter is nil (`Pty.swift:101-104`) — so an
    /// unrooted pane inherits the app process's cwd as before.
    func start() { startProcessInDirectory(resolvedWorkingDirectory()) }

    /// One launch path for initial start and Return restart: same login arguments,
    /// integration environment, cursor style and OSC 133 registration. The view is
    /// deliberately reused so its terminal buffer and scrollback survive restart.
    func startProcessInDirectory(_ directory: String?) {
        var env = Terminal.getEnvironmentVariables()
        env.append("TERM_PROGRAM=GoblinPortal")
        env.append("TERM_PROGRAM_VERSION=0.1")
        appendShellIntegrationEnv(&env)  // GOBLIN_PORTAL_INTEGRATION — see TerminalPane+ShellIntegration
        startedShellName = URL(fileURLWithPath: config.shell).resolvingSymlinksInPath().lastPathComponent
        view.startProcess(executable: config.shell, args: ["-l"],
            environment: env, currentDirectory: directory)
        applyCursorStyle(config.cursorStyle)
        registerShellIntegration()       // OSC 133 — see TerminalPane+ShellIntegration
    }

    /// The cwd to hand the shell, or nil to let it inherit the app's.
    ///
    /// Checked rather than passed through blind because SwiftTerm **discards the
    /// `chdir` result** — `Pty.swift:103` is `_ = chdir(cCurrentDirectory)`, in the
    /// forked child where there is no way to report anything back — so a root that
    /// has been deleted or renamed since the Space opened would start the shell in
    /// the app process's cwd with no error anywhere. A persisted root makes that a
    /// live case, not a theoretical one: `LastSpaceRoot` restores a directory across
    /// launches, and directories get moved between them. Failing soft to the same
    /// place, but *saying so* under `GOBLIN_PORTAL_DIAG`, matches `AppConfig.load()`'s
    /// per-field contract: degrade, warn, never throw.
    ///
    /// The predicate itself is `FileManager.isUsableSpaceRoot(atPath:)` rather than an
    /// inlined `fileExists(atPath:isDirectory:)` — a third caller of the rule that
    /// `Defaults.swift:96` already warns about duplicating ("two copies of a
    /// check-don't-trust rule is two places for it to drift"). Same question, one
    /// answer: a remembered root can be replaced by a *file* of the same name, and
    /// that has to read as unusable here exactly as it does for Space restore.
    /// Internal, not `private`: `TerminalPane+ShellExit.swift` calls it to resolve the
    /// restart cwd when the exited shell's last directory is no longer usable.
    func resolvedWorkingDirectory() -> String? {
        // `.path`, not `absoluteString`: `chdir()` takes a filesystem path, and a
        // `file://` URL string with percent-escapes is not one.
        let path = workingDirectory.standardizedFileURL.path
        guard FileManager.default.isUsableSpaceRoot(atPath: path) else {
            if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
                FileHandle.standardError.write(
                    "[diag] pane root not a usable directory, shell will inherit app cwd: \(path)\n"
                        .data(using: .utf8)!)
            }
            return nil
        }
        return path
    }
}
