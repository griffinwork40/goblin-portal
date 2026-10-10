//
//  check-tmux-directory-fixtures.swift
//  The fixture half of Scripts/check-tmux-directory.sh: real tmux servers on isolated
//  sockets, and REAL clients attached to them on real ptys.
//
//  Not part of the app (`Package.swift` globs `Sources/GoblinPortal` only). The gate
//  compiles this beside `check-tmux-directory-harness.swift` (copied to `main.swift`)
//  and the two shipped units under test.
//
//  WHY A SEPARATE FILE. The harness's assertions plus this machinery would exceed the
//  350-line ceiling in one file, and the seam is the same one check-git-status.sh uses:
//  this file BUILDS the world (servers, clients, fake binaries), the harness ASSERTS
//  about what `TmuxDirectory` saw in it.
//
//  WHY A REAL CLIENT. `display-message -c <tty>` answers for a server's clients, and a
//  detached server has none, so a gate without an attached client could only ever test
//  the nil path. The client here is `tmux attach` spawned as a session leader
//  (POSIX_SPAWN_SETSID) with an openpty slave as fds 0-2 — the same shape as the
//  coordinator's Python `pty.fork()` probe — and `list-clients` is asserted to report
//  that exact slave path before any case runs.
//
//  ISOLATION. Every tmux command below goes through `Fixture.tmux`, which ALWAYS passes
//  `-S <socket under GATE_WORK>` and `-f /dev/null`. No command here relies on -L, the
//  default socket, TMUX_TMPDIR lookup or the user's ~/.tmux.conf.
//
import Darwin
import Foundation

enum Fixture {
    static let env = ProcessInfo.processInfo.environment
    static let work = env["GATE_WORK"] ?? ""
    static let tmuxBinary = env["GATE_TMUX"] ?? ""

    /// The socket directory every real server lives in.
    static var socketDir: URL { URL(fileURLWithPath: work).appendingPathComponent("tmux-\(getuid())") }

    static func fail(_ why: String) -> Never { print("ENV: " + why); exit(2) }

    /// Run the REAL tmux against one isolated socket. Returns (status, stdout).
    @discardableResult
    static func tmux(_ socket: URL, _ args: [String]) -> (Int32, String) {
        precondition(socket.path.hasPrefix(work + "/"), "fixture socket escaped GATE_WORK")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxBinary)
        process.arguments = ["-u", "-f", "/dev/null", "-S", socket.path] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return (process.terminationStatus, text.trimmingCharacters(in: .newlines))
    }

    /// Start a detached server whose first pane runs /bin/sh in `directory`.
    static func startServer(_ socket: URL, in directory: URL) {
        let (status, _) = tmux(socket, ["new-session", "-d", "-s", "gate", "-x", "80", "-y", "24",
                                         "-c", directory.path, "/bin/sh"])
        guard status == 0 else { fail("could not start a tmux server on \(socket.path)") }
    }

    /// A server that is dead but whose socket FILE remains: what a crashed or
    /// SIGKILLed tmux leaves behind. Measured on tmux 3.6a: after `kill -9` of the
    /// server pid the socket file survives, and `display-message` against it prints
    /// "no server running" and exits 1 in ~6 ms.
    static func makeStaleSocket(_ socket: URL, scratch: URL) {
        startServer(socket, in: scratch)
        let (_, pidText) = tmux(socket, ["display-message", "-p", "#{pid}"])
        guard let pid = pid_t(pidText), pid > 0 else { fail("no pid for stale fixture") }
        kill(pid, SIGKILL)
        for _ in 0..<200 where kill(pid, 0) == 0 { usleep(10_000) }
        guard FileManager.default.fileExists(atPath: socket.path) else {
            fail("stale fixture lost its socket file — tmux behaviour changed")
        }
    }

    /// A real tmux client attached to `socket` on a fresh pty.
    final class Client {
        let pid: pid_t
        let master: Int32
        let tty: String
        private var drained = true

        init(attachingTo socket: URL) {
            var master: Int32 = -1, slave: Int32 = -1
            var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0, let name = ttyname(slave) else {
                Fixture.fail("openpty failed")
            }
            tty = String(cString: name)
            self.master = master
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            for fd in Int32(0)...2 { posix_spawn_file_actions_adddup2(&actions, slave, fd) }
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
            var environment = Fixture.env
            environment["TERM"] = "xterm-256color"
            environment["TMUX"] = nil
            let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            let argv: [UnsafeMutablePointer<CChar>?] = [Fixture.tmuxBinary, "-u", "-f", "/dev/null", "-S",
                                                        socket.path, "attach"].map { strdup($0) } + [nil]
            var pid: pid_t = 0
            let rc = posix_spawn(&pid, Fixture.tmuxBinary, &actions, &attributes, argv, envp)
            argv.forEach { free($0) }; envp.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes)
            close(slave)
            guard rc == 0 else { Fixture.fail("could not spawn tmux attach") }
            self.pid = pid
            // Drain the client's screen output forever, or a full pty buffer would
            // eventually block the client and, through it, the server's redraws.
            let fd = master
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while read(fd, &buffer, buffer.count) > 0 {}
            }
            // Ownership is asserted against tmux itself, not assumed.
            for _ in 0..<300 {
                if Fixture.tmux(socket, ["list-clients", "-F", "#{client_tty}"]).1
                    .split(separator: "\n").contains(where: { String($0) == tty }) { return }
                usleep(10_000)
            }
            Fixture.fail("client on \(tty) never appeared in list-clients for \(socket.path)")
        }

        /// SIGKILL and reap, so the gate's closing zombie check sees no stragglers.
        func terminate() {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }

    /// Write an executable `#!/bin/sh` fake tmux. Its arguments arrive exactly as the
    /// shipped probe passes them, so `$7` is the client tty (see `TmuxDirectory.probe`).
    static func fake(_ name: String, _ body: String) -> String {
        let path = work + "/fakes/" + name
        try? FileManager.default.createDirectory(atPath: work + "/fakes", withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: Data(("#!/bin/sh\n" + body + "\n").utf8),
                                             attributes: [.posixPermissions: 0o755])
        else { fail("could not write fake \(name)") }
        return path
    }

    /// A fresh directory under the work root, created on disk.
    static func directory(_ name: String) -> URL {
        let url = URL(fileURLWithPath: work).appendingPathComponent(name)
        guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
        else { fail("could not create \(name)") }
        return url
    }
}

/// How the shipped code spells a path, so expectations compare like with like.
func normalised(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
