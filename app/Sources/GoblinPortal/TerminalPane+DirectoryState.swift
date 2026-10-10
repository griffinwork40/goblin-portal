//
//  TerminalPane+DirectoryState.swift
//  `TerminalPane`'s answer to "where is this pane, and what is in front of it?":
//  the `ShellHosting.shellContext` / `refreshDirectoryState()` conformance, the stored
//  OSC 7 reports, and the asynchronous tmux-directory cache.
//
//  WHY THIS EXISTS. Five readers (the sidebar poller, ⌘T, both split directions and split
//  persistence) ask a pane for its directory, on the main thread, many times a second.
//  The rule they need is pure and lives in `ShellContext.swift`; what it needs as INPUT is
//  not: the foreground program (syscalls), the shell's kernel cwd (a syscall), OSC 7
//  reports (pushed by SwiftTerm at any time) and, inside tmux, tmux's own answer, which
//  costs a subprocess (~4 ms measured, `TmuxDirectory.swift:17`, with a 250 ms deadline).
//  A subprocess may never run on the main thread, so tmux's answer is fetched on a private
//  serial queue and cached here, keyed by the client it describes; every other input is
//  read live because it costs microseconds. This file is that gathering, and nothing else.
//
//  Replaces the wave-0 scaffold in `ShellHosting.swift`, which answered with OSC 7 first
//  and then the FOREGROUND process's cwd: under tmux that was the tmux client's launch dir,
//  under an agent REPL the agent's worktree, under ssh a stale local report.
//  Plan: `.afk/plans/tmux-ssh-cwd-and-158-parallel.md`. Gate: `Scripts/check-shell-context.sh`.
//

import AppKit
import Darwin

/// Which tmux client a cached answer describes. tmux names a client by its tty
/// (`display-message -c <tty>`); the pid distinguishes a re-attach on the same pty.
struct TmuxClientKey: Equatable {
    let pid: pid_t
    let tty: String
}

/// One tmux answer and when it was taken. `directory` nil is a real answer ("tmux could
/// not say"), cached like any other so a failing tmux is asked at most twice a second.
struct TmuxCacheEntry: Equatable {
    let key: TmuxClientKey
    let directory: URL?
    /// `ProcessInfo.systemUptime` (monotonic), so a wall-clock change cannot freeze it.
    let sampledAt: TimeInterval
    let generation: Int
}

/// A remote OSC 7 host and the foreground process group that was in front when it
/// arrived. The group is what scopes it to ONE remote session: a later `ssh` is a new
/// process group, so an earlier session's host can never label it.
struct RemoteOsc7Report: Equatable {
    let host: String
    let foregroundGroup: pid_t
}

/// Per-pane directory state. A class held through one associated object, because an
/// extension cannot add stored properties to `TerminalPane` and `TerminalPane.swift` has
/// no headroom (AFK.md, "Conventions").
@MainActor
final class PaneDirectoryState {
    /// The last LOCAL OSC 7 path from this pane's shell, normalised. Kept apart from the
    /// remote report on purpose: an ssh session must not erase it, and it must not label one.
    var localReport: String?
    var remoteReport: RemoteOsc7Report?
    var tmuxCache: TmuxCacheEntry?
    /// The tmux client last seen in front; a change bumps `tmuxGeneration`.
    var tmuxKey: TmuxClientKey?
    /// Bumped whenever the cache is invalidated; a result scheduled under an older
    /// generation is dropped even if its key happens to match again (pid reuse).
    var tmuxGeneration = 0
    /// Non-nil while a query is on the queue: the coalescing flag.
    var tmuxInFlight: TmuxClientKey?
    /// Count of queries ever scheduled. Read by the gate to prove coalescing.
    var tmuxQueriesStarted = 0
    /// For the one-line-per-change diagnostic.
    var lastContext: ShellContext?
}

