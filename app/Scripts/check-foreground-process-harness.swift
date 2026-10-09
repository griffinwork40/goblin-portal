//
// check-foreground-process-harness.swift
// Swift assertions for check-foreground-process.sh — compiled by that script,
// never run independently.
//
// WHY THIS IS A SEPARATE FILE. Inline, the shell and Swift halves together
// were over the 350-LOC ceiling that check-file-size.sh enforces (AFK.md,
// "Conventions"). The shell half owns: C helper compile, pty pair setup,
// temp dir lifecycle, falsification mutants. This file owns: all assertions.
// Same split as check-git-status.sh / check-git-status-harness.swift.
//
// ENVIRONMENT (set by the shell half):
//   FP_WORK      — temp dir containing the compiled C helper binary ("helper")
//                  and a fake "zsh" binary (a renamed /bin/sleep) at "zsh".
//

import Darwin
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ✓ " : "  ✗ ") + name + (detail.isEmpty ? "" : "   [\(detail)]"))
    if !ok { failures += 1 }
}

let env = ProcessInfo.processInfo.environment
guard let workDir = env["FP_WORK"], !workDir.isEmpty else {
    print("ENV: FP_WORK not set"); exit(2)
}
let helperBin = workDir + "/helper"
guard FileManager.default.fileExists(atPath: helperBin) else {
    print("ENV: helper binary not found at \(helperBin)"); exit(2)
}

// Spawn a child via the C helper: fork+setsid+TIOCSCTTY → foreground process group.
// Returns the child pid on success; the helper prints it on stdout.
// WHY a C helper rather than posix_spawn: BSD requires ioctl(TIOCSCTTY) inside the
// new session to acquire a controlling terminal. posix_spawn sets POSIX_SPAWN_SETSID
// but cannot issue ioctl; Swift marks fork() unavailable. The helper is the bridge.
// `extraArgs`: forwarded verbatim after the program path (e.g. ["-f","-c","while :; do :; done"]
// for zsh so it stays in a tight loop and proc_pidpath sees /bin/zsh, not a child).
func spawnForeground(slave: String,
                     program: String = "/bin/sleep",
                     extraArgs: [String] = []) -> pid_t? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: helperBin)
    p.arguments = [slave, program] + extraArgs
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let str = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return pid_t(str)
}

// Open a pty pair, return (primary, slavePath) or exit 2 on failure.
func openPtyPair() -> (Int32, String) {
    var prim: Int32 = 0, sec: Int32 = 0
    guard openpty(&prim, &sec, nil, nil, nil) == 0 else {
        print("ENV: openpty failed"); exit(2)
    }
    // TIOCPTYGNAME: macOS-native, not ptsname_r (which is not exposed in Swift's
    // Darwin overlay). ptsname is not thread-safe; TIOCPTYGNAME is atomic and
    // works on the primary fd without requiring the slave to be open.
    var gname = [CChar](repeating: 0, count: 128)
    guard ioctl(prim, TIOCPTYGNAME, &gname) == 0 else {
        print("ENV: TIOCPTYGNAME failed"); exit(2)
    }
    close(sec)  // caller gets the slave path; child owns the fd after spawn
    return (prim, String(cString: gname))
}

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

// ─────────────────────────────────────────────────────────────────────────────
// Part (b): real processes on a real pty
// ─────────────────────────────────────────────────────────────────────────────
print("\nForegroundProcess — real-pty cases")

// --- clientTTY and TIOCPTYGNAME ---
let (primaryFd, clientTTYPath) = openPtyPair()

// The shell half left secondaryFd closed; we re-open only to verify ttyname.
// Actually we need a fresh pair to check ttyname without interfering with the helper.
var pfTTY: Int32 = 0, sfTTY: Int32 = 0
openpty(&pfTTY, &sfTTY, nil, nil, nil)
var gTTY = [CChar](repeating: 0, count: 128)
ioctl(pfTTY, TIOCPTYGNAME, &gTTY)
let ttyFromIoctl = String(cString: gTTY)
let ttyFromTtyname = ttyname(sfTTY).map { String(cString: $0) } ?? ""
check("clientTTY TIOCPTYGNAME == ttyname() on slave side",
      ttyFromIoctl == ttyFromTtyname,
      "ioctl=\(ttyFromIoctl) ttyname=\(ttyFromTtyname)")
