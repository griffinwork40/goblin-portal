#!/bin/bash
#
# check-shell-exit.sh — headless truth table for ShellExitPolicy.swift.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/ShellExitPolicy.swift` only. That file
# is Foundation-only BY DESIGN — the decision "waitpid status × closeOnShellExit policy
# → keep or close" is a pure function of its inputs, and a pure function compiles headless
# with swiftc: no NSView, no window server, no SwiftTerm. Same trick as
# check-command-outcome.sh (CommandOutcome.swift) and check-cwd-follow.sh.
#
# WHY IT SPAWNS REAL CHILDREN. The clean/unclean split depends on the POSIX waitpid
# status word, not a plain exit code. SwiftTerm passes the raw `waitpid` status word
# (LocalProcess.swift:368-369), not WEXITSTATUS. Two values that are easy to confuse:
#   • a normal exit(0)  → WIFEXITED && WEXITSTATUS == 0   (word == 0)
#   • a normal exit(3)  → WIFEXITED && WEXITSTATUS == 3   (word == 0x300)
#   • killed by SIGKILL → WIFSIGNALED && WTERMSIG == 9    (word == 9)
#
# A small C fixture forks real children and prints the raw waitpid words. The Swift
# harness feeds THOSE words to the shipped policy; no synthetic substitute stands in
# for the clean/nonzero/signal cases.
#
# FALSIFICATION. A sed-mutated COPY of the shipped policy (not the original) is compiled
# and required to exit 1: this confirms the gate is not blind to the mutation.
#
# EXIT CODES (same three-valued contract as check-reflow.sh, check-command-outcome.sh):
#   0 = all cases passed.
#   1 = a REAL assertion failed (policy mapped a status wrongly).
#   2 = environmental (no toolchain, source file missing, harness would not compile).
#     A broken environment must NEVER read as a green gate.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/ShellExitPolicy.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "ENV: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }
command -v cc >/dev/null 2>&1 || {
    echo "ENV: cc not found — no C toolchain on PATH." >&2; exit 2; }
