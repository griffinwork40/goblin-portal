//
// check-foreground-process-group.swift
// Part (c) of check-foreground-process.sh: the foreground GROUP, not just its leader.
// Compiled beside the harness (copied to main.swift, which owns `openPtyPair` and
// `spawnForeground`) and the table (which owns `check`); never run alone.
//
// WHY ITS OWN FILE. The group concern (review finding, spec item 1, 2026-10-09) is a
// whole concern — a shebang script is a shell binary leading a group whose other members
// are what the user is actually talking to — and adding it to the harness would cross
// the 350-line ceiling (AFK.md, "Conventions").
//
// CASES:
//  (table)  `refiningByGroup` over member-name lists: alone → .knownShell; + ssh →
//           .remote; + screen → .otherMultiplexer; + sleep → .command; ssh beats screen;
//           nil / empty / unreadable member → refuse (.command); non-.knownShell leaders
//           pass through untouched.
//  (pty)    A REAL interactive zsh (`-o monitor`, so job control gives each command its
//           own group) is the integrated shell. It runs a `#!/bin/bash` script that runs
//           the gate's compiled ssh stand-in WITHOUT exec: the leader is /bin/bash, the
//           group is {bash, ssh}, and the kind must be `.remote(ssh)` — which
//           `TerminalInputPolicy.allowsTyping` refuses (its truth table lives in
//           check-shell-context.sh). Same with /bin/sleep → `.command(sleep)`.
//           CONTROL: an interactive `bash` at its prompt is alone in its group and must
//           still read `.knownShell(bash)`; if it did not, the refinement would be
//           refusing every nested shell and the script cases would prove nothing.
//

import Darwin
import Foundation

func runGroupTable() {
    print("\nForegroundProcess — group refinement truth table")
    let leader = ForegroundKind.knownShell(pid: 42, name: "bash")
    let rows: [(String, [String?]?, ForegroundKind)] = [
        ("alone in its group → .knownShell", ["bash"], leader),
        ("bash + zsh (all shells) → .knownShell", ["bash", "zsh"], leader),
        ("zsh alone → .knownShell", ["zsh"], leader),
        ("script + ssh → .remote(ssh)", ["bash", "ssh"], .remote(name: "ssh")),
        ("script + screen → .otherMultiplexer", ["bash", "screen"], .otherMultiplexer(name: "screen")),
        ("script + sleep → .command(sleep)", ["bash", "sleep"], .command(name: "sleep")),
        ("script + sleep + ssh → .remote (remote outranks)", ["bash", "sleep", "ssh"], .remote(name: "ssh")),
        ("script + screen + mosh → .remote", ["bash", "screen", "mosh"], .remote(name: "mosh")),
        ("script + tmux → .command(tmux) (no tty: fail-closed)", ["bash", "tmux"], .command(name: "tmux")),
        ("enumeration nil → refuse (.command)", nil, .command(name: "bash")),
        ("enumeration empty → refuse (.command)", [], .command(name: "bash")),
        ("unreadable member → refuse (.command)", ["bash", nil], .command(name: "bash")),
    ]
    for (name, members, want) in rows {
        let got = ForegroundProcess.refiningByGroup(leader, memberNames: members)
        check("group: \(name)", got == want, "got=\(got)")
    }
    for other in [ForegroundKind.shell, .command(name: "vim"), .remote(name: "ssh"),
                  .tmuxClient(pid: 1, tty: "/dev/ttys001")] {
        check("group: non-.knownShell leader \(other) passes through",
              ForegroundProcess.refiningByGroup(other, memberNames: ["bash", "ssh"]) == other)
    }
}

/// Type `line` into the pty and poll until `current` stops reading `.shell` and the
/// foreground group is not the shell's (the command has started), up to ~3 s.
private func typeAndWait(_ fd: Int32, _ line: String, shellPid: pid_t,
                         minMembers: Int) -> ForegroundKind? {
    _ = line.withCString { write(fd, $0, strlen($0)) }
    var got: ForegroundKind?
    for _ in 0..<60 {
        usleep(50_000)
        drain(fd)
        let fg = tcgetpgrp(fd)
        got = ForegroundProcess.current(childfd: fd, integratedShellPid: shellPid)
        // Wait for the group to settle: a script that has not yet forked its child is
        // momentarily alone (a documented residual), so require the expected size. The
        // caller states the size from the case itself, never from the typed text (PR #206
        // round-2 review: keying on a "script" substring made the wait depend on a comment).
        if fg > 0, fg != shellPid, let n = ForegroundProcess.groupMemberNames(pgid: fg)?.count,
           n >= minMembers { break }
    }
    return got
}

/// Keep the pty's output buffer from filling (zsh echoes and prompts).
private func drain(_ fd: Int32) {
    var buf = [UInt8](repeating: 0, count: 4096)
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    while read(fd, &buf, buf.count) > 0 {}
    _ = fcntl(fd, F_SETFL, flags)
}

func runGroupPtyCases(workDir: String) {
    print("\nForegroundProcess — foreground group (real pty)")
    let cases: [(label: String, script: String?, want: ForegroundKind)] = [
        ("script wrapper running ssh WITHOUT exec → .remote(ssh) (typing refused)",
         "\(workDir)/bin/ssh", .remote(name: "ssh")),
        ("script wrapper running sleep WITHOUT exec → .command(sleep) (typing refused)",
         "/bin/sleep 10", .command(name: "sleep")),
        ("CONTROL nested interactive bash at its prompt → .knownShell(bash)", nil, .shell),
    ]
    for (index, c) in cases.enumerated() {
        let (fd, slave) = openPtyPair()
        guard let zsh = spawnForeground(slave: slave, program: "/bin/zsh",
                                        extraArgs: ["-f", "-i", "-o", "monitor"]) else {
            print("ENV: helper could not start an interactive zsh"); exit(2)
        }
        usleep(400_000); drain(fd)
        let line: String
        if let body = c.script {
            let path = "\(workDir)/group-script-\(index).sh"
            // `echo` AFTER the child, so bash cannot exec-optimise the last command.
            let text = "#!/bin/bash\n\(body)\necho done\n"
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                           attributes: [.posixPermissions: 0o755])
            line = "\(path) # script\r"
        } else {
            line = "/bin/bash --norc --noprofile -i\r"
        }
        let got = typeAndWait(fd, line, shellPid: zsh, minMembers: c.script == nil ? 1 : 2)
        let fg = tcgetpgrp(fd)
        let members = ForegroundProcess.groupMemberNames(pgid: fg) ?? []
        let detail = "got=\(String(describing: got)) fg=\(fg) zsh=\(zsh) members=\(members)"
        guard fg > 0, fg != zsh else {
            print("ENV: the command never took the foreground [\(detail)]"); exit(2)
        }
        let want = c.script == nil ? ForegroundKind.knownShell(pid: fg, name: "bash") : c.want
        check(c.label, got == want, detail)
        // The consumer's verdict, from the shipped ShellContext.swift compiled into this
        // gate: the scripts must be refused, the nested shell must still be allowed.
        check("\(c.label): allowsTyping == \(c.script == nil)",
              TerminalInputPolicy.allowsTyping(into: got) == (c.script == nil), detail)
        kill(-fg, SIGKILL); kill(zsh, SIGKILL)
        var st: Int32 = 0; waitpid(zsh, &st, 0)
        close(fd)
    }
}
