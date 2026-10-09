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
    /// `tcgetpgrp(childfd)` gives the foreground process GROUP; the group leader's pid
    /// equals the group id on Darwin for a simple foreground job, so we treat it as the
    /// pid. If it equals `integratedShellPid`, the shell itself is in front → `.shell`.
    /// Unreadable foreground (fd closed, -1 or 0 returned) → nil, which is fail-closed.
    ///
    /// - Parameters:
    ///   - childfd: the pty primary fd (`LocalProcess.childfd`).
    ///   - integratedShellPid: the pane's own shell (`LocalProcess.shellPid`).
    static func current(childfd: Int32, integratedShellPid: pid_t) -> ForegroundKind? {
        // tcgetpgrp returns the foreground process group id. On Darwin a foreground
        // job that did not change its own process group has group id == its pid
        // (the group leader). -1 means errno (fd closed, BADF); 0 means no foreground
        // group (fresh pty with no session, or process gone). Both are fail-closed → nil.
        guard childfd >= 0 else { return nil }
        let fgpid = tcgetpgrp(childfd)
        guard fgpid > 0 else { return nil }

        let tty = clientTTY(childfd: childfd)
        guard let name = executableName(of: fgpid) else { return nil }
        return kind(executableName: name, pid: fgpid,
                    integratedShellPid: integratedShellPid, clientTTY: tty)
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
        // The integrated shell itself is in front — no foreground job.
        if pid == integratedShellPid { return .shell }

        // Classification is strictly by the kernel's reported executable basename —
        // NOT by argv. A process whose argv[0] is "-zsh" or "zsh" but whose kernel
        // path is /bin/sleep would be caught here because executableName(of:) gives
        // us the real name from proc_pidpath. The remaining documented limit is that
        // we trust the FILENAME, not a code signature: a /bin/sleep renamed "zsh"
        // classifies as .knownShell. That boundary is tested and documented in
        // check-foreground-process.sh.
        switch executableName {

        // ── shells ───────────────────────────────────────────────────────────────
        // Names sourced from the contract doc (plan §wave-0-K).
        // Case-sensitive: proc_pidpath on macOS returns the actual binary name, which
        // is always lowercase for system shells and all shells in Homebrew.
        case "zsh", "bash", "sh", "dash", "fish", "ksh", "mksh",
             "tcsh", "csh", "nu", "elvish", "xonsh", "pwsh":
            return .knownShell(pid: pid, name: executableName)

        // ── tmux ─────────────────────────────────────────────────────────────────
        // A tmux client is in front. We need the pty slave tty to identify WHICH
        // tmux client — `tmux display-message -c <tty>` resolves the active pane.
        // If clientTTY is nil we have no address for tmux and cannot resolve it, so
        // .command is the fail-closed answer: at least the typing guard refuses it.
        case "tmux":
            guard let tty = clientTTY else { return .command(name: "tmux") }
            return .tmuxClient(pid: pid, tty: tty)

        // ── remote session transports ─────────────────────────────────────────────
        // Their directory is on another machine and must never be used as a local path.
        // `mosh` and `mosh-client` are both here: mosh forks a mosh-client, either
        // may be what proc_pidpath returns. `et` is EternalTerminal. `autossh` is a
        // reconnecting wrapper around ssh.
        case "ssh", "mosh-client", "mosh", "et", "autossh":
            return .remote(name: executableName)

        // ── other multiplexers ────────────────────────────────────────────────────
        // We cannot ask these for their active pane's directory without their own
        // protocol (screen's escape sequence, zellij's IPC socket). Unknown = nil cwd.
        // `abduco` and `dtach` detach sessions; same story.
        case "screen", "zellij", "abduco", "dtach":
            return .otherMultiplexer(name: executableName)

        // ── privilege escalation: fail-closed ─────────────────────────────────────
        // The shell under `sudo -s` or `su` is root-owned; its cwd is unreadable to
        // us without root. Even if we could read it, the directory is the root user's
        // cwd, not the pane user's. `.command` is the honest answer: the typing guard
        // refuses it and the cwd rule falls back to the Space root. `doas` is the
        // OpenBSD/macOS equivalent of sudo. None of these three is a shell itself.
        case "sudo", "su", "doas":
            return .command(name: executableName)

        // ── everything else ───────────────────────────────────────────────────────
        // An editor, a build, a REPL, an agent. The typing guard refuses .command,
        // so we never accidentally submit text into an agent prompt.
        default:
            return .command(name: executableName)
        }
    }

    /// Basename of `pid`'s executable from the kernel, or nil if it has exited.
    ///
    /// We use `proc_pidpath` — the kernel's record of the file exec'd — and take its
    /// basename via `URL.lastPathComponent`. This is never argv: a login shell's argv0
    /// is typically "-zsh" (with a leading dash, which is NOT a shell name), and any
    /// process can rewrite its argv to impersonate another name. Only the kernel's
    /// executable path is authoritative.
    ///
    /// `proc_pidpath` returns the number of bytes written (> 0 on success, 0 on
    /// ESRCH when the process has exited). 4096 bytes is the documented buffer size
    /// (PROC_PIDPATHINFO_MAXSIZE = 4 × MAXPATHLEN in sys/proc_info.h, unavailable as
    /// a Swift constant because it is a C expression, not an integer literal).
    static func executableName(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let written = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard written > 0 else { return nil }
        let fullPath = String(cString: buf)
        // URL.lastPathComponent is Foundation-only but Foundation is already imported.
        // It is safer than splitting on "/" manually: it handles trailing slashes and
        // edge cases uniformly. For "zsh" → "zsh", "/usr/bin/ssh" → "ssh", etc.
        let base = URL(fileURLWithPath: fullPath).lastPathComponent
        return base.isEmpty ? nil : base
    }

    /// The pty slave device path (e.g. `/dev/ttys012`) for the primary fd `childfd`.
    ///
    /// On macOS we use `TIOCPTYGNAME` rather than `ptsname` or `ptsname_r`:
    ///  - `ptsname` is not thread-safe (uses a static buffer); POSIX says it may
    ///    be superseded by `ptsname_r`, but `ptsname_r` is a Linux/glibc extension
    ///    absent from Apple's Darwin headers (not in any macOS SDK as of 14+).
    ///  - `TIOCPTYGNAME` is macOS-native, fills a caller-supplied buffer atomically,
    ///    and works on the primary fd without requiring the slave to be open. It is
    ///    the approach used by launchd, Terminal.app, and SwiftTerm's own pty helper
    ///    (`vendor/SwiftTerm/Sources/SwiftTerm/Pty.swift`). Verified in the probe
    ///    at check-foreground-process.sh's development: TIOCPTYGNAME → the same path
    ///    ttyname() reports on the slave fd, every time.
    ///
    /// Returns nil on any failure: fd closed, wrong fd type, or the ioctl erroring.
    /// Nil is fail-closed for clientTTY: tmux cannot be resolved and falls back to
    /// `.command("tmux")` in `kind(...)`.
    static func clientTTY(childfd: Int32) -> String? {
        guard childfd >= 0 else { return nil }
        // 128 bytes is more than enough for any /dev/ttys* path; the longest macOS
        // device name observed is /dev/ttys999 (10 bytes).
        var gname = [CChar](repeating: 0, count: 128)
        guard ioctl(childfd, TIOCPTYGNAME, &gname) == 0 else { return nil }
        let path = String(cString: gname)
        return path.isEmpty ? nil : path
    }
}
