#!/bin/bash
#
# Runtime verification of three paths that shipped without an execution record:
#
#   1. CWD — ⌘T opens a shell whose initial directory is the Space root, not $HOME.
#   2. CONTEXT MENU — "New Terminal Here" is wired to a live responder, not a dead selector.
#   3. BEL → ATTENTION — printf '\a' in a background pane raises .attention on that pane.
#
# WHY THIS GATE EXISTS. Three behaviours were constructed and statically reviewed but never
# driven at runtime: the cwd fix was reading `root` at the right callsite, the context-menu
# wiring was reading `self` as target and `menuNewTerminal(_:)` as action, and the bell→status
# chain had delegate assignments that looked correct. Each is a short chain of two or three
# calls where a nil assignment, a mistyped selector, or an isActiveDocument guard-exit reads
# green in a code review and wrong at the keyboard. This gate drives all three.
#
# CASE 1 — CWD. `addTerminalDocument(start:workingDirectory:)` is called with `start: true`
# and a temp directory as the Space root. After the shell spawns, `ShellDirectory.shellCwd`
# reads the child's real cwd via `tcgetpgrp` + `proc_pidinfo`. That is exactly the same two
# syscalls the production `DirectoryFollow` poller uses, so a successful read here means the
# production follow path sees the right directory on its first tick. The check does NOT use
# OSC 7 — shell integration is opt-in and requires the user's shell config.
#
# CASE 2 — CONTEXT MENU. Verifies that the "New Terminal Here" menu item carries a non-nil
# target, the exact `menuNewTerminal(_:)` selector, and that the responder chain resolves it
# to a live object from the file-tree view. The full right-click path (NSMenuDelegate firing
# `menuNeedsUpdate`) also exercises the item-construction loop that sets `item.target = self`
# for every item with an action. Cannot reach: whether the menu appears at the cursor's
# position, whether it is keyboard-accessible, or whether the tap area is right — those need
# a real user event stream.
#
# CASE 3 — BEL → ATTENTION. Calls `view.feed(byteArray:)` with byte 0x07 (BEL) on a pane
# whose view has no superview, so `isActiveDocument` is false and the guard passes. Asserts
# `documentStatus == .attention`. Also asserts that feeding BEL to the ACTIVE pane (superview
# present) does NOT raise `.attention` — that is the guard's whole job and must be asserted
# separately from the positive case or a guard that always-passes reads green. Cannot reach:
# the NSSound.beep() side-effect (audio hardware), or the strip's repaint (visual output).
#
# EXIT CODES — the same three-valued contract as every other gate:
#   0 = all cases passed.
#   1 = a REAL failure — wrong cwd, selector mis-wired, status not raised, or guard bypassed.
#   2 = environmental — no swiftc, swift build failed, harness would not compile, or child
#       processes never appeared (the cwd case needs a real shell spawn).
#
# THE VERDICT IS THE EXIT CODE. The harness counts failures and exits on the count.
# A harness that died before printing any ok/FAIL line is treated as environmental (exit 2).
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

say "==> building (the harness links Goblin Portal's own objects, so they must be current)"
if ! swift build >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*Debug*GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/TerminalPane.o" ]] || {
  echo "error: no GoblinPortal objects under .build — cannot @testable import GoblinPortal." >&2
  echo "  Looked for '*Debug*GoblinPortal-p.build/Objects-normal/*/TerminalPane.o'. Try: swift build" >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SPACE_ROOT="$TMP/space-root"; mkdir -p "$SPACE_ROOT"

# Harness lives in its own file — see check-git-status.sh for the same split.
# Both files count independently against the 350-LOC ceiling (Scripts/ is gated).
HARNESS="$TMP/main.swift"
cp "$(dirname "$0")/check-runtime-paths-harness.swift" "$HARNESS" 2>/dev/null || {
  echo "error: check-runtime-paths-harness.swift not found beside this script." >&2; exit 2; }

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/runtimepaths" "$HARNESS" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  echo "  If a member is missing, the seam changed and this script needs updating." >&2
  echo "  If a linker symbol is missing, the object list above is stale." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

out="$("$TMP/runtimepaths" "$SPACE_ROOT" 2>&1)"; status=$?
say "$out"

if [[ $status -eq 0 ]]; then exit 0; fi
if [[ $status -eq 2 ]] || ! grep -q 'ok  \|FAIL ' <<<"$out"; then
  echo "error: harness could not judge the runtime paths (exit $status) — treating as environmental." >&2
  exit 2
fi
exit 1
