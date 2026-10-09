#!/bin/sh
# Compile shipped close policy and kernel adapter, never a restated policy.
# 0 = pass; 1 = assertion failure; 2 = toolchain/fixture/compile environment.
# Python's forkpty gives the fixture a controlling tty (Swift's unavailable fork
# cannot; see check-cwd-follow.sh). Tests a real idle zsh and foreground sleep.
# Cannot reach AppKit close routing, alert buttons, modal races or physical focus:
# those remain daily-drive. The same-PID exec case is pinned in the pure policy.
set -u
cd "$(dirname "$0")/.." || exit 2
command -v swiftc >/dev/null 2>&1 || exit 2
command -v python3 >/dev/null 2>&1 || exit 2
TMP="$(mktemp -d)" || exit 2
# All scratch lives in our own mktemp dir outside the checkout; remove that dir whole.
trap 'rm -rf "$TMP"' EXIT  # whole mktemp dir: a per-file list leaked it each time a mutant was added
cp Sources/GoblinPortal/CloseConfirmPolicy.swift "$TMP/policy.swift" || exit 2
cp Sources/GoblinPortal/ShellDirectory.swift "$TMP/directory.swift" || exit 2
cat > "$TMP/main.swift" <<'SWIFT'
import Darwin
import Foundation
var failures = 0
@MainActor func expect(_ label: String, _ value: Bool) {
    if !value { print("FAIL \(label)"); failures += 1 }
}
@MainActor func busy(_ group: Int32?, _ name: String?, _ running: Bool = true) -> String? {
    CloseConfirmPolicy.busyName(shellPID: 10, foregroundGroup: group,
        processName: name, shellName: "zsh", running: running)
}
expect("idle", busy(10, "zsh") == nil)
expect("exited", busy(20, "vim", false) == nil)
expect("invalid group", busy(-1, "vim") == nil)
expect("missing group", busy(nil, "vim") == nil)
expect("vim", busy(20, "vim") == "vim")
expect("nested shell is a job", busy(20, "zsh") == "zsh")
expect("exec replaced shell", busy(10, "vim") == "vim")
expect("unknown leader", busy(20, nil) == "foreground process")
expect("unknown shell executable", busy(10, nil) == "foreground process")
expect("blank leader", busy(20, " ") == "foreground process")
expect("tmux", busy(20, "tmux") == "tmux")
expect("screen", busy(20, "screen") == "screen")
expect("one", CloseConfirmPolicy.message(names: ["afk"]) == "1 process is running: afk")
expect("count jobs not names", CloseConfirmPolicy.message(names: ["vim", "vim", "afk"])
    == "3 processes are running: vim, afk")
expect("closed fd", ShellDirectory.foregroundProcess(childfd: -1) == nil)
if CommandLine.arguments.count == 4,
   let fd = Int32(CommandLine.arguments[1]), let shell = Int32(CommandLine.arguments[2]) {
    let job = ShellDirectory.foregroundProcess(childfd: fd)
    expect("kernel foreground", job != nil)
    if let job {
        let name = CloseConfirmPolicy.busyName(shellPID: shell, foregroundGroup: job.group,
            processName: job.name, shellName: "zsh", running: true)
        if CommandLine.arguments[3] == "idle" {
            expect("real idle shell", name == nil && job.group == shell)
        } else {
            expect("real busy job", name == "sleep" && job.group != shell)
        }
    }
}
print("close-confirm failures: \(failures)")
exit(failures == 0 ? 0 : 1)
SWIFT
if ! swiftc -swift-version 6 "$TMP/policy.swift" "$TMP/directory.swift" "$TMP/main.swift" -o "$TMP/check"; then exit 2; fi
"$TMP/check" || exit $?
# Falsification 1: count UNIQUE names instead of jobs. Classification still works,
# but closing two vim panes would misleadingly report one process.
sed 's/names.count) processes/unique.count) processes/' "$TMP/policy.swift" > "$TMP/mutant.swift"
if ! swiftc -swift-version 6 "$TMP/mutant.swift" "$TMP/directory.swift" "$TMP/main.swift" -o "$TMP/mutant"; then exit 2; fi
"$TMP/mutant"; result=$?
rm -f "$TMP/mutant.swift"
[ "$result" -eq 1 ] || { echo 'FAIL falsification-1 did not fail with exit 1'; exit 1; }
# Falsification 2: break classification — drop the `name == shellName` exec-replacement
# check so that exec'd vim (same PID as shell) is never reported as a job.
# "exec replaced shell" case expects "vim" but the mutant returns nil → exit 1.
# This verifies the gate is not blind to a broken busyName implementation.
sed 's/name == shellName/name == "____NEVER____"/' "$TMP/policy.swift" > "$TMP/mutant2.swift"
if ! swiftc -swift-version 6 "$TMP/mutant2.swift" "$TMP/directory.swift" "$TMP/main.swift" -o "$TMP/mutant2"; then exit 2; fi
"$TMP/mutant2"; result2=$?
rm -f "$TMP/mutant2.swift"
[ "$result2" -eq 1 ] || { echo 'FAIL falsification-2 (exec comparison) did not fail with exit 1'; exit 1; }
cat > "$TMP/pty.py" <<'PYTHON'
import os, select, signal, subprocess, sys, time
pid, fd = os.forkpty()
if pid == 0:
    if sys.argv[2] == 'busy':
        # Establish a real separate foreground job without interactive zsh
        # inheriting the invoking runner's signal dispositions/job-control flags.
        child = subprocess.Popen(['/bin/sleep', '60'], preexec_fn=os.setpgrp)
        os.tcsetpgrp(0, child.pid)
        child.wait()
        os._exit(0)
    os.environ['PS1'] = 'CLOSE_READY> '
    os.execv('/bin/zsh', ['zsh', '-fi'])
try:
    def wait_for_group(busy):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            group = os.tcgetpgrp(fd)
            if group > 0 and ((group != pid) == busy):
                return
            time.sleep(0.02)
        detail = os.read(fd, 4096) if select.select([fd], [], [], 0)[0] else b''
        raise RuntimeError(f'foreground group fixture timeout: shell={pid}, group={os.tcgetpgrp(fd)}, output={detail!r}')
    mode = sys.argv[2]
    if mode == 'busy':
        wait_for_group(True)
        sys.exit(subprocess.run([sys.argv[1], str(fd), str(pid), mode], pass_fds=(fd,)).returncode)
    # pgrp can be the shell before zsh finishes tty startup. Do not feed
    # typeahead that its startup flush may discard: wait for the real prompt.
    deadline = time.monotonic() + 10
    output = b''
    while b'CLOSE_READY>' not in output:
        if time.monotonic() > deadline:
            raise RuntimeError('shell prompt fixture timeout')
        if select.select([fd], [], [], 0.1)[0]:
            output += os.read(fd, 4096)
    wait_for_group(False)
    sys.exit(subprocess.run([sys.argv[1], str(fd), str(pid), mode], pass_fds=(fd,)).returncode)
except Exception as e:
    print('environment:', e, file=sys.stderr)
    sys.exit(2)
finally:
    group = os.tcgetpgrp(fd)
    os.close(fd)
    if group > 0 and group != pid:
        try:
            os.killpg(group, signal.SIGHUP)
        except ProcessLookupError:
            pass
    try:
        os.kill(pid, signal.SIGHUP)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
PYTHON
python3 "$TMP/pty.py" "$TMP/check" idle || exit $?
python3 "$TMP/pty.py" "$TMP/check" busy
exit $?
