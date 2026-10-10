#!/usr/bin/env bash
#
# check-foreground-process.sh — headless truth table + real-pty tests for
# ForegroundProcess.swift.
#
# THIS SCRIPT IS FOUR FILES. Assertions live in
# `Scripts/check-foreground-process-table.swift` (part a),
# `Scripts/check-foreground-process-harness.swift` (part b) and
# `Scripts/check-foreground-process-group.swift` (part c), compiled here, never run
# alone. That split is forced by the 350-line ceiling check-file-size.sh enforces
# (AFK.md, "Conventions"). Same pattern as check-git-status.sh.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/ForegroundProcess.swift`. Like
# ShellDirectory.swift it imports only Foundation/Darwin, so this script can compile
# it standalone with swiftc — no AppKit, no SwiftTerm, no app binary required. The
# Foundation-only ShellContext.swift + Osc7Directory.swift ride along so part (c) can ask
# the shipped typing guard (`TerminalInputPolicy.allowsTyping`) for its verdict.
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
# (c) The foreground GROUP: a `#!/bin/bash` script run from an interactive zsh that runs
#     the ssh stand-in (or sleep) WITHOUT exec leads a {bash, ssh} group and must read
#     `.remote` (typing refused); CONTROL: an interactive bash at its prompt is alone in
#     its group and stays `.knownShell` (typing allowed). Plus a refiningByGroup table.
#
# EXIT CODES (three-valued, matching check-cwd-follow.sh):
#   0 = every case passed
#   1 = a real assertion failed (the implementation is wrong)
#   2 = environmental failure (no swiftc, no C compiler, harness compile error,
#       openpty unavailable). A broken environment must never read as a green gate.
#
# FALSIFICATION (--falsify flag):
#   Applies six mutants to temp copies and asserts each one makes the gate exit 1.
#   Mutant 1: executableName always returns "zsh" (argv-based, not kernel path).
#   Mutant 2: the pid-equality guard removed (.shell becomes .knownShell always).
#   Mutant 3: clientTTY returns ttyname(primaryFd) (primary, not slave).
#   Mutant 4: the pid check moved ahead of the name switch (exec'd tmux/ssh → .shell).
#   Mutant 5: the launched-shell upgrade ignores the name (exec vim/afk → .shell).
#   Mutant 6: current() skips the group refinement (script wrapper → .knownShell). Its
#             DECLARED case is the real-pty script-wrapper case; failing anything else
#             (or nothing) is not a catch.
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
GROUP="Scripts/check-foreground-process-group.swift"
DEPS=("Sources/GoblinPortal/ShellContext.swift" "Sources/GoblinPortal/Osc7Directory.swift")

FALSIFY=0
[[ "${1:-}" == "--falsify" ]] && FALSIFY=1

[ -f "$SRC" ]     || { echo "ENV: $SRC not found";     exit 2; }
[ -f "$HARNESS" ] || { echo "ENV: $HARNESS not found"; exit 2; }
[ -f "$TABLE" ]   || { echo "ENV: $TABLE not found";   exit 2; }
[ -f "$GROUP" ]   || { echo "ENV: $GROUP not found";   exit 2; }
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
cp "$GROUP" "$WORK/group.swift"

if ! swiftc -O "$SRC" "${DEPS[@]}" "$WORK/main.swift" "$WORK/table.swift" "$WORK/group.swift" \
        -o "$WORK/run" 2>"$WORK/build.log"; then
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
    if ! swiftc -O "$mutant_src" "${DEPS[@]}" "$mwork/main.swift" "$WORK/table.swift" \
            "$WORK/group.swift" -o "$mwork/run" 2>/dev/null; then
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

# Mutant 5: the launched-shell upgrade ignores the name (any .command at the shell's pid
# becomes .shell), which would let `exec vim` / `exec afk` read as the shell and unlock
# typing. The "exec vim/afk at the shell pid → still .command" table rows must catch it.
M5="$WORK/mutant5.swift"
python3 - "$SRC" "$M5" << 'PYEOF'
import sys
text = open(sys.argv[1]).read()
old = 'case .command(let name)? = kind, name == launchedShellName else { return kind }'
new = 'case .command? = kind else { return kind } // MUTANT 5: name ignored'
assert text.count(old) == 1, "mutant 5 pattern not found"
open(sys.argv[2], 'w').write(text.replace(old, new, 1))
PYEOF
run_mutant "mutant 5: launched-shell upgrade ignores the name (exec vim/afk read as .shell)" "$M5" \
    || FAL_FAILURES=$((FAL_FAILURES+1))

# Mutant 6: current() returns the LEADER's kind without asking who else is in its group
# (the pre-fix behaviour: a `#!/bin/bash` wrapper running ssh read `.knownShell`). The
# pure refiningByGroup table still passes under it, so the DECLARED case is the real-pty
# "script wrapper" pair; the mutant counts only if every failing line is one of those.
# Pattern-not-found or a compile failure is environmental (exit 2), never a catch.
M6="$WORK/mutant6.swift"
if ! python3 - "$SRC" "$M6" << 'PYEOF'
import sys
text = open(sys.argv[1]).read()
old = '        return refiningByGroup(leader, memberNames: groupMemberNames(pgid: fgpid))\n'
new = '        return leader // MUTANT 6: group membership ignored\n'
if text.count(old) != 1: sys.exit(1)
open(sys.argv[2], 'w').write(text.replace(old, new, 1))
PYEOF
then echo "  ? mutant 6 — pattern no longer applies (environmental)"; exit 2; fi
M6W="$(mktemp -d)"
cp "$WORK/main.swift" "$M6W/main.swift"
if ! swiftc -O "$M6" "${DEPS[@]}" "$M6W/main.swift" "$WORK/table.swift" "$WORK/group.swift" \
        -o "$M6W/run" 2>/dev/null; then
    echo "  ? mutant 6 — did not compile (environmental)"; rm -rf "$M6W"; exit 2
fi
set +e; FP_WORK="$WORK" "$M6W/run" > "$M6W/out" 2>&1; M6CODE=$?; set -e
FAILED="$(grep '✗' "$M6W/out" || true)"; rm -rf "$M6W"
if [[ $M6CODE -eq 1 ]] && [[ -n "$FAILED" ]] && ! grep -qv 'script wrapper running' <<< "$FAILED"; then
    echo "  ✓ mutant 6: group refinement skipped → exit 1, caught only by the script-wrapper case"
else
    echo "  ✗ mutant 6: group refinement skipped → exit $M6CODE (WRONG-CASE or not caught)"
    [[ -n "$FAILED" ]] && echo "$FAILED"
    FAL_FAILURES=$((FAL_FAILURES+1))
fi

echo ""
if [[ $FAL_FAILURES -eq 0 ]]; then
    echo "all falsification mutants caught (exit 0)"; exit 0
fi
echo "$FAL_FAILURES falsification mutant(s) NOT caught — gate is blind"; exit 1
