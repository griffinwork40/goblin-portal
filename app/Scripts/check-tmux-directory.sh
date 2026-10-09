#!/usr/bin/env bash
#
# check-tmux-directory.sh — headless truth table for TmuxDirectory, the unit that asks
# tmux where the active pane of OUR client is.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/TmuxDirectory.swift` (which server owns the
# tty, and what its answer means) and `TmuxDirectory+Subprocess.swift` (the deadline,
# pipe draining, process-group kill and reap). Both import Foundation/Darwin only so
# this script compiles them with swiftc alone, the check-cwd-follow.sh trick.
#
# THIS SCRIPT IS THREE FILES, split on check-git-status.sh's seam: this shell half owns
# isolation, cleanup and falsification; `check-tmux-directory-fixtures.swift` builds the
# world (real servers, REAL clients attached on openpty slaves, fake tmux binaries); and
# `check-tmux-directory-harness.swift` (copied to main.swift) asserts. Inline it would
# be ~560 lines, over check-file-size.sh's ceiling.
#
# WHY THIS EXISTS. `tmux display-message -c <tty>` does NOT fail for a tty the server
# does not own — measured on tmux 3.6a it exits 0 and answers for ANOTHER client. A
# resolver that trusts the exit status works in every single-server demo and hands back
# a stranger's directory the day a second tmux server exists. Only a gate with a decoy
# server and a real attached client can tell those apart, so that is what this builds.
#
# EXIT CODES, the house contract: 0 every case passed; 1 a real assertion failed; 2
# environmental (no tmux, no swiftc, a harness that would not compile, a fixture that
# would not build). The verdict is the harness's exit code, never a stdout substring.
#
# ISOLATION. Every server lives under a `mktemp -d` TMUX_TMPDIR, is addressed with an
# explicit `-S <path>` and started with `-f /dev/null`, and the EXIT trap kill-servers
# each one and removes the directory. The live default socket directory
# (/private/tmp/tmux-<uid>, in use on the author's machine) is snapshotted before and
# after and must be unchanged; the harness separately proves it never passed that
# directory to `current`. The harness runs with LANG/LC_* unset, like an app launched
# from Finder, which is the environment where tmux mangles UTF-8 without `-u`.
#
# FALSIFICATION. `--falsify` copies the two shipped sources to a temp dir, applies one
# mutant at a time to the COPY, re-runs this gate against it (GATE_SRC_DIR), and exits 0
# only if every mutant made the gate exit 1. The real sources are never modified.
#
# WHAT THIS CANNOT TEST: lane C's caching and threading (AppKit), and tmux versions other
# than the one installed. Measured timings are printed, not asserted beyond loose bounds.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SRC_DIR="${GATE_SRC_DIR:-$ROOT/Sources/GoblinPortal}"
UNIT="$SRC_DIR/TmuxDirectory.swift"
SUBPROCESS="$SRC_DIR/TmuxDirectory+Subprocess.swift"
FIXTURES="$ROOT/Scripts/check-tmux-directory-fixtures.swift"
HARNESS="$ROOT/Scripts/check-tmux-directory-harness.swift"

for f in "$UNIT" "$SUBPROCESS" "$FIXTURES" "$HARNESS"; do
    [ -f "$f" ] || { echo "ENV: $f not found"; exit 2; }
done
command -v swiftc >/dev/null 2>&1 || { echo "ENV: no swiftc on PATH"; exit 2; }
TMUX_BIN=""
for d in /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/bin; do
    [ -x "$d/tmux" ] && { TMUX_BIN="$d/tmux"; break; }
done
[ -n "$TMUX_BIN" ] || TMUX_BIN="$(command -v tmux || true)"
[ -n "$TMUX_BIN" ] || { echo "ENV: tmux not installed"; exit 2; }

