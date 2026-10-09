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
//  CONTRACT FROZEN in wave 0 (K). Lane B owns the bodies.
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
        // K STUB (lane B replaces).
        nil
    }

    /// Production socket directories: `$TMUX_TMPDIR/tmux-<uid>` when set, else
    /// `/private/tmp/tmux-<uid>`.
    static func defaultSocketDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        uid: uid_t = getuid()
    ) -> [URL] {
        // K STUB (lane B replaces).
        []
    }
}
