//
//  TmuxDirectory.swift
//  Asking tmux where the active pane of the client attached to a given tty is.
//
//  Pure and view-free — Foundation and Darwin only — so `check-tmux-directory.sh` can
//  compile it alone and drive it against real tmux servers on isolated sockets.
//
//  WHY THIS EXISTS. Inside tmux, the process in front of a Goblin Portal pane is the tmux
//  CLIENT, and the kernel can only tell us the client's own cwd: wherever tmux was
//  started. The shells tmux runs never reach our pty directly, and the integration script
//  stays silent inside tmux because tmux sets `TERM_PROGRAM=tmux` (measured on tmux 3.6a,
//  2026-10-09). tmux itself, however, tracks every pane's directory, and it identifies a
//  client by its tty — which is exactly the pty slave this app owns:
//
//      tmux -L <socket> display-message -p -c <client tty> '#{pane_current_path}'
//
//  follows window switches, pane switches and `cd` (measured, ~4 ms per spawn). The cost
//  is a subprocess, so callers must never run this on the main thread
//  (`TerminalPane+DirectoryState.swift` caches it off-main).
//
//  CONTRACT FROZEN in wave 0 (K). Lane B owns the bodies. The subprocess machinery —
//  deadline, pipe draining, process-group kill, reaping, finding the binary — lives in
//  `TmuxDirectory+Subprocess.swift`; this file decides which server answers and what
//  its answer means. Gated by `Scripts/check-tmux-directory.sh` against real servers
//  with a real client attached on a pty.
//

import Darwin
import Foundation

/// Resolving a tmux client's active-pane directory. A namespace: there is no state.
enum TmuxDirectory {
    /// The active pane's directory for the tmux client attached to `clientTTY`, or nil on
    /// any failure: tmux missing, no server owns that client, a timeout, or output that
    /// is not an absolute path. Blocking: never call on the main thread.
    ///
    /// - Parameters:
    ///   - clientTTY: the pane's pty slave, e.g. `/dev/ttys012`.
    ///   - socketDirectories: where to look for tmux server sockets. Nil means the
    ///     production locations (`defaultSocketDirectories`). Gates always pass an
    ///     isolated directory so the user's real servers are never contacted.
    ///   - tmuxExecutable: tmux binary to run. Nil means search the usual install
    ///     locations, because an app launched from Finder does not inherit a shell PATH.
    ///   - timeout: an OVERALL deadline across every socket probed, not per socket.
    static func current(
        clientTTY: String,
        socketDirectories: [URL]? = nil,
        tmuxExecutable: String? = nil,
        timeout: TimeInterval = 0.25
    ) -> URL? {
        let deadline = now() + max(0, timeout)
        guard clientTTY.hasPrefix("/"),
              let tmux = resolveExecutable(tmuxExecutable)
        else { return nil }
        let sockets = socketFiles(in: socketDirectories ?? defaultSocketDirectories())

        // EVERY socket is asked, even after one claims the tty, because two claimants is
        // a state we cannot disambiguate and must refuse (the doc comment's contract).
        // The cost is one ~4-6 ms spawn per extra server, and a typical user has one.
        var owner: String?
        for socket in sockets {
            guard now() < deadline else { return nil }
            guard let path = probe(socket, clientTTY: clientTTY, tmux: tmux, deadline: deadline)
            else { continue }
            guard owner == nil else {
                diag("tty \(clientTTY) claimed by more than one server; refusing")
                return nil
            }
            owner = path
        }
        guard let owner else { return nil }
        // Same normalisation as `ShellDirectory.current` (ShellDirectory.swift:78): tmux
        // reports the kernel's `/private/tmp/...` spelling (measured), and the sidebar's
        // root-unchanged guard compares resolved paths, so an unnormalised answer here
        // would read as a directory change on every poll.
        return URL(fileURLWithPath: owner).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// One server's answer for `clientTTY`: the active pane's raw path, or nil when this
    /// server has no client on that tty (or is dead, slow, or says something malformed).
    ///
    /// ONE SPAWN, AND IT CHECKS OWNERSHIP ITSELF. `display-message -c <tty>` does NOT
    /// fail for a tty the server does not own: measured on tmux 3.6a, it exits 0 and
    /// falls back to the server's "best" client — another terminal's client, or none,
    /// printing that client's pane path. Trusting its exit status would hand back a
    /// stranger's directory. So the format asks for `#{client_tty}` too, and only an
    /// exact match counts. That makes `list-clients` first redundant: it would cost a
    /// second spawn on the owning server to learn exactly what this one already proves,
    /// and a dead server fails both the same fast way ("no server running", exit 1).
    ///
    /// `-u` because tmux otherwise decides UTF-8 from LANG/LC_*, which an app launched
    /// from Finder does not have: measured under `env -i`, `café ☕` came back as
    /// `caf_ __`, and inside the gate's LANG-less harness the newline separator in the
    /// format below came back as `_` too, so without `-u` EVERY answer fails to parse
    /// (the `--falsify` no-utf8-flag mutant turns 14 cases red). `-S` with the full socket path, never `-L`, so the server addressed is
    /// exactly the file enumerated and no TMUX_TMPDIR/uid lookup is re-done by tmux.
    /// `-f /dev/null` would be meaningless here (no server is started by this command).
    static func probe(
        _ socket: URL, clientTTY: String, tmux: String, deadline: TimeInterval
    ) -> String? {
        let arguments = ["-u", "-S", socket.path, "display-message", "-p", "-c", clientTTY,
                         "#{client_tty}\n#{pane_current_path}"]
        guard let data = run(tmux, arguments, deadline: deadline),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        // Split on the FIRST newline only: a tty never contains one, a path may contain
        // anything but NUL, and only the single trailing newline tmux adds is removed.
        guard let split = text.firstIndex(of: "\n") else { return nil }
        let tty = String(text[..<split])
        var path = String(text[text.index(after: split)...])
        if path.hasSuffix("\n") { path.removeLast() }
        guard tty == clientTTY, path.hasPrefix("/") else { return nil }
        return path
    }

    /// Every socket file directly inside `directories`, sorted for a deterministic probe
    /// order. tmux keeps one socket per `-L` name in its `tmux-<uid>` directory; anything
    /// else there (a stray regular file) is skipped by checking the file type with
    /// lstat rather than trusting the name. A missing directory contributes nothing.
    static func socketFiles(in directories: [URL]) -> [URL] {
        var sockets: [URL] = []
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() {
                let url = directory.appendingPathComponent(name)
                var info = stat()
                if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK {
                    sockets.append(url)
                }
            }
        }
        return sockets
    }

    private static func diag(_ message: String) {
        guard ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil else { return }
        FileHandle.standardError.write(Data("[diag] tmux-directory: \(message)\n".utf8))
    }

    /// Production socket directories: `$TMUX_TMPDIR/tmux-<uid>` when set, else
    /// `/private/tmp/tmux-<uid>`.
    static func defaultSocketDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        uid: uid_t = getuid()
    ) -> [URL] {
        // tmux's own rule (tmux.c, `expand_paths`/`make_label`): TMUX_TMPDIR when set
        // and non-empty, else _PATH_TMP, which is `/tmp/` on macOS. `/private/tmp` is
        // spelled out because `/tmp` is a symlink to it and the gate's isolation check
        // compares this path against the live default socket directory.
        if let base = environment["TMUX_TMPDIR"], !base.isEmpty {
            return [URL(fileURLWithPath: base).appendingPathComponent("tmux-\(uid)")]
        }
        return [URL(fileURLWithPath: "/private/tmp/tmux-\(uid)")]
    }
}