if [ "${1:-}" = "--falsify" ]; then
    FWORK="$(mktemp -d /tmp/gptmux-falsify.XXXXXX)"
    trap 'rm -rf "$FWORK"' EXIT
    # name|python replacement on the copy: "old" -> "new" pairs, all must apply.
    mutant() {
        local name="$1" file="$2" old="$3" new="$4"
        rm -rf "$FWORK/src" && mkdir -p "$FWORK/src"
        cp "$UNIT" "$SUBPROCESS" "$FWORK/src/"
        if ! python3 - "$FWORK/src/$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
if text.count(old) != 1: sys.exit(1)
open(path, "w").write(text.replace(old, new))
PY
        then echo "ENV: mutant '$name' no longer applies — update --falsify"; exit 2; fi
        set +e
        GATE_SRC_DIR="$FWORK/src" "$0" >"$FWORK/$name.log" 2>&1
        local rc=$?
        set -e
        echo "  mutant $name: gate exit $rc ($(grep -c '✗' "$FWORK/$name.log" || true) cases red)"
        [ "$rc" -eq 1 ] || { echo "    BLIND: expected exit 1"; tail -5 "$FWORK/$name.log"; BLIND=1; }
    }
    BLIND=0
    echo "FALSIFY — each mutant of a COPY of the shipped source must turn the gate red"
    mutant no-ownership TmuxDirectory.swift \
        'guard tty == clientTTY, path.hasPrefix("/") else { return nil }' \
        '_ = tty; guard path.hasPrefix("/") else { return nil }'
    mutant first-answer-wins TmuxDirectory.swift \
        '            guard owner == nil else {' \
        '            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard owner == nil else {'
    mutant ignore-deadline TmuxDirectory.swift \
        'let deadline = now() + max(0, timeout)' 'let deadline = now() + 3600 + 0 * timeout'
    mutant skip-normalisation TmuxDirectory.swift \
        'return URL(fileURLWithPath: owner).standardizedFileURL.resolvingSymlinksInPath()' \
        'return URL(fileURLWithPath: owner)'
    # The two below were chosen to break things the assertions were NOT written around.
    mutant no-utf8-flag TmuxDirectory.swift \
        'let arguments = ["-u", "-S", socket.path,' 'let arguments = ["-S", socket.path,'
    mutant kill-child-not-group TmuxDirectory+Subprocess.swift \
        '        kill(-pid, SIGKILL)
' ''
    mutant stderr-undrained TmuxDirectory+Subprocess.swift \
        'pollfd(fd: err, events: Int16(POLLIN), revents: 0)]' 'pollfd(fd: -1, events: 0, revents: 0)]'
    [ "$BLIND" -eq 0 ] || { echo "FALSIFY: at least one mutant survived"; exit 1; }
    echo "FALSIFY: every mutant was caught"; exit 0
fi

REAL_DIR="/private/tmp/tmux-$(id -u)"
snapshot_real() { ls -A "$REAL_DIR" 2>/dev/null | LC_ALL=C sort || true; }
REAL_BEFORE="$(snapshot_real)"

# Short root under /tmp: a unix socket path must fit in 104 bytes (sockaddr_un), and
# $TMPDIR's /var/folders/... prefix eats half of that before the custom socket name.
WORK="$(mktemp -d /tmp/gptmux.XXXXXX)"
cleanup() {
    for sock in "$WORK"/*/tmux-*/* "$WORK"/tmux-*/* "$WORK"/stale-*/* ; do
        [ -S "$sock" ] && "$TMUX_BIN" -S "$sock" kill-server >/dev/null 2>&1 || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT
export TMUX_TMPDIR="$WORK"
unset TMUX TMUX_PANE

cp "$HARNESS" "$WORK/main.swift"
if ! swiftc -O "$UNIT" "$SUBPROCESS" "$FIXTURES" "$WORK/main.swift" -o "$WORK/run" 2>"$WORK/build.log"; then
    echo "ENV: the harness would not compile against TmuxDirectory"
    grep -E "error:" "$WORK/build.log" | head -10 || true
    exit 2
fi

set +e
env -u LANG -u LC_ALL -u LC_CTYPE GATE_WORK="$WORK" GATE_TMUX="$TMUX_BIN" \
    GATE_REAL_SOCKET_DIR="$REAL_DIR" "$WORK/run"
RC=$?
set -e

REAL_AFTER="$(snapshot_real)"
if [ "$REAL_BEFORE" != "$REAL_AFTER" ]; then
    echo "  ✗ the real default socket directory $REAL_DIR changed during the gate"
    diff <(echo "$REAL_BEFORE") <(echo "$REAL_AFTER") || true
    exit 1
fi
echo "  ✓ $REAL_DIR listing unchanged ($(echo "$REAL_BEFORE" | grep -c . || true) entries)"
exit "$RC"
