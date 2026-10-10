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
//    - shell / ordinary command in front → the SHELL's kernel cwd; a local OSC 7 only when
//      that read fails. Never the foreground program's cwd: the sidebar must not follow
//      agent-afk (or any command) into its own worktree, which the old fallback did.
//      Kernel first because OSC 7 is emitted at precmd: for `cd ~/proj && afk` the report
//      predates the `cd`, and a report left by a nested integrated zsh would outrank a
//      non-integrated outer shell forever (review finding B2, 2026-10-09; this reverses
//      the earlier "OSC 7 wins" rule). OSC 7 stays the only source of a remote host.
//    - another local shell in front      → that shell's kernel cwd.
//    - tmux client in front              → tmux's answer for the active pane (cached).
//    - remote / screen / zellij / unknown → nil, so ⌘T and splits fall back to the Space
//      root and nothing stale is persisted. The sidebar shows `followStatus` instead.
//
//  CONTRACT FROZEN in wave 0 (K). Lane C owns `ShellDirectoryPolicy.resolve`, gated by
//  `Scripts/check-shell-context.sh` (layer 1 is the full truth table over it).
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
    ///   - reported: the last OSC 7 report from the pane's own shell. A local one is a
    ///     FALLBACK for `.shell` / `.command` when `shellDirectory` is nil; a remote one
    ///     only labels `.remote`.
    ///   - shellDirectory: the pane's login shell's kernel cwd — primary for `.shell` /
    ///     `.command`.
    ///   - knownShellDirectory: the kernel cwd of a `.knownShell` foreground.
    ///   - tmuxDirectory: the cached tmux answer for the current client, if fresh.
    static func resolve(
        foreground: ForegroundKind?,
        reported: Osc7Directory?,
        shellDirectory: URL?,
        knownShellDirectory: URL?,
        tmuxDirectory: URL?
    ) -> ShellContext {
        // Lane C. Each branch reads ONLY the input that belongs to the program in front;
        // the order of the `switch` is the precedence, and no branch falls through to
        // another's input. That is the whole fix: the old `currentDirectory` let one
        // input (a never-cleared OSC 7 value) answer for every foreground.
        func context(_ directory: URL?, _ status: DirectoryFollowStatus) -> ShellContext {
            ShellContext(foreground: foreground, directory: directory, followStatus: status)
        }
        switch foreground {
        case nil:
            // Unreadable foreground (shell exiting, fd closed): claim nothing. A report
            // or a shell cwd would be a guess about a pane we cannot see into.
            return context(nil, .unavailable)
        case .shell?, .command?:
            // The pane's own shell is in charge of the directory either way: a command
            // runs IN the shell's directory, and whatever it `chdir`s to itself (agent-afk
            // into its worktree, a build into a subdir) is not where the user is. The
            // shell's KERNEL cwd answers: it is live, while a report is from the last
            // prompt and goes stale on `cd X && cmd` (header, B2). A LOCAL report is the
            // fallback only when the kernel read fails (e.g. the shell is not ours to
            // inspect). A `.remote` report here is stale by construction — the remote
            // session is no longer in front — so it is ignored, not treated as "no dir".
            if let shellDirectory { return context(shellDirectory, .local) }
            if case .local(let path)? = reported { return context(URL(fileURLWithPath: path), .local) }
            return context(nil, .local)
        case .knownShell?:
            // A nested local shell (`bash`, `nix-shell`). Any stored report came from
            // the OUTER shell, which is suspended behind it, so only the nested shell's
            // own kernel cwd answers.
            return context(knownShellDirectory, .local)
        case .tmuxClient?:
            // tmux's answer for the active pane, or nil while it is still cold. Never
            // the outer shell's report: the integration script is silent inside tmux
            // (`TERM_PROGRAM=tmux`, plan "Why"), so that report is from before tmux.
            return context(tmuxDirectory, .local)
        case .remote?:
            // Another machine's filesystem: no directory, ever. The host is display-only
            // and only trustworthy when a remote OSC 7 named it. The caller passes a
            // remote report only if it arrived while THIS process group was in front
            // (`TerminalPane+DirectoryState.swift`), so a host here is from this session.
            if case .remote(let host)? = reported { return context(nil, .remote(host: host)) }
            return context(nil, .remote(host: nil))
        case .otherMultiplexer(let name)?:
            // screen / zellij: we cannot ask for the active pane, so we say so.
            return context(nil, .paused(program: name))
        }
    }
}
