#!/usr/bin/env bash
#
# check-cwd-follow.sh — headless truth table for ShellDirectory, the unit both halves
# of cwd-follow run through.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/ShellDirectory.swift` only. It is pure and
# imports nothing but Foundation/Darwin precisely so this script can compile it
# directly with swiftc and never link AppKit, SwiftTerm, or the app — the same trick
# check-keybindings.sh plays on KeyBindings.swift. Nothing here launches Goblin Portal, steals
# focus, or needs a window server.
#
# SCOPE CHANGE (lane C, 2026-10-09). ShellDirectory no longer chooses WHICH process to ask:
# `current(foregroundOf:fallbackPid:)` followed the pty's foreground program and was
# deleted with that rationale (ShellDirectory.swift header). This gate now covers the
# per-pid read `workingDirectory(of:)` and the cd command; the choice of pid (shell vs.
# command vs. tmux vs. ssh) is gated by check-shell-context.sh against a real pane.
#
# WHY THIS EXISTS. The repo has no test target and no CI (AFK.md, "Checks"), so a
# feature's gate script IS its evidence. cwd-follow reads another process's working
# directory through two syscalls and writes a shell command built by string quoting —
# both are the kind of code that looks right and is wrong, and neither is visible in a
# diff review.
#
# EXIT CODES, deliberately three-valued, copying check-reflow.sh: 0 = every case
# passed; 1 = a real assertion failed (the implementation is wrong); 2 = anything
# environmental — no swiftc, missing source, a harness that would not compile, openpty
# or posix_spawn unavailable. A broken environment must never read as a green gate.
#
# ISOLATION. Everything happens under a mktemp -d removed by a trap, including the
# directories the child shell is pointed at. Nothing outside that directory is written,
# and no UserDefaults domain is touched at all (unlike check-space-restore.sh, this unit
# has no persisted state).
#
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/ShellDirectory.swift"

[ -f "$SRC" ] || { echo "ENV: $SRC not found (run from app/ or app/Scripts/)"; exit 2; }
command -v swiftc >/dev/null 2>&1 || { echo "ENV: no swiftc on PATH"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The harness must be main.swift: Swift only allows top-level statements in a file with
# that name, and this needs top-level code to drive a spawned child.
cat > "$WORK/main.swift" <<'SWIFT'
import Darwin
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ✓ " : "  ✗ ") + name + (detail.isEmpty ? "" : "   [\(detail)]"))
    if !ok { failures += 1 }
}

// A directory name carrying every character that breaks naive quoting: a space, a
// single quote, a dollar sign and a backtick. If cdCommand(to:) is ever rewritten with
// double quotes or no quotes, `$weird` expands to nothing and the backtick opens a
// command substitution — the cd lands somewhere else or fails outright.
let base = ProcessInfo.processInfo.environment["CWD_FOLLOW_WORK"] ?? "/tmp"
let target = base + "/deep dir's $weird`one"
guard (try? FileManager.default.createDirectory(
        atPath: target, withIntermediateDirectories: true)) != nil else {
    print("ENV: could not create the test directory"); exit(2)
}

// A real pty, so tcgetpgrp() is genuinely exercised rather than skipped. The child is
// spawned with POSIX_SPAWN_SETSID and OPENS the pty itself — that is what makes it
// acquire a controlling terminal and become the foreground process group. Inheriting a
// dup'd fd would not, and tcgetpgrp would then have nothing to report, which would
// silently reduce this file to a test of the fallback path only.
var primary: Int32 = 0
var secondary: Int32 = 0
guard openpty(&primary, &secondary, nil, nil, nil) == 0 else {
    print("ENV: openpty failed"); exit(2)
}
guard let ttyPath = ttyname(secondary).map({ String(cString: $0) }) else {
    print("ENV: ttyname failed"); exit(2)
}

var attr: posix_spawnattr_t?
posix_spawnattr_init(&attr)
posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
var acts: posix_spawn_file_actions_t?
posix_spawn_file_actions_init(&acts)
posix_spawn_file_actions_addopen(&acts, 0, ttyPath, O_RDWR, 0)
posix_spawn_file_actions_adddup2(&acts, 0, 1)
posix_spawn_file_actions_adddup2(&acts, 0, 2)
posix_spawn_file_actions_addchdir_np(&acts, target)

var pid: pid_t = 0
// Two statements, not one: inlining the literal makes Swift try to unify String with
// UnsafePointer<CChar>? and the map fails to type-check.
let words = ["/bin/zsh", "-c", "sleep 12"]
var argv = words.map { strdup($0) } + [nil]
guard posix_spawn(&pid, "/bin/zsh", &acts, &attr, &argv, environ) == 0 else {
    print("ENV: posix_spawn failed"); exit(2)
}
close(secondary)
usleep(800_000)  // let zsh reach its sleep and settle as the foreground group