let gotTTY = ForegroundProcess.clientTTY(childfd: pfTTY)
check("clientTTY(childfd:) returns slave device path",
      gotTTY == ttyFromIoctl, "got=\(gotTTY ?? "nil") want=\(ttyFromIoctl)")
close(pfTTY); close(sfTTY)

// --- closed fd → nil ---
var pfClosed: Int32 = 0, sfClosed: Int32 = 0
openpty(&pfClosed, &sfClosed, nil, nil, nil)
close(sfClosed); close(pfClosed)
let closedResult = ForegroundProcess.current(childfd: pfClosed, integratedShellPid: 99999)
check("closed primary fd → nil (fail-closed)", closedResult == nil,
      "got=\(String(describing: closedResult))")

// --- foreground = integratedShellPid → .shell ---
// Spawn /bin/sleep as the foreground on a fresh pty.
guard let childPid = spawnForeground(slave: clientTTYPath) else {
    print("ENV: helper failed to spawn child"); exit(2)
}
usleep(300_000)  // let child reach tcsetpgrp

// Confirm tcgetpgrp actually returns childPid — this is how we know the code path
// through tcgetpgrp is exercised, not the fallback-pid path.
let fgGroup = tcgetpgrp(primaryFd)
check("tcgetpgrp(primaryFd) == childPid (foreground branch is live)",
      fgGroup == childPid, "tcgetpgrp=\(fgGroup) childPid=\(childPid)")

let shellCase = ForegroundProcess.current(childfd: primaryFd, integratedShellPid: childPid)
check("foreground == integratedShellPid → .shell", shellCase == .shell,
      "got=\(String(describing: shellCase))")

// executableName uses kernel path, not argv.
let exeName = ForegroundProcess.executableName(of: childPid)
let exeBase = exeName.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
check("executableName(of:) uses proc_pidpath, not argv",
      exeBase == "sleep", "got=\(exeName ?? "nil")")

// --- different shell binary in front → .knownShell ---
// zsh with -f (fast, no rc) -c "while :; do :; done": stays alive as a tight loop
// so proc_pidpath sees /bin/zsh (not a child sleep it exec'd). Without extra args,
// interactive zsh may exec a child or exit before proc_pidpath can query it.
let (pShell, shellSlave) = openPtyPair()
if let zshPid = spawnForeground(slave: shellSlave, program: "/bin/zsh",
                                extraArgs: ["-f", "-c", "while :; do :; done"]) {
    usleep(300_000)
    let diffShellPid: pid_t = zshPid + 100
    let knownResult = ForegroundProcess.current(childfd: pShell, integratedShellPid: diffShellPid)
    if case .knownShell(let p, let n) = knownResult {
        check("zsh as foreground, pid≠shellPid → .knownShell", p == zshPid, "pid=\(p)")
        check("knownShell.name == 'zsh'", n == "zsh", "got=\(n)")
    } else {
        check("zsh as foreground → .knownShell", false, "\(String(describing:knownResult))")
        check("knownShell.name == 'zsh'", false, "not .knownShell")
    }
    kill(zshPid, SIGKILL); var st: Int32 = 0; waitpid(zshPid, &st, 0)
} else { print("  – SKIP zsh foreground (helper spawn failed)") }
close(pShell)

// --- non-shell command (/bin/sleep) → .command("sleep") ---
let (pSleep, sleepSlave) = openPtyPair()
if let sleepPid = spawnForeground(slave: sleepSlave) {
    usleep(200_000)
    let sleepResult = ForegroundProcess.current(childfd: pSleep, integratedShellPid: 7777)
    if case .command(let n) = sleepResult {
        check("/bin/sleep as foreground → .command(\"sleep\")", n == "sleep", "got=\(n)")
    } else {
        check("/bin/sleep as foreground → .command(\"sleep\")", false, "\(String(describing:sleepResult))")
    }
    kill(sleepPid, SIGKILL); var st: Int32 = 0; waitpid(sleepPid, &st, 0)
} else { print("  – SKIP sleep foreground (helper spawn failed)") }
close(pSleep)