[[ -f "$SRC" ]] || {
    echo "ENV: $SRC not found — did the file move?" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$SRC" "$TMP/ShellExitPolicy.swift"

cat > "$TMP/exit-status.c" <<'C'
#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
int main(void) {
    for (int i = 0; i < 3; i++) {
        pid_t child = fork();
        if (child < 0) return 2;
        if (child == 0) {
            if (i == 2) { raise(SIGKILL); _exit(99); }
            _exit(i == 0 ? 0 : 3);
        }
        int status = -1;
        if (waitpid(child, &status, 0) != child) return 2;
        printf("%d%s", status, i == 2 ? "\n" : " ");
    }
    return 0;
}
C
if ! cc "$TMP/exit-status.c" -o "$TMP/exit-status"; then
    echo "ENV: real-child fixture did not compile" >&2; exit 2
fi
if ! WORDS="$($TMP/exit-status)"; then
    echo "ENV: real-child waitpid fixture failed" >&2; exit 2
fi
set -- $WORDS
[[ $# -eq 3 ]] || { echo "ENV: real-child fixture gave $# words" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Main harness
# ---------------------------------------------------------------------------
cat > "$TMP/main.swift" <<'SWIFT'
import Darwin
import Foundation

var bad = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("  \u{2713} \(label)")
    } else {
        print("  \u{2717} \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
        bad += 1
    }
}

// These are raw kernel waitpid words from the C fixture's three real children.
// An invalid invocation is environmental, not a successful policy verdict.
guard CommandLine.arguments.count == 4,
      let ws0 = Int32(CommandLine.arguments[1]),
      let ws3 = Int32(CommandLine.arguments[2]),
      let wsKill = Int32(CommandLine.arguments[3]) else { exit(2) }
check("real exit 0 status", WIFEXITED(ws0) && WEXITSTATUS(ws0) == 0, "ws=\(ws0)")
check("real exit 3 status", WIFEXITED(ws3) && WEXITSTATUS(ws3) == 3, "ws=\(ws3)")
check("real SIGKILL status", WIFSIGNALED(wsKill) && WTERMSIG(wsKill) == SIGKILL, "ws=\(wsKill)")

// MARK: - CloseOnShellExit.named(_:) parsing

check("parse 'clean'",  CloseOnShellExit.named("clean")  == .clean)
check("parse 'always'", CloseOnShellExit.named("always") == .always)
check("parse 'never'",  CloseOnShellExit.named("never")  == .never)
check("parse 'CLEAN' (case-insensitive)", CloseOnShellExit.named("CLEAN") == .clean)
check("parse unknown returns nil",        CloseOnShellExit.named("yes")   == nil)

// MARK: - ShellExitPolicy.decide — mode: .always

check("always + exit(0) → close",  ShellExitPolicy.decide(waitStatus: ws0,    mode: .always) == .close)
check("always + exit(3) → close",  ShellExitPolicy.decide(waitStatus: ws3,    mode: .always) == .close)
check("always + SIGKILL → close",  ShellExitPolicy.decide(waitStatus: wsKill, mode: .always) == .close)
check("always + nil → close",      ShellExitPolicy.decide(waitStatus: nil,    mode: .always) == .close)

// MARK: - ShellExitPolicy.decide — mode: .never

check("never + exit(0) → keep",    ShellExitPolicy.decide(waitStatus: ws0,    mode: .never) == .keep)
check("never + exit(3) → keep",    ShellExitPolicy.decide(waitStatus: ws3,    mode: .never) == .keep)
check("never + SIGKILL → keep",    ShellExitPolicy.decide(waitStatus: wsKill, mode: .never) == .keep)
check("never + nil → keep",        ShellExitPolicy.decide(waitStatus: nil,    mode: .never) == .keep)

// MARK: - ShellExitPolicy.decide — mode: .clean (the key cases)

check("clean + exit(0) → close  [THE KEY CASE]",
    ShellExitPolicy.decide(waitStatus: ws0,    mode: .clean) == .close)
check("clean + exit(3) → keep   [THE KEY CASE]",
    ShellExitPolicy.decide(waitStatus: ws3,    mode: .clean) == .keep)
check("clean + SIGKILL → keep   [THE KEY CASE]",
    ShellExitPolicy.decide(waitStatus: wsKill, mode: .clean) == .keep)
check("clean + nil → keep (I/O error = unclean)",
    ShellExitPolicy.decide(waitStatus: nil,    mode: .clean) == .keep)

// MARK: - ShellExitPolicy.exitDescription

let descClean  = ShellExitPolicy.exitDescription(waitStatus: ws0)
let descFail   = ShellExitPolicy.exitDescription(waitStatus: ws3)
let descSignal = ShellExitPolicy.exitDescription(waitStatus: wsKill)
let descNil    = ShellExitPolicy.exitDescription(waitStatus: nil)

check("exitDescription exit(0): 'code 0'",     descClean.contains("code 0"),   descClean)
check("exitDescription exit(3): 'code 3'",     descFail.contains("code 3"),    descFail)
check("exitDescription SIGKILL: 'SIGKILL'",    descSignal.contains("SIGKILL"), descSignal)
check("exitDescription nil: 'exited'",         descNil.contains("exited"),     descNil)

// MARK: - ShellExitPolicy.statusLine format

let line = ShellExitPolicy.statusLine(waitStatus: ws3, canRestart: true)
check("statusLine: starts with '['",   line.hasPrefix("["), line)
check("statusLine: ends with ']'",     line.hasSuffix("]"), line)
check("statusLine: contains 'Return'", line.contains("Return"), line)
check("statusLine: contains '\u{2318}W'", line.contains("\u{2318}W"), line)

let lineNoRestart = ShellExitPolicy.statusLine(waitStatus: ws3, canRestart: false)
check("statusLine(noRestart): no 'Return'", !lineNoRestart.contains("Return"), lineNoRestart)

// MARK: - ShellExitPolicy.signalName spot checks

check("signalName(SIGKILL) == 'SIGKILL'", ShellExitPolicy.signalName(SIGKILL) == "SIGKILL")
check("signalName(SIGTERM) == 'SIGTERM'", ShellExitPolicy.signalName(SIGTERM) == "SIGTERM")
check("signalName(SIGHUP)  == 'SIGHUP'",  ShellExitPolicy.signalName(SIGHUP)  == "SIGHUP")
check("signalName(999) starts 'signal'",  ShellExitPolicy.signalName(999).hasPrefix("signal"))

// MARK: - Done

if bad == 0 {
    print("All cases passed.")
    exit(0)
} else {
    print("\(bad) case(s) failed.")
    exit(1)
}
SWIFT

say "Compiling harness against shipped ShellExitPolicy.swift..."
if ! swiftc -O "$TMP/ShellExitPolicy.swift" "$TMP/main.swift" -o "$TMP/harness" 2>"$TMP/compile.err"; then
    echo "ENV: harness did not compile:" >&2
    cat "$TMP/compile.err" >&2
    exit 2
fi

say "Running truth table..."
if ! "$TMP/harness" "$1" "$2" "$3"; then
    exit 1
fi

# ---------------------------------------------------------------------------
# Falsification: mutate a COPY and require exit 1.
#
# Mutation: remove the WEXITSTATUS check in the clean-mode branch so that
# exit(0) AND exit(3) both decide .close (erasing the "keep on nonzero" logic).
# This is a NON-OBVIOUS change — it does not delete a case, it widens the close
# condition. If the gate still exits 0 after this mutation, it is blind.
# ---------------------------------------------------------------------------
say ""
say "Falsification: mutated policy must fail..."

MUTATED="$TMP/ShellExitPolicy_mutated.swift"
# Widen the clean-exit test: WIFEXITED alone (any exit code) → close.
# Before: if WIFEXITED(ws) && WEXITSTATUS(ws) == 0 { return .close }
# After:  if WIFEXITED(ws)                          { return .close }
sed 's/if WIFEXITED(ws) && WEXITSTATUS(ws) == 0 { return .close }/if WIFEXITED(ws) { return .close }/' \
    "$TMP/ShellExitPolicy.swift" > "$MUTATED"
if cmp -s "$MUTATED" "$TMP/ShellExitPolicy.swift"; then
    echo "FAIL: falsification mutation did not match shipped policy" >&2; exit 1
fi

if ! swiftc -O "$MUTATED" "$TMP/main.swift" -o "$TMP/harness_mutated" 2>/dev/null; then
    echo "ENV: mutated harness did not compile — falsification inconclusive" >&2; exit 2
else
    "$TMP/harness_mutated" "$1" "$2" "$3" >/dev/null 2>&1
    mutant_status=$?
    if [[ "$mutant_status" -ne 1 ]]; then
        echo "FAIL: falsification — mutated policy exited $mutant_status, expected 1." >&2
        exit 1
    fi
    say "  ✓ falsification: mutated policy correctly exits 1"
fi

say ""
say "check-shell-exit: all cases passed."
exit 0