// The pty is kept because a real shell-in-a-pty is what production reads; which pid is
// in FRONT of it no longer matters to this unit (ShellDirectory.swift header). Real
// foreground selection is exercised by check-shell-context.sh through forkpty
// (LocalProcess.swift:513), which does the TIOCSCTTY a spawned child here cannot.

print("ShellDirectory — reading a live shell's directory")
let expected = URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath()
let got = ShellDirectory.workingDirectory(of: pid)
check("reads a spawned shell's cwd by pid", got == expected,
      "got=\(got?.path ?? "nil") want=\(expected.path)")
check("answer carries no /private prefix", got?.path.hasPrefix("/private/") == false,
      "got=\(got?.path ?? "nil")")
// The normalisation rule, measured rather than assumed, because two earlier guesses at
// it were both wrong. Foundation strips a leading /private ONLY when the result still
// names an existing file (the documented NSString.standardizingPath rule). So:
//   existing    -> both spellings converge on the short form  (/private/tmp -> /tmp)
//   nonexistent -> neither is rewritten, and they do NOT converge
// cwd-follow is safe under that rule because both sides always exist in practice: the
// kernel is reporting a LIVE process's cwd, and a FileNode is built from a real directory
// entry. The residual edge is benign and self-correcting — if a directory is deleted
// between two polls, the spelling can flip and cost exactly one spurious re-root.
check("existing dir: both spellings converge on the short form (by path)",
      URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path
          == URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path,
      URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path)
// The trap this gate caught in review, kept as a permanent case. URL equality includes the
// directory marker, and resolvingSymlinksInPath() drops it when the last component is a
// symlink, so these two are `.path`-equal and `==`-UNEQUAL. FileTreeViewController.setRoot
// therefore compares paths; if anyone "tidies" that back to URL comparison, a 750ms poller
// will rebuild the tree twice a second and this case is what says so.
check("URL == is NOT safe for this comparison (why setRoot compares .path)",
      URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
          != URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath())
check("nonexistent dir: convergence does NOT hold (why the guard needs live paths)",
      URL(fileURLWithPath: "/private/tmp/doesnotexist").resolvingSymlinksInPath()
          != URL(fileURLWithPath: "/tmp/doesnotexist").resolvingSymlinksInPath())
check("idempotent across two reads", ShellDirectory.workingDirectory(of: pid) == got)
// The pid asked is the pid answered: our own process sits in a different directory from
// the child, so a reader that ignored its argument (e.g. read the caller) would fail.
let mine = ShellDirectory.workingDirectory(of: getpid())
let ourCwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .standardizedFileURL.resolvingSymlinksInPath()
check("reads THE pid given: our own cwd for getpid()", mine == ourCwd && mine != got,
      "got=\(mine?.path ?? "nil") want=\(ourCwd.path)")

print("ShellDirectory — inputs that must not trap")
check("pid 0 -> nil (it would mean our own group)", ShellDirectory.workingDirectory(of: 0) == nil)
check("negative pid -> nil", ShellDirectory.workingDirectory(of: -42) == nil)
check("pid 1 (launchd, not ours) -> nil or a path, never a trap",
      ShellDirectory.workingDirectory(of: 1) != nil || ShellDirectory.workingDirectory(of: 1) == nil)

print("ShellDirectory — the cd command")
// Executed, not string-matched: the only question that matters is whether a real zsh
// lands in the intended directory, and asserting on the quoting's shape would pass for
// any self-consistent wrong answer.
let cmd = ShellDirectory.cdCommand(to: URL(fileURLWithPath: target)) + "pwd\n"
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
proc.arguments = ["-c", cmd]
let out = Pipe()
proc.standardOutput = out
proc.standardError = Pipe()
try? proc.run()
proc.waitUntilExit()
let landed = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
check("cd survives space + ' + $ + backtick (executed, pwd compared)", landed == target,
      "pwd=\(landed)")
check("cd is submitted (trailing newline)",
      ShellDirectory.cdCommand(to: URL(fileURLWithPath: "/x")).hasSuffix("\n"))
check("embedded quote is closed-escaped-reopened",
      ShellDirectory.singleQuoted("a'b") == "'a'\\''b'",
      ShellDirectory.singleQuoted("a'b"))

print("ShellDirectory — a shell that has gone away")
kill(pid, SIGKILL)
var status: Int32 = 0
waitpid(pid, &status, 0)
usleep(400_000)
check("exited child -> nil, no crash", ShellDirectory.workingDirectory(of: pid) == nil)

print("")
if failures == 0 {
    print("all checks passed")
    exit(0)
}
print("\(failures) check(s) failed")
exit(1)
SWIFT

if ! swiftc -O "$SRC" "$WORK/main.swift" -o "$WORK/run" 2>"$WORK/build.log"; then
    echo "ENV: the harness would not compile against $SRC"
    grep -E "error:" "$WORK/build.log" | head -10 || true
    exit 2
fi

# The child shell is pointed inside the temp dir, so the isolation claim in this file's
# header is enforced rather than asserted.
CWD_FOLLOW_WORK="$WORK" "$WORK/run"
