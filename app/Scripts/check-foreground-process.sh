#!/usr/bin/env bash
#
# check-foreground-process.sh — headless truth table + real-pty tests for
# ForegroundProcess.swift.
#
# THIS SCRIPT IS THREE FILES. Assertions live in
# `Scripts/check-foreground-process-table.swift` (part a) and
# `Scripts/check-foreground-process-harness.swift` (part b), compiled here, never run
# alone. That split is forced by the 350-line ceiling check-file-size.sh enforces
# (AFK.md, "Conventions"). Same pattern as check-git-status.sh.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/ForegroundProcess.swift`. Like
# ShellDirectory.swift it imports only Foundation/Darwin, so this script can compile
# it standalone with swiftc — no AppKit, no SwiftTerm, no app binary required.
#
# TWO TEST PARTS:
# (a) Truth table over kind(executableName:pid:integratedShellPid:clientTTY:):
#     every shell name, every special category, empty name, path-like name, the
#     pid-equality case, tmux with and without a tty, and EXEC rows: tmux/ssh/screen/
#     vim at the shell's own pid are classified by name, a shell there is `.shell`.
# (b) Real processes on a real pty. A C helper forks+setsid+TIOCSCTTY to become the
#     foreground process group — the path posix_spawn cannot reach on Darwin (BSD
#     requires explicit TIOCSCTTY; Swift marks fork() unavailable; check-cwd-follow.sh
#     documents this at lines 97-107). Cases: a non-shell at the shell's pid → .command;
#     a real zsh at the shell's pid → .shell, then EXECs a compiled ssh/tmux/vim stand-in
#     and is classified by the new name; a different shell in front → .knownShell;
#     /bin/sleep → .command("sleep"); a symlink named zsh → its resolved name;
#     exited pid → nil; closed fd → nil; clientTTY matching ttyname() on the slave side.
#     A real ssh session is not spawned (needs sshd); the stand-in proves the exec path.
#
# EXIT CODES (three-valued, matching check-cwd-follow.sh):
#   0 = every case passed
#   1 = a real assertion failed (the implementation is wrong)
#   2 = environmental failure (no swiftc, no C compiler, harness compile error,
#       openpty unavailable). A broken environment must never read as a green gate.
#
# FALSIFICATION (--falsify flag):
#   Applies four mutants to temp copies and asserts each one makes the gate exit 1.
#   Mutant 1: executableName always returns "zsh" (argv-based, not kernel path).
#   Mutant 2: the pid-equality guard removed (.shell becomes .knownShell always).
#   Mutant 3: clientTTY returns ttyname(primaryFd) (primary, not slave).
#   Mutant 4: the pid check moved ahead of the name switch (exec'd tmux/ssh → .shell).
#   Exits 0 only if every mutant is caught.
#
# ISOLATION. All work under mktemp -d removed by trap. No UserDefaults domain,
# no user tmux socket, no ~/.config/goblin-portal touched.
#
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/ForegroundProcess.swift"
HARNESS="Scripts/check-foreground-process-harness.swift"
TABLE="Scripts/check-foreground-process-table.swift"

FALSIFY=0
[[ "${1:-}" == "--falsify" ]] && FALSIFY=1

