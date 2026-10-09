#!/usr/bin/env bash
#
# check-shell-context.sh — the cwd rule (`ShellDirectoryPolicy.resolve`) and its wiring
# into a real `TerminalPane` (`TerminalPane+DirectoryState.swift`, OSC 7 storage in
# `TerminalPane+ShellIntegration.swift`), through a plain shell, a command, tmux and ssh.
#
# THIS GATE IS FOUR FILES, split on check-tmux-directory.sh's seam so each stays under the
# 350-line ceiling: this shell half owns isolation, cleanup and falsification;
# `check-shell-context-table.swift` is layer 1; `check-shell-context-harness.swift` and
# `check-shell-context-world.swift` are layer 2 (assertions, and the pty world they drive).
#
# LAYER 1 — PURE. Compiles the shipped ShellContext.swift + ForegroundProcess.swift +
# Osc7Directory.swift alone with swiftc and runs every ForegroundKind x report x
# directories cell of `resolve`, plus the named stale-report hazards. No AppKit.
#
# LAYER 2 — WIRING. Links the app's own objects (`@testable import GoblinPortal`, the
# check-runtime-paths.sh shape) and drives a REAL TerminalPane running a REAL zsh: a plain
# shell, `cd`, a command started from another directory, tmux on an isolated socket with a
# `cd` inside it and a detach, and a compiled fake `ssh` that prints a remote OSC 7. Every
# assertion reads the shipped `shellContext` / `currentDirectory` / delivery entry point.
#
# WHY. Before this gate, `currentDirectory` preferred an OSC 7 value that was never
# cleared and fell back to the FOREGROUND program's cwd, so tmux, ssh and agent REPLs
# all moved the sidebar, ⌘T, splits and split persistence to a wrong or remote path
# (plan `.afk/plans/tmux-ssh-cwd-and-158-parallel.md`, "Why"). Each of those was a
# precedence bug, invisible in a diff and obvious only when a real pty is driven.
#
# EXIT CODES, the house contract: 0 every case passed; 1 a real assertion failed; 2
# environmental (no swiftc/cc/tmux, build or harness compile failure, a shell that never
# spawned). The verdict is each layer's EXIT CODE, never a stdout substring.
#
# ISOLATION. Everything lives under a short `mktemp -d /tmp/gpctx.XXXXXX` (unix socket
# paths must fit sockaddr_un's 104 bytes). TMUX_TMPDIR is exported to that dir BEFORE the
# harness starts, so the app's tmux discovery (`TmuxDirectory.defaultSocketDirectories`)
# only ever sees the gate's server; the pane's tmux is started with the same TMUX_TMPDIR,
# `-L gate` and `-f /dev/null`. HOME is pointed at an empty temp home so the pane's login
# zsh loads no user rc file (and so never sources the integration script or starts the
# user's tmux). The EXIT trap kill-servers every socket under the work dir. The live
# default socket directory (/private/tmp/tmux-<uid>) is snapshotted before and after and
# must be unchanged. No UserDefaults domain is written (layer 2 never persists a split).
#
# FALSIFICATION. `--falsify` clones the whole app/ dir (including .build, via APFS
# `cp -cR`) into a temp dir with a `vendor` symlink beside it, mutates ONE shipped source
# file in the clone, checks its checksum changed, and runs the CLONED gate in normal mode.
# Mutant exit 1 = caught; 0 = NOT caught (falsify fails, exit 1); 2 = environmental
# (falsify exits 2). Harness expectations are never mutated; the real sources never are.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SRC="$ROOT/Sources/GoblinPortal"
SCRIPTS="$ROOT/Scripts"

command -v swiftc >/dev/null 2>&1 || { echo "ENV: no swiftc on PATH"; exit 2; }

if [ "${1:-}" = "--falsify" ]; then
    exec "$SCRIPTS/check-shell-context-falsify.sh"
fi

command -v cc >/dev/null 2>&1 || { echo "ENV: no C compiler on PATH"; exit 2; }
TMUX_BIN=""
for d in /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/bin; do
    [ -x "$d/tmux" ] && { TMUX_BIN="$d/tmux"; break; }
done
[ -n "$TMUX_BIN" ] || { echo "ENV: tmux not installed"; exit 2; }

REAL_DIR="/private/tmp/tmux-$(id -u)"
snapshot_real() { ls -A "$REAL_DIR" 2>/dev/null | LC_ALL=C sort || true; }
REAL_BEFORE="$(snapshot_real)"

