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

// HONEST SCOPE NOTE, and it was found by asserting it rather than assuming it. The
// child above is a session leader (POSIX_SPAWN_SETSID) that opens the pty itself, which
// on Linux would make it acquire the terminal and become its foreground process group.
// On Darwin it does not: BSD requires an explicit ioctl(TIOCSCTTY), which a spawned
// process cannot be made to issue, and the fork()-then-ioctl route is closed because
// Swift marks fork() unavailable ("Please use threads or posix_spawn*()"). So
// tcgetpgrp(primary) fails here and these cases exercise the FALLBACK pid path. They are
// named for what they actually test. The tcgetpgrp branch is covered separately below,
// against this process's own controlling terminal, and in production by the app itself —
// SwiftTerm reaches the pty through forkpty (LocalProcess.swift:513), which does the
// TIOCSCTTY this script cannot.
let foregroundWorks = tcgetpgrp(primary) > 0

print("ShellDirectory — reading a live shell's directory")
let expected = URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath()
let got = ShellDirectory.current(foregroundOf: primary, fallbackPid: pid)
check("reads a spawned child's cwd (fallback pid path)", got == expected,
      "got=\(got?.path ?? "nil") want=\(expected.path)")
check("foreground-group probe behaved as documented on this OS", !foregroundWorks,
      "tcgetpgrp(primary)=\(tcgetpgrp(primary)) — if this ever succeeds, retitle the cases above")
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
check("idempotent across two reads",
      ShellDirectory.current(foregroundOf: primary, fallbackPid: pid) == got)
check("falls back to shellPid when childfd is unusable",
      ShellDirectory.current(foregroundOf: -1, fallbackPid: pid) == expected)

print("ShellDirectory — inputs that must not trap")
check("childfd -1 and pid 0 -> nil", ShellDirectory.current(foregroundOf: -1, fallbackPid: 0) == nil)
check("negative pid -> nil", ShellDirectory.current(foregroundOf: -1, fallbackPid: -42) == nil)
check("pid 1 (launchd, not ours) -> nil or a path, never a trap",
      ShellDirectory.current(foregroundOf: -1, fallbackPid: 1) != nil
          || ShellDirectory.current(foregroundOf: -1, fallbackPid: 1) == nil)

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

print("ShellDirectory — the tcgetpgrp branch, against our own terminal")
// The one place this script can reach a real controlling terminal is its own, when run
// from a terminal. That exercises the tcgetpgrp branch for real: fd 0 is a tty, its
// foreground process group exists, and the answer must be an absolute existing path.
// SKIPped rather than failed when stdin is not a tty, because a redirected run is an
// environment fact, not a defect.
if isatty(0) == 1 {
    let mine = ShellDirectory.current(foregroundOf: 0, fallbackPid: 0)
    check("tcgetpgrp path returns an absolute existing directory", mine.map {
        $0.path.hasPrefix("/") && FileManager.default.fileExists(atPath: $0.path)
    } ?? false, "got=\(mine?.path ?? "nil")")
    check("tcgetpgrp path needs no fallback pid", mine != nil)
} else {
    print("  – SKIP tcgetpgrp branch (stdin is not a tty)")
}

print("ShellDirectory — a shell that has gone away")
kill(pid, SIGKILL)
var status: Int32 = 0
waitpid(pid, &status, 0)
usleep(400_000)
check("exited child -> nil, no crash",
      ShellDirectory.current(foregroundOf: primary, fallbackPid: pid) == nil)

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
