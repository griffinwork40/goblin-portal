//
//  ForegroundProcess.swift
//  What program is in front of a pane's shell: the shell itself, another shell, a tmux
//  client, a remote session, or an ordinary command.
//
//  Pure and view-free — Foundation and Darwin only — so `check-foreground-process.sh`
//  can compile it alone with swiftc, the same trick `ShellDirectory.swift` plays for
//  `check-cwd-follow.sh`.
//
//  WHY THIS EXISTS. Everything that reads a shell's working directory used to assume the
//  program in front of the pty was the shell, or something that shared its filesystem.
//  Inside tmux the foreground process is the tmux CLIENT, whose cwd is wherever tmux was
//  started; under ssh it is `ssh`, and the directory that matters is on another machine.
//  The sidebar, ⌘T, splits and split persistence all inherited that wrong answer, and the
//  four actions that type into a terminal (Insert Path, cd Here, Send Path, Run in
//  Terminal) typed into whatever was in front — including an agent REPL, where ⌘⇧R
//  submitted `python3 <path>` as a prompt. Classifying the foreground once, here, is what
//  lets both the cwd rule (`ShellDirectoryPolicy`) and the typing guard
//  (`TerminalInputPolicy`) answer from the same fact. Plan:
//  `.afk/plans/tmux-ssh-cwd-and-158-parallel.md`.
//
//  CONTRACT FROZEN in wave 0 (K). Lane A owns the bodies; the signatures do not change
//  without coordinator approval, because lanes C and F build against them in parallel.
//

import Darwin
import Foundation

/// The program in front of a pane's pty, as far as cwd and typing are concerned.
///
/// Classification is by the kernel's executable identity, never by argv: a process can
/// set its displayed command line to anything, and a command that calls itself `zsh`
/// must not unlock the typing guard.
enum ForegroundKind: Equatable {
    /// The pane's own login shell is in front (no foreground job).
    case shell
    /// A different local shell binary is in front (`bash`, `sudo -s`, `nix-shell`).
    case knownShell(pid: pid_t, name: String)
    /// A tmux client is in front; `tty` is the pane's pty slave, which is how tmux
    /// identifies that client (`tmux display-message -c <tty>`).
    case tmuxClient(pid: pid_t, tty: String)
    /// A remote session is in front (`ssh`, `mosh-client`, `et`): its directory is on
    /// another machine and must never be read as a local path.
    case remote(name: String)
    /// A multiplexer we cannot ask for its active pane (`screen`, `zellij`).
    case otherMultiplexer(name: String)
    /// Anything else: an editor, a build, a REPL.
    case command(name: String)
}

/// Classifying a pane's foreground process. A namespace: there is no state.
enum ForegroundProcess {
    /// Classify the pty's foreground process group, or nil when it cannot be read
    /// (shell exited, fd closed). Nil is unsafe for typing and gives no cwd.
    ///
    /// - Parameters:
    ///   - childfd: the pty primary fd (`LocalProcess.childfd`).
    ///   - integratedShellPid: the pane's own shell (`LocalProcess.shellPid`).
    static func current(childfd: Int32, integratedShellPid: pid_t) -> ForegroundKind? {
        // K STUB (lane A replaces): fail closed.
        nil
    }

    /// The pure mapping from an executable name to a kind. Split out from `current` so a
    /// gate can run a truth table without spawning every binary it names.
    ///
    /// - Parameters:
    ///   - executableName: basename of the kernel's executable path (`proc_pidpath`).
    ///   - pid: the foreground process.
    ///   - integratedShellPid: the pane's own shell; `pid == integratedShellPid` is `.shell`.
    ///   - clientTTY: the pane's pty slave path, needed for `.tmuxClient`.
    static func kind(
        executableName: String, pid: pid_t, integratedShellPid: pid_t, clientTTY: String?
    ) -> ForegroundKind {
        // K STUB (lane A replaces): everything is an ordinary command, which the typing
        // guard refuses.
        .command(name: executableName)
    }

    /// Basename of `pid`'s executable from the kernel, or nil if it has exited.
    static func executableName(of pid: pid_t) -> String? {
        // K STUB (lane A replaces).
        nil
    }

    /// The pty slave device path (e.g. `/dev/ttys012`) for the primary fd `childfd`.
    static func clientTTY(childfd: Int32) -> String? {
        // K STUB (lane A replaces).
        nil
    }
}