[ -f "$SRC" ]     || { echo "ENV: $SRC not found";     exit 2; }
[ -f "$HARNESS" ] || { echo "ENV: $HARNESS not found"; exit 2; }
[ -f "$TABLE" ]   || { echo "ENV: $TABLE not found";   exit 2; }
command -v swiftc >/dev/null 2>&1 || { echo "ENV: no swiftc on PATH"; exit 2; }
command -v cc     >/dev/null 2>&1 || { echo "ENV: no C compiler on PATH"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ───────────────────────────────────────────────────────────────────────────
# C HELPER: fork+setsid+TIOCSCTTY → foreground process group on a pty slave.
# WHY: POSIX_SPAWN_SETSID sets the session but cannot issue ioctl(TIOCSCTTY);
# Swift marks fork() unavailable. This helper bridges that gap for part (b).
# Usage: helper <slave-device-path> <program-to-exec>
# Prints child pid to stdout; child execs the named program.
# ───────────────────────────────────────────────────────────────────────────
cat > "$WORK/helper.c" << 'CHELPER'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: helper <slave> <prog>\n"); return 1; }
    const char *slave = argv[1];
    const char *prog  = argv[2];
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }
    if (pid == 0) {
        if (setsid() < 0)                    { perror("setsid");    _exit(1); }
        int fd = open(slave, O_RDWR|O_NOCTTY, 0);
        if (fd < 0)                          { perror("open slave"); _exit(1); }
        if (ioctl(fd, TIOCSCTTY, 0) < 0)    { perror("TIOCSCTTY"); _exit(1); }
        if (tcsetpgrp(fd, getpid()) < 0)    { perror("tcsetpgrp"); _exit(1); }
        dup2(fd,0); dup2(fd,1);
        int dn = open("/dev/null", O_WRONLY, 0);
        if (dn >= 0) { dup2(dn,2); close(dn); }
        if (fd > 2) close(fd);
        /* argv[2] is the program path; argv[3..argc-1] are optional extra args.
         * If the program is /bin/sleep and no extra args given, append "10".
         * Otherwise pass all extra args verbatim so callers can pass "-f -c '...'"
         * to zsh without modifying this binary. */
        if (strcmp(prog, "/bin/sleep") == 0 && argc < 4) {
            char *a[] = {"/bin/sleep","10",NULL};
            execv(prog, a);
        } else {
            /* Build argv from argv[2..argc-1] */
            char **a = (char **)malloc((argc - 1) * sizeof(char *));
            if (!a) _exit(1);
            for (int i = 0; i < argc - 2; i++) a[i] = argv[i + 2];
            a[argc - 2] = NULL;
            execv(prog, a);
        }
        perror("exec"); _exit(1);
    }
    printf("%d\n", (int)pid);
    return 0;
}
CHELPER

if ! cc -o "$WORK/helper" "$WORK/helper.c" 2>"$WORK/cbuild.log"; then
    echo "ENV: C helper would not compile"
    cat "$WORK/cbuild.log" || true
    exit 2
fi

# Stand-ins for programs a shell may `exec` (ssh, tmux, vim): one COMPILED binary under
# three names. Compiled, not copied, because a copied /bin binary run from a temp dir is
# SIGKILLed by code signing before it can be inspected (the harness's symlink case
# records how that misled an earlier version of this gate). Each just sleeps.
mkdir -p "$WORK/bin"
printf '#include <unistd.h>\nint main(void){sleep(10);return 0;}\n' > "$WORK/bin/standin.c"
for name in ssh tmux vim; do
    cc -o "$WORK/bin/$name" "$WORK/bin/standin.c" 2>>"$WORK/cbuild.log" || {
        echo "ENV: could not compile the $name stand-in"; exit 2; }
done

# ───────────────────────────────────────────────────────────────────────────
# Compile the harness against the shipped source and run it.
# harness.swift is copied to main.swift: Swift only allows top-level statements
# in a file with that name (same convention as check-cwd-follow.sh and
# check-git-status-harness.swift).
# ───────────────────────────────────────────────────────────────────────────
cp "$HARNESS" "$WORK/main.swift"
cp "$TABLE" "$WORK/table.swift"

if ! swiftc -O "$SRC" "$WORK/main.swift" "$WORK/table.swift" -o "$WORK/run" 2>"$WORK/build.log"; then
    echo "ENV: the harness would not compile against $SRC"
    grep -E "error:" "$WORK/build.log" | head -20 || true
    exit 2
fi

# set +e: under `set -e` a red run (exit 1) would end the script here, so --falsify
# could never be reached from a red baseline and the verdict would skip this line.
set +e
FP_WORK="$WORK" "$WORK/run"
RESULT=$?
set -e

[[ $FALSIFY -eq 0 ]] && exit $RESULT

# ───────────────────────────────────────────────────────────────────────────
# FALSIFICATION: each mutant must produce exit 1 from a real assertion.
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "ForegroundProcess — falsification"

FAL_FAILURES=0

run_mutant() {
    local label="$1" mutant_src="$2"
    local mwork; mwork="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$mwork'" RETURN
    cp "$WORK/main.swift" "$mwork/main.swift"
    if ! swiftc -O "$mutant_src" "$mwork/main.swift" "$WORK/table.swift" \
            -o "$mwork/run" 2>/dev/null; then
        echo "  ✗ $label — mutant did not compile"; return 1
    fi
    FP_WORK="$WORK" "$mwork/run" >/dev/null 2>&1; local code=$?
    if [[ $code -eq 1 ]]; then
        echo "  ✓ $label → exit 1 (mutant caught)"
    else
        echo "  ✗ $label → exit $code (expected 1; mutant NOT caught)"; return 1
    fi
}