/// One serial queue for every pane: tmux queries never overlap, so N panes in tmux cost
/// at most one subprocess at a time, and the main thread never waits on any of them.
private let tmuxDirectoryQueue = DispatchQueue(
    label: "com.griffinlong.goblin-portal.tmux-directory", qos: .utility)

/// Older than this, a cached tmux answer is served once more but re-asked. Below the
/// sidebar poller's 750 ms tick (`SpaceViewController+DirectoryFollow.swift:74`), so
/// every tick inside tmux triggers one fresh query.
private let tmuxCacheMaxAge: TimeInterval = 0.5

nonisolated(unsafe) private var directoryStateKey: UInt8 = 0

private func directoryDiag(_ message: String) {
    guard ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil else { return }
    FileHandle.standardError.write(Data("[diag] directory-state: \(message)\n".utf8))
}

@MainActor
extension TerminalPane {
    var directoryState: PaneDirectoryState {
        if let state = objc_getAssociatedObject(self, &directoryStateKey) as? PaneDirectoryState {
            return state
        }
        let state = PaneDirectoryState()
        objc_setAssociatedObject(self, &directoryStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// Live and cheap: `ForegroundProcess.current` (tcgetpgrp + TIOCPTYGNAME +
    /// proc_pidpath), at most one `proc_pidinfo` for a cwd, and a cache read. Never waits;
    /// a missing or old tmux answer schedules a refresh and is served as it stands.
    /// The best record of where this pane's shell last was, for a shell that has
    /// ALREADY EXITED (tranche 2's kept-tab restart and vetoed-close recovery). The live
    /// rule cannot answer then: waitpid has reaped the pid, so `shellContext` reports an
    /// unreadable foreground and a nil directory. A shell exits from a prompt, after
    /// precmd re-reported, so the last local OSC 7 report is current at that moment;
    /// a shell without the integration script falls back to the last directory the
    /// live rule resolved for this pane.
    /// The one way this pane reads its foreground, shared by the getter and the refresh so
    /// they never disagree. An unlisted login shell (`ksh93`) at its own pid is still the
    /// shell (`ForegroundProcess.adoptingLaunchedShell`).
    private func liveForeground(childfd: Int32, shellPid: pid_t) -> ForegroundKind? {
        ForegroundProcess.adoptingLaunchedShell(
            ForegroundProcess.current(childfd: childfd, integratedShellPid: shellPid),
            foregroundIsShellPid: childfd >= 0 && tcgetpgrp(childfd) == shellPid,
            launchedShellName: startedShellName)
    }

    var lastKnownDirectoryPath: String? {
        let state = directoryState
        return state.localReport ?? state.lastContext?.directory?.path
    }

    var shellContext: ShellContext {
        // `view.process` is `LocalProcess!`, nil before `startProcess`.
        guard let process = view.process else {
            return ShellContext(foreground: nil, directory: nil, followStatus: .unavailable)
        }
        let kind = liveForeground(childfd: process.childfd, shellPid: process.shellPid)
        let state = directoryState
        noteForeground(kind, state)

        var shellDirectory: URL?, knownShellDirectory: URL?, tmuxDirectory: URL?
        var tmuxAnswered = false
        var reported: Osc7Directory? = state.localReport.map { .local(path: $0) }
        switch kind {
        case .shell?, .command?:
            // The SHELL's pid, never the foreground's: a command's own `chdir` is not
            // where the user is (ShellContext.swift header).
            shellDirectory = ShellDirectory.workingDirectory(of: process.shellPid)
        case .knownShell(let pid, _)?:
            knownShellDirectory = ShellDirectory.workingDirectory(of: pid)
        case .tmuxClient(let pid, let tty)?:
            let key = TmuxClientKey(pid: pid, tty: tty)
            if let entry = state.tmuxCache, entry.key == key {
                tmuxDirectory = entry.directory
                tmuxAnswered = true
                if ProcessInfo.processInfo.systemUptime - entry.sampledAt > tmuxCacheMaxAge {
                    scheduleTmuxQuery(key, state)
                }
            } else {
                scheduleTmuxQuery(key, state)
            }
        case .remote?:
            // Only a host reported while THIS process group was in front counts.
            let group = tcgetpgrp(process.childfd)
            reported = state.remoteReport.flatMap {
                $0.foregroundGroup == group && group > 0 ? .remote(host: $0.host) : nil
            }
        case .otherMultiplexer?, nil:
            break
        }
        let context = ShellDirectoryPolicy.resolve(
            foreground: kind, reported: reported, shellDirectory: shellDirectory,
            knownShellDirectory: knownShellDirectory, tmuxDirectory: tmuxDirectory,
            tmuxAnswered: tmuxAnswered)
        if context != state.lastContext {
            state.lastContext = context
            directoryDiag("fg=\(kind.map { "\($0)" } ?? "nil") dir=\(context.directory?.path ?? "nil") status=\(context.followStatus)")
        }
        return context
    }

    /// Ask tmux again if a tmux client is in front. Never blocks; while a query is in
    /// flight further calls are no-ops, so a 750 ms poller plus the getter's own
    /// self-refresh can never stack subprocesses.
    func refreshDirectoryState() {
        guard let process = view.process else { return }
        let kind = liveForeground(childfd: process.childfd, shellPid: process.shellPid)
        let state = directoryState
        noteForeground(kind, state)
        if case .tmuxClient(let pid, let tty)? = kind {
            scheduleTmuxQuery(TmuxClientKey(pid: pid, tty: tty), state)
        }
    }

    /// Store a tmux answer, unless the world moved on while it was being fetched: a
    /// different generation (the cache was invalidated since), or a key that is no
    /// longer the live foreground (detached, re-attached, or tmux replaced by something
    /// else). Internal, not private, so the gate can deliver a late answer by hand.
    func deliverTmuxDirectory(_ directory: URL?, for key: TmuxClientKey, generation: Int) {
        let state = directoryState
        guard generation == state.tmuxGeneration, let process = view.process,
              case .tmuxClient(let pid, let tty)? = ForegroundProcess.current(
                  childfd: process.childfd, integratedShellPid: process.shellPid),
              TmuxClientKey(pid: pid, tty: tty) == key
        else {
            directoryDiag("dropped a late tmux answer for \(key.tty) (pid \(key.pid))")
            return
        }
        state.tmuxCache = TmuxCacheEntry(
            key: key, directory: directory,
            sampledAt: ProcessInfo.processInfo.systemUptime, generation: generation)
    }

    /// Invalidate the tmux cache the moment its client is no longer what is in front.
    private func noteForeground(_ kind: ForegroundKind?, _ state: PaneDirectoryState) {
        var key: TmuxClientKey?
        if case .tmuxClient(let pid, let tty)? = kind { key = TmuxClientKey(pid: pid, tty: tty) }
        guard key != state.tmuxKey else { return }
        state.tmuxKey = key
        state.tmuxCache = nil
        state.tmuxGeneration += 1
    }

    /// Put ONE `TmuxDirectory.current` on the serial queue, unless one is already there.
    ///
    /// Only value types cross threads: the key (pid + String), the generation (Int) and
    /// the answer (URL?). The pane is captured weakly — it is `@MainActor`, hence
    /// Sendable, but it is only ever touched back on the main actor — so a pane torn
    /// down mid-query simply receives nothing.
    private func scheduleTmuxQuery(_ key: TmuxClientKey, _ state: PaneDirectoryState) {
        guard state.tmuxInFlight == nil else { return }
        state.tmuxInFlight = key
        state.tmuxQueriesStarted += 1
        let generation = state.tmuxGeneration
        let tty = key.tty
        tmuxDirectoryQueue.async { [weak self] in
            let directory = TmuxDirectory.current(clientTTY: tty)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.directoryState.tmuxInFlight = nil
                    self.deliverTmuxDirectory(directory, for: key, generation: generation)
                }
            }
        }
    }
}
