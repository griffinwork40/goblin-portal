// check-shell-context-table.swift
// Layer 1 of check-shell-context.sh: the pure truth table over the SHIPPED
// `ShellDirectoryPolicy.resolve` (ShellContext.swift), compiled beside the shipped
// ForegroundProcess.swift and Osc7Directory.swift. Copied to main.swift by the script;
// never run directly.
//
// WHY A FULL TABLE AND NOT A FEW EXAMPLES. The cwd rule is a precedence order across
// seven foreground kinds and three report states. The two bugs that motivated it were
// both precedence bugs (an OSC 7 value that outranked everything forever; a fallback that
// followed the foreground program), and precedence bugs hide in the cells nobody wrote an
// example for. So every ForegroundKind x {no report, local report, remote report} x
// {every directory present, every directory absent} cell is asserted, plus named rows
// for the two stale-report hazards the coordinator called out.
//
// The `spec` function below is the specification written as rows, one per foreground
// kind: it is what the plan's "Coordinator decisions" section says, not a copy of the
// shipped switch. If the two ever disagree, this table is the one to argue with.
//
import Foundation

var failures = 0
var cases = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    if !ok {
        failures += 1
        print("  ✗ \(name)   [\(detail())]")
    }
}

let shellDir = URL(fileURLWithPath: "/gate/shell")      // the pane's own shell
let knownDir = URL(fileURLWithPath: "/gate/known")      // a nested local shell
let tmuxDir = URL(fileURLWithPath: "/gate/tmux")        // tmux's active pane
let reportedPath = "/gate/reported"                     // a LOCAL OSC 7 report
let reportedDir = URL(fileURLWithPath: reportedPath)

let kinds: [ForegroundKind?] = [
    nil, .shell, .command(name: "sleep"), .knownShell(pid: 77, name: "bash"),
    .tmuxClient(pid: 88, tty: "/dev/ttys099"), .remote(name: "ssh"),
    .otherMultiplexer(name: "screen"),
]
let reports: [Osc7Directory?] = [nil, .local(path: reportedPath), .remote(host: "other-host")]

/// The rule, row by row (ShellContext.swift header; plan "Coordinator decisions" 1-2).
func spec(_ kind: ForegroundKind?, _ report: Osc7Directory?, _ present: Bool)
    -> (URL?, DirectoryFollowStatus) {
    switch kind {
    case nil:
        // Unreadable foreground: we know nothing, so we claim nothing.
        return (nil, .unavailable)
    case .shell?, .command?:
        // A LOCAL report from the pane wins; otherwise the SHELL's kernel cwd. A remote
        // report here is stale by construction (the remote session is no longer in front).
        if case .local? = report { return (reportedDir, .local) }
        return (present ? shellDir : nil, .local)
    case .knownShell?:
        // That shell's cwd only. A local report came from the OUTER shell: stale here.
        return (present ? knownDir : nil, .local)
    case .tmuxClient?:
        // tmux's cached answer only. Never the outer shell's last OSC 7.
        return (present ? tmuxDir : nil, .local)
    case .remote?:
        // Never a directory. The host is shown only when a remote report named one.
        if case .remote(let host)? = report { return (nil, .remote(host: host)) }
        return (nil, .remote(host: nil))
    case .otherMultiplexer(let name)?:
        return (nil, .paused(program: name))
    }
}

func label(_ k: ForegroundKind?) -> String { k.map { "\($0)" } ?? "nil" }
func label(_ r: Osc7Directory?) -> String { r.map { "\($0)" } ?? "nil" }

print("ShellDirectoryPolicy.resolve — full truth table")
for kind in kinds {
    for report in reports {
        for present in [true, false] {
            let got = ShellDirectoryPolicy.resolve(
                foreground: kind, reported: report,
                shellDirectory: present ? shellDir : nil,
                knownShellDirectory: present ? knownDir : nil,
                tmuxDirectory: present ? tmuxDir : nil)
            let (wantDir, wantStatus) = spec(kind, report, present)
            let name = "fg=\(label(kind)) report=\(label(report)) dirs=\(present ? "present" : "absent")"
            check(name + " directory", got.directory == wantDir,
                  "got=\(got.directory?.path ?? "nil") want=\(wantDir?.path ?? "nil")")
            check(name + " status", got.followStatus == wantStatus,
                  "got=\(got.followStatus) want=\(wantStatus)")
            check(name + " echoes foreground", got.foreground == kind,
                  "got=\(label(got.foreground))")
        }
    }
}

print("ShellDirectoryPolicy.resolve — named hazards")
// 1. User was in ssh (remote report arrived), exits back to a NON-integrated local shell.
//    The stale remote report must not blank the directory or leak a remote status.
let afterSsh = ShellDirectoryPolicy.resolve(
    foreground: .shell, reported: .remote(host: "old-host"),
    shellDirectory: shellDir, knownShellDirectory: nil, tmuxDirectory: nil)
check("stale remote report, back in local shell -> shell cwd, .local",
      afterSsh.directory == shellDir && afterSsh.followStatus == .local, "\(afterSsh)")
// 2. Integrated shell reported /gate/reported, then the user ran tmux; tmux has not
//    answered yet. The outer shell's report is NOT where the user is.
let tmuxCold = ShellDirectoryPolicy.resolve(
    foreground: .tmuxClient(pid: 9, tty: "/dev/ttys001"), reported: .local(path: reportedPath),
    shellDirectory: shellDir, knownShellDirectory: nil, tmuxDirectory: nil)
check("stale local report under tmux (cache cold) -> nil, never the outer report",
      tmuxCold.directory == nil, "\(tmuxCold)")
let tmuxWarm = ShellDirectoryPolicy.resolve(
    foreground: .tmuxClient(pid: 9, tty: "/dev/ttys001"), reported: .local(path: reportedPath),
    shellDirectory: shellDir, knownShellDirectory: nil, tmuxDirectory: tmuxDir)
check("stale local report under tmux (cache warm) -> tmux's answer",
      tmuxWarm.directory == tmuxDir, "\(tmuxWarm)")
// 3. Same staleness for a nested shell and for ssh.
let nested = ShellDirectoryPolicy.resolve(
    foreground: .knownShell(pid: 5, name: "bash"), reported: .local(path: reportedPath),
    shellDirectory: shellDir, knownShellDirectory: knownDir, tmuxDirectory: tmuxDir)
check("local report under a nested shell -> the nested shell's cwd",
      nested.directory == knownDir, "\(nested)")
let sshLocal = ShellDirectoryPolicy.resolve(
    foreground: .remote(name: "ssh"), reported: .local(path: "/tmp"),
    shellDirectory: shellDir, knownShellDirectory: knownDir, tmuxDirectory: tmuxDir)
check("ssh in front with a local report -> nil and host nil, never /tmp",
      sshLocal.directory == nil && sshLocal.followStatus == .remote(host: nil), "\(sshLocal)")
// 4. A command in front: the shell's cwd, never anything else even if every input exists.
let command = ShellDirectoryPolicy.resolve(
    foreground: .command(name: "agent-afk"), reported: nil,
    shellDirectory: shellDir, knownShellDirectory: knownDir, tmuxDirectory: tmuxDir)
check("command in front, no report -> the shell's cwd",
      command.directory == shellDir && command.followStatus == .local, "\(command)")

print("")
if failures == 0 {
    print("all \(cases) truth-table checks passed")
    exit(0)
}
print("\(failures) of \(cases) truth-table check(s) failed")
exit(1)