# Mutant 1: executableName always returns "zsh" — simulates argv-based
# classification. The /bin/sleep as foreground → .command("sleep") case must
# catch this: with the mutant, sleep's name becomes "zsh" → .knownShell, not .command.
M1="$WORK/mutant1.swift"
python3 - "$SRC" "$M1" << 'PYEOF'
import sys
text = open(sys.argv[1]).read()
# Insert an early return "zsh" at the top of executableName, before any syscall.
# Uses a literal string replace on the unique function signature + first guard line.
old = ('    static func executableName(of pid: pid_t) -> String? {\n'
       '        guard pid > 0 else { return nil }')
new = ('    static func executableName(of pid: pid_t) -> String? {\n'
       '        return "zsh" // MUTANT 1: always zsh, not kernel path\n'
       '        guard pid > 0 else { return nil }')
text2 = text.replace(old, new, 1)
assert text2 != text, "mutant 1 pattern not found"
open(sys.argv[2], 'w').write(text2)
PYEOF
run_mutant "mutant 1: executableName always 'zsh' (argv-based, not kernel)" "$M1" \
    || FAL_FAILURES=$((FAL_FAILURES+1))

# Mutant 2: pid-equality guard removed so .shell is never returned.
# The "foreground == integratedShellPid → .shell" assertion must catch this.
M2="$WORK/mutant2.swift"
python3 - "$SRC" "$M2" << 'PYEOF'
import sys, re
text = open(sys.argv[1]).read()
# Remove the line that returns .shell when pid matches
text2 = re.sub(
    r'\bif\s+pid\s*==\s*integratedShellPid\s*\{[^}]+\.shell[^}]+\}',
    '/* MUTANT 2: pid-equality removed */',
    text, count=1, flags=re.DOTALL
)
open(sys.argv[2], 'w').write(text2)
PYEOF
run_mutant "mutant 2: pid-equality guard removed (.shell → .knownShell)" "$M2" \
    || FAL_FAILURES=$((FAL_FAILURES+1))

# Mutant 3: clientTTY returns ttyname(primaryFd) — the primary/master side —
# instead of the slave. On macOS ttyname() on the primary fd returns nil (the
# primary is not a named device); the assertion for clientTTY matching the slave
# path must catch this.
M3="$WORK/mutant3.swift"
python3 - "$SRC" "$M3" << 'PYEOF'
import sys, re
text = open(sys.argv[1]).read()
body_re = re.compile(
    r'(static func clientTTY\(childfd: Int32\) -> String\? \{)(.*?)(^\s+\})',
    re.DOTALL|re.MULTILINE
)
def replace_body(m):
    return (m.group(1) +
        '\n        // MUTANT 3: return primary tty name (wrong — should be slave)\n'
        '        guard let n = ttyname(childfd) else { return nil }\n'
        '        return String(cString: n)\n    ' +
        m.group(3))
text2 = body_re.sub(replace_body, text, count=1)
open(sys.argv[2], 'w').write(text2)
PYEOF
run_mutant "mutant 3: clientTTY returns primary (master) tty name" "$M3" \
    || FAL_FAILURES=$((FAL_FAILURES+1))

# Mutant 4: the pid check moved back IN FRONT of the name switch (review finding B1):
# an exec'd tmux/ssh/vim at the shell's pid reads `.shell` again. The truth-table exec
# rows and the real-pty "exec <stand-in>" cases must catch this.
M4="$WORK/mutant4.swift"
python3 - "$SRC" "$M4" << 'PYEOF'
import sys
text = open(sys.argv[1]).read()
old = '        switch executableName {\n'
new = '        if pid == integratedShellPid { return .shell } // MUTANT 4: pid first\n' + old
assert text.count(old) == 1, "mutant 4 pattern not found"
open(sys.argv[2], 'w').write(text.replace(old, new, 1))
PYEOF
run_mutant "mutant 4: pid checked before the name (exec'd tmux/ssh read as .shell)" "$M4" \
    || FAL_FAILURES=$((FAL_FAILURES+1))

echo ""
if [[ $FAL_FAILURES -eq 0 ]]; then
    echo "all falsification mutants caught (exit 0)"; exit 0
fi
echo "$FAL_FAILURES falsification mutant(s) NOT caught — gate is blind"; exit 1
