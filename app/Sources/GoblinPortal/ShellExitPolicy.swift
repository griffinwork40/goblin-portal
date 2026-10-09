//
//  ShellExitPolicy.swift
//  What to do when a terminal's shell exits — the decision, separated from the doing.
//
//  Foundation-only, view-free. The policy is a pure function of exit status and
//  the user's `closeOnShellExit` setting, so it compiles headless with swiftc
//  alongside a truth table (`app/Scripts/check-shell-exit.sh`). Same trick as
//  `CommandOutcome.swift`, `Renderer.swift`, `CursorStyle.swift`.
//
//  WHY FOUNDATION-ONLY. The AppKit callers live in `TerminalPane+ShellExit.swift`
//  (the status-line rendering, restart wiring, key-swallow guard), which imports
//  AppKit and SwiftTerm. Splitting the decision from the presentation keeps the
//  decision testable and the presentation honest: the gate cannot lie about a
//  result it measured from a compiled copy of the shipped file.
//
//  EXIT STATUS SEMANTICS (from `LocalProcess.swift`):
//
//  The forkpty path (`startProcessWithForkpty`) calls `waitpid(shellPid, &n, WNOHANG)`
//  (`LocalProcess.swift:368`) and passes `n` — the raw `waitpid` status word — straight
//  to the delegate as `exitCode` (`LocalProcess.swift:369`). That is NOT the exit status;
//  it is the full `waitpid` status word that must be unpacked with POSIX macros:
//
//   • WIFEXITED(n) — shell exited normally; WEXITSTATUS(n) is the exit code (0–255)
//   • WIFSIGNALED(n) — shell killed by signal; WTERMSIG(n) is the signal number
//   • Both false — should not happen with WNOHANG and a reaped child; treated as
//     unclean.
//
//  The subprocess path (`startProcessWithSubprocess`) is gated behind `#if false` in
//  the vendored source (`LocalProcess.swift:388-392`, `#if false //canImport(Subprocess)`)
//  and is therefore unreachable at runtime. That path separately encodes
//  `.exit(let code)` → `exitCode = code` and `.uncaughtSignal` → `exitCode = nil`
//  (`LocalProcess.swift:469-476`). Both paths' contracts are documented here so
//  future changes can reason from the source rather than guessing.
//
//  The delegate callback on `TerminalView` (`processTerminated(source:exitCode:)` in
//  `LocalProcessTerminalViewDelegate`) passes the same raw value through unchanged
//  (`Mac/MacLocalTerminalView.swift:120`, `LocalProcess.swift:369`).
//
//  CLEAN-vs-UNCLEAN SPLIT. `closeOnShellExit`:
//   • "clean"  (default): close the pane only when WIFEXITED && WEXITSTATUS == 0.
//     Any signal or nonzero exit is unclean → keep the pane.
//   • "always": always close (today's behaviour).
//   • "never":  always keep.
//
//  Gated by `app/Scripts/check-shell-exit.sh`.
//

import Foundation

// MARK: - waitpid status word helpers
//
// The POSIX macros WIFEXITED, WEXITSTATUS, WIFSIGNALED, WTERMSIG are C macros and
// are NOT available as Swift functions outside AppKit/Foundation builds — standalone
// swiftc sees them as "macro unavailable: function like macros not supported". The
// Darwin SDK definitions are (`sys/wait.h`):
//
//   #define _WSTATUS(x)     ((x) & 0x7f)
//   #define WIFEXITED(x)    (_WSTATUS(x) == 0)
//   #define WEXITSTATUS(x)  ((_W_INT(x) >> 8) & 0xff)   // __DARWIN_UNIX03
//   #define WIFSIGNALED(x)  (_WSTATUS(x) != 0x7f && _WSTATUS(x) != 0)
//   #define WTERMSIG(x)     (_WSTATUS(x))
//
// We reproduce them as pure Swift so the Foundation-only file compiles headless.
// The arithmetic is identical to the C macros; the gate spawns real children and
// feeds their actual waitpid status words through these functions to validate them.
//
// `_W_INT` is `*(int *)&(x)` — a simple cast — so for Int32 it is identity.

@inline(__always)
private func _wstatus(_ x: Int32) -> Int32 { x & 0x7f }

/// True when the process exited normally via exit(2) or _exit(2).
func WIFEXITED(_ x: Int32) -> Bool { _wstatus(x) == 0 }

/// The exit code (0–255) when WIFEXITED is true.
func WEXITSTATUS(_ x: Int32) -> Int32 { (x >> 8) & 0xff }

/// True when the process was killed by a signal.
func WIFSIGNALED(_ x: Int32) -> Bool { _wstatus(x) != 0x7f && _wstatus(x) != 0 }

/// The signal number when WIFSIGNALED is true.
func WTERMSIG(_ x: Int32) -> Int32 { _wstatus(x) }

// MARK: - CloseOnShellExit

