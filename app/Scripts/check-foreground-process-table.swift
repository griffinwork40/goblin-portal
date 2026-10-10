//
// check-foreground-process-table.swift
// Part (a) of check-foreground-process.sh: the pure truth table over
// `ForegroundProcess.kind(executableName:pid:integratedShellPid:clientTTY:)`. Compiled
// beside the harness (copied to main.swift) and the shipped ForegroundProcess.swift;
// never run alone.
//
// WHY ITS OWN FILE. The exec rows (B1 of the 2026-10-09 review) pushed the single harness
// past the 350-line ceiling; the truth table is a whole concern with no pty in it, so it
// is the seam (AFK.md, "Conventions").
//

import Darwin
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ✓ " : "  ✗ ") + name + (detail.isEmpty ? "" : "   [\(detail)]"))
    if !ok { failures += 1 }
}

func runKindTruthTable() {
    // ─────────────────────────────────────────────────────────────────────────────
    // Part (a): truth table over kind(executableName:pid:integratedShellPid:clientTTY:)
    // ─────────────────────────────────────────────────────────────────────────────
    print("ForegroundProcess — kind() truth table")

    let shellPid:  pid_t = 1000   // the "integrated shell" in this table
    let otherPid:  pid_t = 2000   // any foreground pid that is NOT the shell's
    let tty = "/dev/ttys099"

    // Shells: every name from the contract (AFK.md wave-0 doc).
    for name in ["zsh","bash","sh","dash","fish","ksh","mksh","tcsh","csh",
                 "nu","elvish","xonsh","pwsh"] {
        let k = ForegroundProcess.kind(executableName: name, pid: otherPid,
                                       integratedShellPid: shellPid, clientTTY: tty)
        if case .knownShell = k {
            check("kind(\(name)) → .knownShell", true)
        } else {
            check("kind(\(name)) → .knownShell", false, "\(k)")
        }
    }

    // pid equality: the integrated shell itself must map to .shell, not .knownShell.
    let shellItself = ForegroundProcess.kind(executableName: "zsh", pid: shellPid,
                                             integratedShellPid: shellPid, clientTTY: tty)
    check("kind(zsh, pid==shellPid) → .shell (not .knownShell)", shellItself == .shell,
          "\(shellItself)")

    // Case-sensitive: "Zsh" is not a shell name returned by the kernel.
    let upperK = ForegroundProcess.kind(executableName: "Zsh", pid: otherPid,
                                        integratedShellPid: shellPid, clientTTY: tty)
    if case .command(let n) = upperK {
        check("kind('Zsh') → .command (case-sensitive)", n == "Zsh", "\(upperK)")
    } else { check("kind('Zsh') → .command (case-sensitive)", false, "\(upperK)") }

    // tmux with tty → .tmuxClient(pid:tty:)
    let tmuxWith = ForegroundProcess.kind(executableName: "tmux", pid: otherPid,
                                          integratedShellPid: shellPid, clientTTY: tty)
    if case .tmuxClient(let p, let t) = tmuxWith {
        check("kind(tmux, tty=…) → .tmuxClient", p == otherPid && t == tty, "\(tmuxWith)")
    } else { check("kind(tmux, tty=…) → .tmuxClient", false, "\(tmuxWith)") }

    // tmux without tty → .command("tmux")  [fail-closed: no tty → can't pass to tmux]
    let tmuxNil = ForegroundProcess.kind(executableName: "tmux", pid: otherPid,
                                         integratedShellPid: shellPid, clientTTY: nil)
    if case .command(let n) = tmuxNil {
        check("kind(tmux, tty=nil) → .command (fail-closed)", n == "tmux", "\(tmuxNil)")
    } else { check("kind(tmux, tty=nil) → .command (fail-closed)", false, "\(tmuxNil)") }

    // Remote programs.
    for name in ["ssh","mosh-client","mosh","et","autossh"] {
        let k = ForegroundProcess.kind(executableName: name, pid: otherPid,
                                       integratedShellPid: shellPid, clientTTY: tty)
        if case .remote(let n) = k {
            check("kind(\(name)) → .remote", n == name, "\(k)")
        } else { check("kind(\(name)) → .remote", false, "\(k)") }
    }

    // Other multiplexers.
    for name in ["screen","zellij","abduco","dtach"] {
        let k = ForegroundProcess.kind(executableName: name, pid: otherPid,
                                       integratedShellPid: shellPid, clientTTY: tty)
        if case .otherMultiplexer(let n) = k {
            check("kind(\(name)) → .otherMultiplexer", n == name, "\(k)")
        } else { check("kind(\(name)) → .otherMultiplexer", false, "\(k)") }
    }

    // sudo/su/doas → .command (fail-closed: cwd is root-owned, unreadable to us).
    for name in ["sudo","su","doas"] {
        let k = ForegroundProcess.kind(executableName: name, pid: otherPid,
                                       integratedShellPid: shellPid, clientTTY: tty)
        if case .command(let n) = k {
            check("kind(\(name)) → .command (fail-closed)", n == name, "\(k)")
        } else { check("kind(\(name)) → .command (fail-closed)", false, "\(k)") }
    }

    // Ordinary command.
    let vimK = ForegroundProcess.kind(executableName: "vim", pid: otherPid,
                                       integratedShellPid: shellPid, clientTTY: tty)
    if case .command(let n) = vimK {
        check("kind(vim) → .command", n == "vim", "\(vimK)")
    } else { check("kind(vim) → .command", false, "\(vimK)") }

    // Path-like name: a name with "/" must still resolve to .command (kernel gives basename,
    // but guard the table against a caller accidentally passing a full path).
    let pathLike = ForegroundProcess.kind(executableName: "/usr/bin/python3", pid: otherPid,
                                           integratedShellPid: shellPid, clientTTY: tty)
    if case .command = pathLike {
        check("kind('/usr/bin/python3') → .command (path-like, not a shell)", true, "\(pathLike)")
    } else { check("kind('/usr/bin/python3') → .command (path-like)", false, "\(pathLike)") }

    // Empty name → .command("") — must not crash.
    let emptyK = ForegroundProcess.kind(executableName: "", pid: otherPid,
                                         integratedShellPid: shellPid, clientTTY: tty)
    if case .command(let n) = emptyK {
        check("kind(\"\") → .command (empty name, no crash)", n == "", "\(emptyK)")
    } else { check("kind(\"\") → .command (empty, no crash)", false, "\(emptyK)") }


    // ── exec'd programs keep the shell's pid ─────────────────────────────────────
    // `exec tmux new -A` (a common .zshrc line), `exec ssh host` and `exec bash` replace
    // the pane's shell IN PLACE: the pid is still integratedShellPid, the program is not
    // the shell. Classification must be by name first, or tmux reads as `.shell` (the
    // sidebar follows the tmux client's launch dir) and ssh reads as `.shell` (cd Here
    // types into the remote machine). Review finding B1, 2026-10-09.
    let execTmux = ForegroundProcess.kind(executableName: "tmux", pid: shellPid,
                                          integratedShellPid: shellPid, clientTTY: tty)
    check("exec: kind(tmux, pid==shellPid) → .tmuxClient",
          execTmux == .tmuxClient(pid: shellPid, tty: tty), "\(execTmux)")
    let execSsh = ForegroundProcess.kind(executableName: "ssh", pid: shellPid,
                                         integratedShellPid: shellPid, clientTTY: tty)
    check("exec: kind(ssh, pid==shellPid) → .remote", execSsh == .remote(name: "ssh"), "\(execSsh)")
    let execScreen = ForegroundProcess.kind(executableName: "screen", pid: shellPid,
                                            integratedShellPid: shellPid, clientTTY: tty)
    check("exec: kind(screen, pid==shellPid) → .otherMultiplexer",
          execScreen == .otherMultiplexer(name: "screen"), "\(execScreen)")
    // The pane's own shell exec'ing a shell (`exec bash`, `exec zsh -l` to reload) is
    // still the pane's shell: same pid, so `.shell`, and its kernel cwd is the shell's.
    for name in ["bash", "zsh", "fish"] {
        let k = ForegroundProcess.kind(executableName: name, pid: shellPid,
                                       integratedShellPid: shellPid, clientTTY: tty)
        check("exec: kind(\(name), pid==shellPid) → .shell", k == .shell, "\(k)")
    }
    // A non-shell program exec'd in place (`exec vim`, `exec agent-afk`): `.command`, so
    // typing is refused, and the cwd rule reads the shell PID's cwd, which is now that
    // program's own cwd — the only process there is (ShellContext.swift header).
    let execVim = ForegroundProcess.kind(executableName: "vim", pid: shellPid,
                                         integratedShellPid: shellPid, clientTTY: tty)
    check("exec: kind(vim, pid==shellPid) → .command", execVim == .command(name: "vim"), "\(execVim)")
    let execSudo = ForegroundProcess.kind(executableName: "sudo", pid: shellPid,
                                          integratedShellPid: shellPid, clientTTY: tty)
    check("exec: kind(sudo, pid==shellPid) → .command (fail-closed)",
          execSudo == .command(name: "sudo"), "\(execSudo)")

    // An unlisted LOGIN shell at its own pid (adoptingLaunchedShell): `.shell`, so its
    // user is not refused every typing action. Only `.command` with the launched name
    // is upgraded; exec'd programs and other pids are not.
    let ksh93 = ForegroundProcess.kind(executableName: "ksh93", pid: shellPid,
                                       integratedShellPid: shellPid, clientTTY: tty)
    let adopt = { (k: ForegroundKind?, atShell: Bool, launched: String) in
        ForegroundProcess.adoptingLaunchedShell(k, foregroundIsShellPid: atShell,
                                                launchedShellName: launched) }
    check("launched ksh93 at its own pid → .shell", adopt(ksh93, true, "ksh93") == .shell,
          "\(String(describing: adopt(ksh93, true, "ksh93")))")
    check("ksh93 NOT at the shell pid → unchanged", adopt(ksh93, false, "ksh93") == ksh93)
    check("exec vim at the shell pid (launched zsh) → still .command",
          adopt(.command(name: "vim"), true, "zsh") == .command(name: "vim"))
    check("exec afk at the shell pid (launched zsh) → still .command",
          adopt(.command(name: "afk"), true, "zsh") == .command(name: "afk"))
    let tmuxK = ForegroundKind.tmuxClient(pid: shellPid, tty: tty)
    check("a tmux client is never upgraded, even if launched as the shell",
          adopt(tmuxK, true, "tmux") == tmuxK)
    check("empty launched name → unchanged", adopt(ksh93, true, "") == ksh93)
    check("nil foreground → nil", adopt(nil, true, "ksh93") == nil)
}
