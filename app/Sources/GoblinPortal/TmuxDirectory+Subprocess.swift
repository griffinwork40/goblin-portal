//
//  TmuxDirectory+Subprocess.swift
//  Running one tmux command under a hard deadline, and finding the tmux binary.
//
//  Split from `TmuxDirectory.swift` because the two halves fail differently: that file
//  decides WHICH server answers and what the answer means; this one only guarantees that
//  asking cannot hang, deadlock, leak a zombie or leave an orphan behind. Same imports
//  (Foundation/Darwin only) so `check-tmux-directory.sh` compiles both with swiftc alone.
//
//  WHY posix_spawn AND poll(2), NOT `Process` like `GitStatusReader.swift:118-146`. That
//  reader has no deadline: it reads stdout to EOF and then waits, which is right for git
//  and wrong here. A caller (lane C's cache) needs an answer within ~250 ms or none, and
//  the deadline must cover three things `Process` cannot bound together:
//    1. draining stdout AND stderr concurrently — reading one to EOF while the child is
//       blocked writing >64 KB into the other is the deadlock `GitStatusReader` documents;
//    2. a stalled child that never closes its pipes; and
//    3. a GRANDCHILD that inherited the pipes. Killing only the direct child is not
//       enough: a wrapper script (`#!/bin/sh` + `sleep`) dies on SIGKILL while its `sleep`
//       keeps the write end open, so EOF never arrives. The gate's sleeping fake tmux
//       measures exactly this. Hence the child gets its own process group and the
//       timeout path kills the whole group.
//  Every exit path reaps the child with a blocking `waitpid` after SIGKILL, so nothing is
//  left as a zombie (asserted by `check-tmux-directory.sh`).
//

import Darwin
import Foundation

extension TmuxDirectory {
    /// stdout above this is not a path; the child is killed and the probe answers nil.
    /// A real answer is one tty plus one path — well under 4 KB even at PATH_MAX.
    static let outputCap = 64 * 1024

    /// Where tmux is usually installed, in order. An app launched from Finder/the Dock
    /// inherits launchd's minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which finds
    /// none of the package-manager installs, so these come first and PATH is the
    /// fallback (Homebrew arm64, Homebrew x86/manual, MacPorts, system).
    static let executableSearchDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin",
    ]

    /// The tmux binary to run: the explicit one when given (nil if not executable),
    /// else the first executable `tmux` in the search directories, then PATH.
    static func resolveExecutable(_ explicit: String?) -> String? {
        let fm = FileManager.default
        if let explicit {
            return explicit.hasPrefix("/") && fm.isExecutableFile(atPath: explicit)
                ? explicit : nil
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in executableSearchDirectories + pathDirs where dir.hasPrefix("/") {
            let candidate = dir + "/tmux"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Monotonic seconds; immune to wall-clock changes mid-probe.
    static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    /// Run `executable arguments…` and return its stdout if it exits 0 before
    /// `deadline` (a `now()` value) with at most `outputCap` bytes of stdout.
    /// Nil for a spawn failure, non-zero exit, oversize output or a missed deadline;
    /// in the last two cases the child's whole process group is SIGKILLed and reaped.
    static func run(_ executable: String, _ arguments: [String], deadline: TimeInterval) -> Data? {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return nil }
        guard pipe(&errPipe) == 0 else { close(outPipe[0]); close(outPipe[1]); return nil }
        // CLOEXEC on all four ends at once, so a concurrent spawn elsewhere in the app
        // (SwiftTerm's forkpty, a git poll) cannot inherit them and hold our pipes open.
        // Our own child still gets its two ends: dup2 file actions clear the flag.
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        defer { close(outPipe[0]); close(errPipe[0]) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETPGROUP with pgroup 0: the child leads a new process group, which is what
        // lets the timeout path kill grandchildren too (header, point 3).
        // CLOEXEC_DEFAULT: the child inherits fds 0-2 and nothing else of ours.
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for arg in argv { free(arg) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        close(outPipe[1]); close(errPipe[1])
        guard spawned == 0, pid > 0 else { return nil }

        guard let stdout = drain(stdout: outPipe[0], stderr: errPipe[0], deadline: deadline) else {
            killGroup(pid)
            return nil
        }
        guard let status = reap(pid, deadline: deadline) else { return nil }
        return status == 0 ? stdout : nil
    }

    /// Read both pipes to EOF, concurrently, via poll(2). stderr is read and discarded
    /// (tmux prints "no server running on …" there for a stale socket) — but it IS read,
    /// because an unread stderr is the deadlock in the header. Nil on deadline or when
    /// stdout passes `outputCap`.
    private static func drain(stdout out: Int32, stderr err: Int32, deadline: TimeInterval) -> Data? {
        var collected = Data()
        var fds = [pollfd(fd: out, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: err, events: Int16(POLLIN), revents: 0)]
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while fds.contains(where: { $0.fd >= 0 }) {
            let remaining = deadline - now()
            guard remaining > 0 else { return nil }
            let ready = poll(&fds, nfds_t(fds.count), Int32(min(remaining * 1000, 60_000)) + 1)
            if ready < 0 { if errno == EINTR { continue }; return nil }
            for index in fds.indices where fds[index].fd >= 0 && fds[index].revents != 0 {
                let count = read(fds[index].fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { fds[index].fd = -1; continue }  // EOF or error: stop polling it
                if index == 0 {
                    collected.append(contentsOf: buffer[0..<count])
                    if collected.count > outputCap { return nil }
                }
            }
        }
        return collected
    }

    /// The child's exit status once it exits, polling until `deadline`; past it, the
    /// group is killed and reaped and the answer is nil. Pipes at EOF do not prove the
    /// child exited — it may have closed them and stalled.
    private static func reap(_ pid: pid_t, deadline: TimeInterval) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                // WIFEXITED/WEXITSTATUS are C macros Swift does not import; this is
                // their definition from <sys/wait.h>.
                return (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
            }
            if result < 0 && errno != EINTR { return nil }
            if now() >= deadline { killGroup(pid); return nil }
            usleep(500)
        }
    }

    /// SIGKILL the child's whole process group, then reap the child so it never lingers
    /// as a zombie. SIGKILL cannot be caught, so the blocking wait returns promptly.
    private static func killGroup(_ pid: pid_t) {
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)  // belt and braces if the group was already gone
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}