/// The `closeOnShellExit` config field: when a shell exits, should the pane close?
///
/// `"clean"` is Terminal.app's default: close on a clean exit (code 0), keep on a
/// nonzero exit or signal so the user can read what went wrong. `"always"` is today's
/// behaviour. `"never"` is the paranoid mode — the tab stays until the user explicitly
/// closes it.
///
/// Foundation-only and compiled by the headless gate.
enum CloseOnShellExit: String {
    case clean  = "clean"
    case always = "always"
    case never  = "never"

    /// Config spellings, for the gate's drift check.
    static let configNames = "clean | always | never"

    /// Parse the config string. Case-insensitive, hyphen or underscore treated as
    /// equivalent (matching the pattern in `Renderer.named(_:)`). Returns nil when
    /// the value is not recognised; the caller appends a warning.
    static func named(_ raw: String) -> CloseOnShellExit? {
        let normalised = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        switch normalised {
        case "clean":  return .clean
        case "always": return .always
        case "never":  return .never
        default:       return nil
        }
    }
}

// MARK: - ShellExitDecision

/// What to do when a shell exits under a given policy.
enum ShellExitDecision: Equatable {
    /// Close the tab immediately. Today's behaviour.
    case close
    /// Keep the pane: show a status line, swallow keys, allow restart.
    case keep
}

// MARK: - ShellExitPolicy

/// The decision function: waitpid status word × policy → keep or close?
///
/// Kept as a namespace rather than global functions so the harness can import it
/// unambiguously alongside future additions.
enum ShellExitPolicy {

    /// Decide what to do when the shell exits.
    ///
    /// - Parameters:
    ///   - waitStatus: the raw value from `waitpid(pid, &n, WNOHANG)`, passed through
    ///     by SwiftTerm as `exitCode` in `processTerminated(source:exitCode:)`.
    ///     Nil means SwiftTerm could not obtain a status (I/O error path).
    ///   - mode: the configured `closeOnShellExit` policy.
    /// - Returns: `.close` to remove the pane, `.keep` to leave it showing a status line.
    static func decide(waitStatus: Int32?, mode: CloseOnShellExit) -> ShellExitDecision {
        switch mode {
        case .always: return .close
        case .never:  return .keep
        case .clean:
            guard let ws = waitStatus else { return .keep }  // nil = I/O error = unclean
            // POSIX waitpid status word: WIFEXITED and WEXITSTATUS are C macros that
            // Swift cannot import standalone. We re-implement them as Swift functions
            // above using the identical Darwin arithmetic (sys/wait.h:152,144).
            if WIFEXITED(ws) && WEXITSTATUS(ws) == 0 { return .close }
            return .keep
        }
    }

    // MARK: - Status line text

    /// The inline status line to display in a kept pane.
    ///
    /// - Parameters:
    ///   - waitStatus: raw waitpid status word (nil = I/O error).
    ///   - canRestart: true when the pane supports restart (always true in the
    ///     current implementation; parameter exists so the gate can cover both paths).
    /// - Returns: a human-readable string; the terminal renderers it as a plain line.
    static func statusLine(waitStatus: Int32?, canRestart: Bool) -> String {
        let exitDescription = exitDescription(waitStatus: waitStatus)
        let restart = canRestart ? " — press Return to restart, ⌘W to close" : " — press ⌘W to close"
        return "[\(exitDescription)\(restart)]"
    }

    /// The exit description component of the status line.
    ///
    /// Separated so the gate can cover it independently of the full status-line format.
    static func exitDescription(waitStatus: Int32?) -> String {
        guard let ws = waitStatus else {
            return "process exited"
        }
        if WIFEXITED(ws) {
            let code = WEXITSTATUS(ws)
            return "process exited with code \(code)"
        }
        if WIFSIGNALED(ws) {
            let sig = WTERMSIG(ws)
            return "terminated by \(signalName(sig))"
        }
        // WIFSTOPPED etc. — should not reach a terminal's exit callback, but handled safely.
        return "process exited"
    }

    // MARK: - Signal naming

    /// Human-readable POSIX signal name. Covers the subset a shell user is likely to encounter.
    ///
    /// Numbers rather than strsignal(3) to stay Foundation-only and avoid locale dependency.
    /// Covers SIGKILL (9), SIGTERM (15), SIGQUIT (3), SIGINT (2), SIGHUP (1), SIGPIPE (13),
    /// SIGABRT (6), SIGSEGV (11), SIGBUS (10) — the signals most shells, CLIs, and editors see
    /// in practice. Falls back to `signal \(n)` for everything else.
    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGHUP:  return "SIGHUP"
        case SIGINT:  return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGABRT: return "SIGABRT"
        case SIGKILL: return "SIGKILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGPIPE: return "SIGPIPE"
        case SIGALRM: return "SIGALRM"
        case SIGTERM: return "SIGTERM"
        case SIGUSR1: return "SIGUSR1"
        case SIGUSR2: return "SIGUSR2"
        case SIGBUS:  return "SIGBUS"
        default:      return "signal \(sig)"
        }
    }
}
