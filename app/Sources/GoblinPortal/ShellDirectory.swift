//
//  ShellDirectory.swift
//  Asking a running shell where it is, and telling it to go somewhere else.
//
//  Pure and view-free on purpose — `Foundation` and `Darwin` only, no AppKit and no
//  SwiftTerm. That is not tidiness: it is what lets `Scripts/check-cwd-follow.sh`
//  compile this one file directly with `swiftc` and run a truth table over it, the
//  same trick `KeyBindings.swift` plays for `check-keybindings.sh`. In a repo with no
//  test target and no CI (AFK.md, "Checks"), a concern that cannot be compiled alone
//  cannot be gated alone, so the dependency-free boundary IS the testability.
//
//  Both directions of cwd-follow pass through here: `workingDirectory(of:)` reads where a
//  shell is (feeding `ShellDirectoryPolicy.resolve`, and from there the sidebar root, ⌘T
//  and splits), and `cdCommand(to:)` builds the line that moves it (written back through
//  `ShellHosting.send(text:)`). Keeping the read and the write together is deliberate
//  — they are inverse halves of one contract, and the symlink normalisation the read
//  applies is exactly what makes a write's echo compare equal and stop the loop.
//
//  WHICH PROCESS IS ASKED is no longer decided here. This file used to answer
//  `current(foregroundOf:fallbackPid:)`: the cwd of the pty's FOREGROUND process, on the
//  argument that the sidebar should show what a REPL or installer had `chdir`ed to. That
//  rationale is RETIRED (plan `.afk/plans/tmux-ssh-cwd-and-158-parallel.md`, coordinator
//  decision 1): following the foreground moved the sidebar into agent-afk's worktree,
//  into a tmux client's launch directory, and into whatever `ssh` was started from. The
//  choice of pid now belongs to `ShellContext.swift` and its caller
//  (`TerminalPane+DirectoryState.swift`), which ask only for the pane's own shell or a
//  nested local shell; this file reads a given pid and nothing else. The foreground
//  reader was deleted rather than kept: with no caller, it was only a way back to the bug.
//
//  OSC 7 AND THE KERNEL POLL. The kernel read here is PRIMARY while the shell (or a
//  command it runs) is in front; a LOCAL OSC 7 report is the fallback when this read
//  fails. `shell-integration.zsh` (Resources/) emits OSC 7 only in its precmd hook, so a
//  report predates any `cd` on the current command line (`cd ~/proj && afk`) — the
//  reason the order was reversed (review finding B2, 2026-10-09; `ShellContext.swift`).
//  The kernel path also works on any shell and requires no user action.
//

import Darwin
import Foundation

