// check-shell-context-harness.swift
// Layer 2 of check-shell-context.sh: one real TerminalPane running a real, NON-integrated
// login zsh, walked through every foreground state the cwd rule distinguishes. Copied to
// main.swift beside check-shell-context-world.swift; never run directly.
//
// ORDER IS PART OF THE TEST. The ssh case runs before the local OSC 7 case so a STALE
// remote report is in storage when the shell comes back (it must be ignored), and the
// local report is planted before tmux so a STALE local report is in storage while tmux is
// in front (it must not outrank tmux, not even while tmux's answer is still cold).
//
// Exit: 0 all passed, 1 a real assertion failed, 2 environmental (no shell spawned).
//
import AppKit
import SwiftTerm
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    let home = work.appendingPathComponent("home")
    let dirA = makeDir("start"), dirB = makeDir("cd-target"), dirOther = makeDir("other")
    let dirR = makeDir("reported"), dirT = makeDir("tmux-pane"), dirT2 = makeDir("tmux-pane-2")
    let fakeSsh = work.appendingPathComponent("bin/ssh").path
    let q = { (u: URL) in ShellDirectory.singleQuoted(u.path) }

    guard let (pane, win) = startPane(home: home, in: dirA) else {
        print("  ENV  the pane's shell never spawned"); exit(2)
    }
    _ = win

    print("CASE 1 — the pane's own shell")
    var (ctx, _) = poll(pane, 10) { $0.foreground == .shell && $0.directory == dirA }
    expect("fresh pane: .shell in its start directory", ctx.foreground == .shell
           && ctx.directory == dirA && ctx.followStatus == .local, describe(ctx))
    expect("currentDirectory is shellContext.directory", pane.currentDirectory == ctx.directory,
           "currentDirectory=\(pane.currentDirectory?.path ?? "nil")")

    print("CASE 2 — cd follows (kernel cwd of the shell, no OSC 7 in this shell)")
    pane.send(text: "cd \(q(dirB))\n")
    (ctx, _) = poll(pane, 5) { $0.directory == dirB }
    expect("after cd: .shell in the new directory", ctx.foreground == .shell
           && ctx.directory == dirB, describe(ctx))

    print("CASE 3 — a command in front keeps the SHELL's directory, not its own")
    pane.send(text: "(cd \(q(dirOther)) && exec sleep 30)\n")
    (ctx, _) = poll(pane, 5) { isCommand($0.foreground, "sleep") }
    expect("sleep is classified .command", isCommand(ctx.foreground, "sleep"), describe(ctx))
    expect("directory is the shell's (cd-target), not sleep's (other)",
           ctx.directory == dirB, describe(ctx))
    expect("command in front: status .local", ctx.followStatus == .local, describe(ctx))
    pane.send(text: "\u{03}")
    (ctx, _) = poll(pane, 5) { $0.foreground == .shell }
    expect("Ctrl-C returns to .shell", ctx.foreground == .shell && ctx.directory == dirB, describe(ctx))

    print("CASE 4 — a remote session: no directory, the host from its OSC 7")
    pane.send(text: "\(q(URL(fileURLWithPath: fakeSsh)))\n")
    (ctx, _) = poll(pane, 5) {
        isRemote($0.foreground) && $0.followStatus == .remote(host: "other-host")
    }
    expect("fake ssh is classified .remote", isRemote(ctx.foreground), describe(ctx))
    expect("remote: directory nil (never the remote /tmp)", ctx.directory == nil
           && pane.currentDirectory == nil, describe(ctx))
    expect("remote: status names other-host", ctx.followStatus == .remote(host: "other-host"),
           describe(ctx))
    pane.send(text: "\u{03}")
    (ctx, _) = poll(pane, 5) { $0.foreground == .shell }
    expect("after ssh exits: the shell's local directory returns (stale remote ignored)",
           ctx.foreground == .shell && ctx.directory == dirB && ctx.followStatus == .local,
           describe(ctx))

    print("CASE 5 — a local OSC 7 report wins for the shell")
    pane.send(text: "printf '\\033]7;file://localhost%s\\a' \(q(dirR))\n")
    (ctx, _) = poll(pane, 5) { $0.directory == dirR }
    expect("local OSC 7 outranks the kernel cwd under .shell", ctx.foreground == .shell
           && ctx.directory == dirR, describe(ctx))

    print("CASE 6 — tmux: the active pane's directory, asynchronously")
    pane.send(text: "export TMUX_TMPDIR=\(q(work)); \(q(URL(fileURLWithPath: tmuxBin))) "
              + "-L gate -f /dev/null new-session\n")
    var leakedReport = false
    let attachStart = Date()
    (ctx, _) = poll(pane, 10) {
        if isTmux($0.foreground) && $0.directory == dirR { leakedReport = true }
        return isTmux($0.foreground)
    }
    expect("tmux client is classified .tmuxClient", isTmux(ctx.foreground), describe(ctx))
    pane.send(text: "cd \(q(dirT))\n")
    var reads = 0
    (ctx, reads) = poll(pane, 6) {
        if isTmux($0.foreground) && $0.directory == dirR { leakedReport = true }
        return isTmux($0.foreground) && $0.directory == dirT
    }
    expect("inside tmux: directory is the tmux pane's (\(reads) reads)",
           isTmux(ctx.foreground) && ctx.directory == dirT && ctx.followStatus == .local,
           describe(ctx))
    expect("the stale local OSC 7 never outranked tmux, cold or warm", !leakedReport,
           "a read under .tmuxClient returned \(dirR.path)")
    print("    first tmux sample after attach: \(String(format: "%.2f", Date().timeIntervalSince(attachStart)))s")
    pane.send(text: "cd \(q(dirT2))\n")
    (ctx, reads) = poll(pane, 6) { $0.directory == dirT2 }
    expect("a second cd inside tmux is followed (cache refreshes, \(reads) reads)",
           ctx.directory == dirT2, describe(ctx))

    // Non-blocking: the refresh and the getter return without waiting on tmux, whose
    // spawn costs ~4 ms (TmuxDirectory.swift:17). 2.5 ms of headroom is far above the
    // syscall-only cost and below one spawn.
    var worst = 0.0
    for _ in 0..<5 {
        _ = pump(0.6)
        let t0 = Date()
        pane.refreshDirectoryState(); _ = pane.shellContext
        worst = max(worst, Date().timeIntervalSince(t0))
    }
    expect("refreshDirectoryState + shellContext never block (worst \(String(format: "%.2f", worst * 1000)) ms)",
           worst < 0.0025, "worst=\(worst)")

    // Coalescing: fifty requests while one is (or is not) in flight start at most one query.
    _ = pump(0.6)
    let before = pane.directoryState.tmuxQueriesStarted
    for _ in 0..<50 { pane.refreshDirectoryState() }
    let started = pane.directoryState.tmuxQueriesStarted - before
    expect("50 refresh calls start at most one tmux query (started \(started))", started <= 1,
           "started=\(started)")

    print("CASE 7 — a late tmux answer for a client that is no longer in front is dropped")
    guard case .tmuxClient(let pid, let tty)? = pane.shellContext.foreground else {
        fail("tmux left the foreground before the late-delivery case"); exit(1)
    }
    _ = pump(0.5)  // let any in-flight refresh land first
    let state = pane.directoryState
    let staleKey = TmuxClientKey(pid: pid + 100_000, tty: tty)
    pane.deliverTmuxDirectory(URL(fileURLWithPath: "/late/answer"), for: staleKey,
                              generation: state.tmuxGeneration)
    expect("delivery for another client does not enter the cache",
           state.tmuxCache?.directory?.path != "/late/answer",
           "cache=\(state.tmuxCache.map { "\($0)" } ?? "nil")")
    expect("…and is never what a reader sees", pane.currentDirectory?.path != "/late/answer",
           "currentDirectory=\(pane.currentDirectory?.path ?? "nil")")

    print("CASE 8 — detach returns to the shell, and the cache is invalidated")
    pane.send(text: "\u{02}d")
    (ctx, _) = poll(pane, 6) { $0.foreground == .shell }
    expect("after detach: .shell again", ctx.foreground == .shell, describe(ctx))
    expect("after detach: the shell's answer (its last local report)", ctx.directory == dirR,
           describe(ctx))
    expect("after detach: the tmux cache is gone", pane.directoryState.tmuxCache == nil,
           "cache=\(pane.directoryState.tmuxCache.map { "\($0)" } ?? "nil")")
    // A late answer for the detached client, delivered now, must not be stored either.
    pane.deliverTmuxDirectory(URL(fileURLWithPath: "/late/detached"),
                              for: TmuxClientKey(pid: pid, tty: tty),
                              generation: pane.directoryState.tmuxGeneration)
    expect("late answer after detach is dropped", pane.directoryState.tmuxCache == nil
           && pane.currentDirectory == dirR,
           "cache=\(pane.directoryState.tmuxCache.map { "\($0)" } ?? "nil")")

    pane.documentWillClose()
    _ = pump(0.3)
    print("")
    print(bad == 0 ? "all wiring cases passed" : "\(bad) wiring case(s) FAILED")
    exit(bad == 0 ? 0 : 1)
}
