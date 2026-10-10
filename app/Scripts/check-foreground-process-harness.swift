//
// check-foreground-process-harness.swift
// Swift assertions for check-foreground-process.sh — compiled by that script,
// never run independently.
//
// WHY THIS IS A SEPARATE FILE. Inline, the shell and Swift halves together
// were over the 350-LOC ceiling that check-file-size.sh enforces (AFK.md,
// "Conventions"). The shell half owns: C helper compile, pty pair setup,
// temp dir lifecycle, falsification mutants. This file owns the real-pty assertions
// (part b); the pure truth table (part a) is check-foreground-process-table.swift.
//
// ENVIRONMENT (set by the shell half):
//   FP_WORK      — temp dir containing the compiled C helper binary ("helper") and
//                  compiled exec stand-ins at bin/ssh, bin/tmux, bin/vim.
//

import Darwin
import Foundation

// `check` and `failures` live in check-foreground-process-table.swift (part a).

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

runKindTruthTable()

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

// The pid alone no longer makes `.shell` (B1, 2026-10-09): a NON-shell binary at the
// shell's pid is what `exec sleep` leaves behind, and is classified by its name. The real
// `.shell` path is asserted by the exec cases below, with a real zsh at that pid.
let shellCase = ForegroundProcess.current(childfd: primaryFd, integratedShellPid: childPid)
check("non-shell binary at integratedShellPid → .command(sleep), not .shell",
      shellCase == .command(name: "sleep"), "got=\(String(describing: shellCase))")

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

// --- a "zsh" that is really /bin/sleep: the name a process ARRIVES under is not trusted ---
//
// CORRECTED 2026-10-09 (coordinator). This case originally copied /bin/sleep to a temp
// dir and asserted current() == nil, attributing the nil to a "macOS restriction on
// proc_pidpath for temp-dir binaries". That was wrong: proc_pidpath works for any
// same-uid process (measured: Homebrew tmux resolves to
// /opt/homebrew/Cellar/tmux/3.6a/bin/tmux). The nil came from the copied platform
// binary being KILLED by code signing (SIGKILL, "Killed: 9") before it was ever
// inspected, so the case passed for a reason unrelated to the code under test.
//
// What it now proves: a symlink named `zsh` pointing at /bin/sleep is classified by
// the kernel's RESOLVED executable (`sleep`), not by the name it was launched under.
// That is the property the typing guard relies on: neither argv0 nor a symlink name
// can make an arbitrary program pass as a shell. The remaining, documented limit is a
// real binary FILE named `zsh`: kind() trusts the basename, not a code signature
// (asserted directly below via the truth table).
let (pRename, renameSlave) = openPtyPair()
let fakeZshPath = workDir + "/zsh"
if (try? FileManager.default.createSymbolicLink(
        atPath: fakeZshPath, withDestinationPath: "/bin/sleep")) != nil {
    // "10" explicitly: the helper only defaults sleep's argument for the literal path
    // /bin/sleep, and an argument-less sleep exits at once, which would read as nil.
    if let fakePid = spawnForeground(slave: renameSlave, program: fakeZshPath, extraArgs: ["10"]) {
        usleep(200_000)
        let fakeResult = ForegroundProcess.current(childfd: pRename,
                                                    integratedShellPid: fakePid + 200)
        if case .command(let n)? = fakeResult {
            check("symlink named zsh -> /bin/sleep classifies by resolved path (.command(sleep))",
                  n == "sleep", "got=\(n)")
        } else {
            check("symlink named zsh -> /bin/sleep classifies by resolved path (.command(sleep))",
                  false, "got=\(String(describing: fakeResult))")
        }
        let kindResult = ForegroundProcess.kind(executableName: "zsh",
                                                pid: fakePid, integratedShellPid: fakePid + 200,
                                                clientTTY: renameSlave)
        if case .knownShell(_, let n) = kindResult {
            check("kind('zsh') → .knownShell (basename limit: a real FILE named zsh is trusted)",
                  n == "zsh", "name=\(n)")
        } else {
            check("kind('zsh') → .knownShell (basename limit)", false,
                  "\(String(describing:kindResult))")
        }
        kill(fakePid, SIGKILL); var st: Int32 = 0; waitpid(fakePid, &st, 0)
    } else { print("  – SKIP symlinked-zsh cases (helper spawn failed)") }
    try? FileManager.default.removeItem(atPath: fakeZshPath)
} else { print("  – SKIP symlinked-zsh cases (symlink creation failed)") }
close(pRename)

// --- the shell EXECs another program: same pid, classified by its NEW name ---
// Review finding B1 (2026-10-09): `exec tmux new -A` / `exec ssh host` keep the shell's
// pid, so a pid-first `kind()` called them `.shell`. Here a real zsh is the "integrated
// shell" (its pid IS integratedShellPid), spins until a flag file appears, then execs a
// compiled stand-in. Before the exec it must read `.shell`; after it, the stand-in's
// name decides. The stand-ins are compiled by the shell half (a copied /bin binary is
// SIGKILLed by code signing from a temp dir — see the symlink case's history below).
for (stand, want) in [("ssh", ForegroundKind.remote(name: "ssh")),
                      ("tmux", nil), ("vim", ForegroundKind.command(name: "vim"))] {
    let (pExec, execSlave) = openPtyPair()
    let flag = workDir + "/exec-go-\(stand)"
    let target = workDir + "/bin/\(stand)"
    let script = "while [ ! -e '\(flag)' ]; do :; done; exec '\(target)'"
    guard let execPid = spawnForeground(slave: execSlave, program: "/bin/zsh",
                                        extraArgs: ["-f", "-c", script]) else {
        print("  – SKIP exec \(stand) (helper spawn failed)"); close(pExec); continue
    }
    usleep(300_000)
    let before = ForegroundProcess.current(childfd: pExec, integratedShellPid: execPid)
    check("exec \(stand): before the exec, the shell itself → .shell", before == .shell,
          "got=\(String(describing: before))")
    FileManager.default.createFile(atPath: flag, contents: nil)
    var after: ForegroundKind?
    for _ in 0..<40 {   // up to 2 s for the exec to land
        usleep(50_000)
        after = ForegroundProcess.current(childfd: pExec, integratedShellPid: execPid)
        if after != .shell { break }
    }
    let expected = want ?? .tmuxClient(pid: execPid, tty: execSlave)
    check("exec \(stand): same pid, classified by the new name → \(expected)", after == expected,
          "got=\(String(describing: after))")
    kill(execPid, SIGKILL); var st: Int32 = 0; waitpid(execPid, &st, 0)
    close(pExec)
}

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