/// Reading and directing a live shell's working directory.
///
/// A namespace, not a type: there is no state to hold. Also deliberately not
/// `@MainActor`, unlike every type in this app — these are pure functions over a pid
/// and a `URL`, safe to call from anywhere, and annotating them would force the
/// isolation onto a future caller that has no reason to want it.
enum ShellDirectory {
    /// The working directory of one specific process, or nil if it cannot be answered.
    /// The caller has already decided WHICH process answers (`ShellContext.swift`): the
    /// pane's own shell (`LocalProcess.shellPid`,
    /// `vendor/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:70`) or a nested local
    /// shell, never an arbitrary foreground command.
    ///
    /// Nil is a normal, expected answer, not an error to report: it happens while a
    /// pane is still starting, and every time between a shell exiting and its pane
    /// closing. Callers hold their last good value rather than reacting to nil —
    /// blanking the sidebar because a shell exited would be worse than stale. A
    /// non-positive pid is "nothing to ask": pid 0 is the caller's own process group and
    /// negative pids are not pids, so passing either to `proc_pidinfo` would ask about
    /// the wrong process entirely.
    static func workingDirectory(of pid: pid_t) -> URL? {
        guard pid > 0, let path = workingDirectoryPath(of: pid) else { return nil }

        // `standardizedFileURL` first (collapse `.`/`..`, strip a trailing slash) and
        // then `resolvingSymlinksInPath()`, so `/tmp` and `/private/tmp` — or any
        // symlinked checkout — reduce to one spelling. Note the direction, which is
        // the opposite of what the name suggests and was verified rather than assumed:
        // Foundation canonicalises **toward** the short form, so both `/tmp/x` and
        // `/private/tmp/x` come back as `/tmp/x` (and `/private/var` as `/var`). It is
        // documented on `NSString.standardizingPath` — a leading `/private` is dropped
        // when the result still names an existing file — and it is why the kernel's own
        // answer here, which is always the `/private`-prefixed vnode path, does not
        // compare equal to a `URL` the UI built from a `FileNode` until it goes through
        // this call. Both sides converge, which is all the guard needs. This
        // normalisation is
        // load-bearing rather than cosmetic: `FileTreeViewController.setRoot(_:)`
        // early-returns on an unchanged root by comparing resolved paths, and that
        // comparison is the only thing standing between cwd-follow and an infinite
        // UI -> shell -> UI loop. It also matches the normalisation
        // `AppDelegate.openFolder` and `SpaceRestore` already apply, so a Space's
        // identity root and its followed directory are spelled the same way.
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The line that moves a shell to `url`, newline included so it submits.
    ///
    /// Submitting is the difference between this and "Insert Path in Terminal"
    /// (`SpaceViewController+Delegates.swift`), which deliberately leaves its text on
    /// the prompt because inserting a path is for *composing* a command. Here the
    /// command IS the whole intent, so leaving it unsubmitted would make a sidebar
    /// click look broken until the user also pressed Return.
    ///
    /// `cd --` is not used: a leading-dash directory is already impossible to reach
    /// here because every path this receives is absolute (it comes from a `FileNode`
    /// or an `NSPathControl` item, never from typing), and `cd -- '/x'` would print an
    /// error on shells that do not accept `--`.
    static func cdCommand(to url: URL) -> String {
        "cd " + singleQuoted(url.path) + "\n"
    }

    /// POSIX single-quote wrapping: everything inside a single-quoted string is
    /// literal to the shell, which is what makes spaces, `$`, backticks, `;`, `&&`,
    /// newlines and glob characters in a filename safe. The one character that cannot
    /// appear inside is `'` itself, so each is closed-escaped-reopened as `'\''`.
    ///
    /// Internal rather than private so the gate script can exercise it directly, and
    /// deliberately the same rule `didRequestPathInsert` already applies
    /// (`SpaceViewController+Delegates.swift:104`) — two different quoting
    /// conventions writing to the same shell is how one of them ends up wrong.
    static func singleQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Strict foreground observation for close confirmation (main's tranche 2). Unlike
    /// the cwd rule, there is no fallback: a closed pty must not consult a stale shell
    /// PID, so a failed `tcgetpgrp` (-1, or a non-positive group) is nil. It used to
    /// share `foregroundPid(childfd:fallbackPid:)` with the cwd fallback; that helper was
    /// retired with foreground-following (`ShellContext.swift` header), so the one
    /// syscall it needs is inlined here (LocalProcess.swift:67,70 for `childfd`).
    static func foregroundProcess(childfd: Int32) -> (group: pid_t, name: String?)? {
        guard childfd >= 0 else { return nil }
        let group = tcgetpgrp(childfd)
        guard group > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = proc_name(group, &bytes, UInt32(bytes.count))
        let name = count > 0 ? bytes.withUnsafeBufferPointer {
            $0.baseAddress.map { String(cString: $0) }
        } : nil
        return (group, name)
    }

    // MARK: - The syscall

    /// A process's current directory, straight from the kernel.
    ///
    /// `PROC_PIDVNODEPATHINFO` fills a `proc_vnodepathinfo` whose `pvi_cdir` is the
    /// cwd vnode; `vip_path` is its absolute path as a fixed C buffer. Verified to
    /// work unentitled, same-uid and non-root, parent to its own pty child, before
    /// any of this was written — the probe read a child zsh's cwd correctly, which is
    /// the only reason this approach was chosen over shell integration.
    ///
    /// The `written == size` guard is not defensive noise: `proc_pidinfo` returns the
    /// number of bytes it filled and returns 0 (with `errno == ESRCH`) for a process
    /// that has exited between the caller choosing its pid and this call — a race that
    /// happens in normal use every time a user types `exit`. Anything short of a full
    /// struct means `pvi_cdir` was not populated, so reading it would produce a path
    /// built from uninitialised stack.
    private static func workingDirectoryPath(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard written == size else { return nil }

        // `withUnsafePointer` over the fixed-size C char array rather than any bridged
        // conversion: `vip_path` is a tuple of `CChar` to Swift, which has no
        // `String` initialiser of its own, and rebinding the tuple's address to
        // `CChar` is how its NUL-terminated contents are read. An empty path means
        // the kernel answered with no cwd, which is a nil, not a "".
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }
}
