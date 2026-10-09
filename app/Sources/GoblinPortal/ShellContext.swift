//
//  ShellContext.swift
//  One answer to "where is this pane's shell, and may we type into it?".
//
//  Pure and view-free — Foundation only — so `check-shell-context.sh` can compile it with
//  `ForegroundProcess.swift` and `Osc7Directory.swift` and run the whole rule as a table.
//
//  WHY THIS EXISTS. Five features read a pane's working directory (the sidebar poller,
//  ⌘T, both split directions, split persistence) and four type into the pane. Before this
//  file each read `TerminalPane.currentDirectory`, which preferred an OSC 7 value that was
//  never cleared, so tmux and ssh left all of them pointing at a stale or meaningless
//  path. The rule now lives here, once, and every consumer reads its result:
//
//    - shell / ordinary command in front → OSC 7 if local, else the SHELL's kernel cwd.
//      Never the foreground program's cwd: the sidebar must not follow agent-afk (or any
//      command) into its own worktree, which the old kernel fallback did.
//    - another local shell in front      → that shell's kernel cwd.
//    - tmux client in front              → tmux's answer for the active pane (cached).
//    - remote / screen / zellij / unknown → nil, so ⌘T and splits fall back to the Space
//      root and nothing stale is persisted. The sidebar shows `followStatus` instead.
//
//  CONTRACT FROZEN in wave 0 (K). Lane C owns `ShellDirectoryPolicy.resolve`.
//  `TerminalInputPolicy` is final as written: it IS the typing-guard decision.
//

import Foundation

/// What the sidebar should say about following, independent of the directory itself.
enum DirectoryFollowStatus: Equatable {
    /// Following a local directory normally.
    case local
    /// A remote session is in front. `host` is known only when a remote OSC 7 named it.
    case remote(host: String?)
    /// Something we cannot follow is in front (`screen`, `zellij`, …).
    case paused(program: String)
    /// No answer right now (shell starting or exited, tmux not yet resolved).
    case unavailable
}

/// The resolved state of one pane.
struct ShellContext: Equatable {
    let foreground: ForegroundKind?
    /// A LOCAL directory, or nil. Never a remote path, never a stale one.
    let directory: URL?
    let followStatus: DirectoryFollowStatus
}

/// May a shell-directed action type into this pane?
enum TerminalInputPolicy {
    /// True only for a shell or a tmux client. Unknown foreground is refused.
    ///
    /// tmux is allowed because tmux forwards typed text to its active pane, which is
    /// usually a shell; the residual risk (the active pane is vim or an agent) is
    /// documented, not hidden — the outer pty cannot see inside tmux.
    static func allowsTyping(into foreground: ForegroundKind?) -> Bool {
        switch foreground {
        case .shell, .knownShell, .tmuxClient: return true
        case .remote, .otherMultiplexer, .command, nil: return false
        }
    }
}

/// The cwd rule, as a pure function of everything the pane can observe.
enum ShellDirectoryPolicy {
    /// - Parameters:
    ///   - foreground: the classified foreground, nil when unreadable.
    ///   - reported: the last OSC 7 report from the pane's own shell.
    ///   - shellDirectory: the pane's login shell's kernel cwd.
    ///   - knownShellDirectory: the kernel cwd of a `.knownShell` foreground.
    ///   - tmuxDirectory: the cached tmux answer for the current client, if fresh.
    static func resolve(
        foreground: ForegroundKind?,
        reported: Osc7Directory?,
        shellDirectory: URL?,
        knownShellDirectory: URL?,
        tmuxDirectory: URL?
    ) -> ShellContext {
        // K STUB (lane C replaces): behaviour-preserving — a local OSC 7 wins, else the
        // shell's directory, exactly as `currentDirectory` behaved before this file.
        let directory: URL?
        if case .local(let path)? = reported {
            directory = URL(fileURLWithPath: path)
        } else {
            directory = shellDirectory
        }
        return ShellContext(foreground: foreground, directory: directory, followStatus: .local)
    }
}