WORK="$(mktemp -d /tmp/gpctx.XXXXXX)"
cleanup() {
    find "$WORK" -type s 2>/dev/null | while IFS= read -r sock; do
        "$TMUX_BIN" -S "$sock" kill-server >/dev/null 2>&1 || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT
# Set in THIS process's environment before anything runs: the harness inherits it, and
# with it the app code's socket discovery.
export TMUX_TMPDIR="$WORK"
unset TMUX TMUX_PANE

# ---------------------------------------------------------------- layer 1: pure table
echo "LAYER 1 — ShellDirectoryPolicy.resolve truth table"
mkdir -p "$WORK/pure"
cp "$SCRIPTS/check-shell-context-table.swift" "$WORK/pure/main.swift"
if ! swiftc -O "$SRC/ShellContext.swift" "$SRC/ForegroundProcess.swift" "$SRC/Osc7Directory.swift" \
        "$WORK/pure/main.swift" -o "$WORK/pure/run" 2>"$WORK/pure/build.log"; then
    echo "ENV: the truth table would not compile against the shipped sources"
    grep -E "error:" "$WORK/pure/build.log" | head -10 || true
    exit 2
fi
set +e
"$WORK/pure/run"; PURE=$?
set -e
echo "  layer 1 exit $PURE"
[ "$PURE" -eq 0 ] || [ "$PURE" -eq 1 ] || { echo "ENV: layer 1 exited $PURE"; exit 2; }

# ---------------------------------------------------------------- layer 2: wiring
echo "LAYER 2 — a real TerminalPane through shell / command / tmux / ssh"
PRODUCTS="$ROOT/.build/out/Products/Debug"
BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
if ! swift build "${BFLAGS[@]}" >"$WORK/swiftbuild.log" 2>&1; then
    echo "ENV: swift build failed"; grep -E 'error' "$WORK/swiftbuild.log" | head -10 || true
    exit 2
fi
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
    -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/TerminalPane.o" && -e "$PRODUCTS/SwiftTerm.o" ]] || {
    echo "ENV: GoblinPortal objects not found under .build/out"; exit 2; }

# The fake remote: a COMPILED binary named `ssh` (a copied /bin binary is SIGKILLed by
# code signing when run from a temp dir, which misled lane A). It prints exactly what a
# remote integrated shell would, then waits to be interrupted.
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/wire"
cat > "$WORK/bin/ssh.c" <<'C'
#include <stdio.h>
#include <unistd.h>
int main(void) {
    printf("\033]7;file://other-host/tmp\a");
    fflush(stdout);
    sleep(30);
    return 0;
}
C
cc -o "$WORK/bin/ssh" "$WORK/bin/ssh.c" 2>"$WORK/bin/cc.log" || {
    echo "ENV: could not compile the fake ssh"; exit 2; }
# An rc file must exist or zsh -l starts zsh-newuser-install, which waits for a keypress.
printf "PROMPT='gate%%# '\nunsetopt BEEP\n" > "$WORK/home/.zshrc"

cp "$SCRIPTS/check-shell-context-harness.swift" "$WORK/wire/main.swift"
cp "$SCRIPTS/check-shell-context-world.swift" "$WORK/wire/world.swift"
OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
# shellcheck disable=SC2086
if ! swiftc -o "$WORK/wire/run" "$WORK/wire/main.swift" "$WORK/wire/world.swift" \
        -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
        $OBJS "$PRODUCTS/SwiftTerm.o" -framework AppKit 2>"$WORK/wire/build.log"; then
    echo "ENV: the wiring harness would not compile (a seam changed, or stale objects)"
    grep -E 'error' "$WORK/wire/build.log" | head -10 || true
    exit 2
fi
set +e
HOME="$WORK/home" GATE_WORK="$WORK" GATE_TMUX="$TMUX_BIN" "$WORK/wire/run"; WIRE=$?
set -e
echo "  layer 2 exit $WIRE"

REAL_AFTER="$(snapshot_real)"
if [ "$REAL_BEFORE" != "$REAL_AFTER" ]; then
    echo "  ✗ the real default socket directory $REAL_DIR changed during the gate"
    exit 1
fi
echo "  ✓ $REAL_DIR listing unchanged ($(echo "$REAL_BEFORE" | grep -c . || true) entries)"

[ "$WIRE" -eq 0 ] || [ "$WIRE" -eq 1 ] || { echo "ENV: layer 2 exited $WIRE"; exit 2; }
[ "$PURE" -eq 0 ] && [ "$WIRE" -eq 0 ] && { echo "check-shell-context: PASS"; exit 0; }
exit 1