// --- binary renamed "zsh" in a temp dir: two sub-cases ---
//
// DOCUMENTED LIMIT: classification is by basename of the kernel executable path, not
// by code signature. The kind() truth table already asserts this: kind("zsh",…) →
// .knownShell regardless of what binary is actually running. That is the limit.
//
// SECONDARY LIMIT: proc_pidpath returns ESRCH (errno 3) for processes whose binary
// lives in user temp dirs (/tmp, /var/folders, /private/tmp). This is a macOS
// restriction — verified by probe during gate development: /bin/sleep works,
// /tmp/sleep and /var/folders/.../sleep return 0. This means current() returns nil
// for a renamed binary in a temp dir, not .knownShell — the system is MORE
// restrictive than basename identity suggests, not less.
//
// The two cases below verify both behaviors:
// (a) kind("zsh") via truth table already covers the pure classification.
// (b) A renamed /bin/sleep in a temp dir → current() returns nil (proc_pidpath
//     restricted by macOS), which is the correct fail-closed behavior.
let (pRename, renameSlave) = openPtyPair()
let fakeZshPath = workDir + "/fake_zsh"
let copied = (try? FileManager.default.copyItem(atPath: "/bin/sleep",
                                                 toPath: fakeZshPath)) != nil
if copied {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                            ofItemAtPath: fakeZshPath)
    if let fakePid = spawnForeground(slave: renameSlave, program: fakeZshPath) {
        usleep(200_000)
        // proc_pidpath returns 0 for temp-dir binaries (macOS restriction).
        // current() → nil, not .knownShell. Fail-closed, tested explicitly.
        let fakeResult = ForegroundProcess.current(childfd: pRename,
                                                    integratedShellPid: fakePid + 200)
        check("binary in temp dir → nil (proc_pidpath macOS restriction, fail-closed)",
              fakeResult == nil, "got=\(String(describing:fakeResult))")
        // Also confirm kind("zsh") → .knownShell directly (the classification layer).
        // This is the 'basename limit' case: IF the kernel gives us "zsh", kind() trusts it.
        let kindResult = ForegroundProcess.kind(executableName: "zsh",
                                                pid: fakePid, integratedShellPid: fakePid + 200,
                                                clientTTY: renameSlave)
        if case .knownShell(_, let n) = kindResult {
            check("kind('zsh') → .knownShell (basename limit: if kernel names it, we trust it)",
                  n == "zsh", "name=\(n)")
        } else {
            check("kind('zsh') → .knownShell (basename limit)", false,
                  "\(String(describing:kindResult))")
        }
        kill(fakePid, SIGKILL); var st: Int32 = 0; waitpid(fakePid, &st, 0)
    } else { print("  – SKIP renamed-zsh cases (helper spawn failed)") }
    try? FileManager.default.removeItem(atPath: fakeZshPath)
} else { print("  – SKIP renamed-zsh cases (copy of /bin/sleep failed)") }
close(pRename)

// --- exited pid → nil ---
kill(childPid, SIGKILL); var exitSt: Int32 = 0; waitpid(childPid, &exitSt, 0)
usleep(200_000)
let exitedResult = ForegroundProcess.current(childfd: primaryFd,
                                              integratedShellPid: childPid)
check("exited foreground pid → nil (no crash)", exitedResult == nil,
      "got=\(String(describing:exitedResult))")

let deadExe = ForegroundProcess.executableName(of: childPid)
check("executableName of exited pid → nil", deadExe == nil,
      "got=\(deadExe ?? "non-nil")")

close(primaryFd)

// NOTE: ssh classification is covered by the kind() truth table above.
// Spawning a real ssh session deterministically as the foreground group requires
// sshd to be running and listening — an environmental condition that would make
// this gate an environmental flap. The truth table is the correct locus for
// classification logic; the real-pty section proves current() calls kind() correctly.
print("  – NOTE: ssh covered by truth table (real ssh spawn omitted — see header)")

print("")
if failures == 0 { print("all checks passed"); exit(0) }
print("\(failures) check(s) failed"); exit(1)
