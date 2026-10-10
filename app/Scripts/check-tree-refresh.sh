#!/bin/bash
#
# check-tree-refresh.sh — gate: main-thread-blocking detector for setRoot/refresh (#158).
#
# WHAT IS UNDER TEST
#   FileTreeViewController.setRoot and .refresh(), via the DirectoryListing.lister seam.
#   The seam is replaced with a stub that blocks on a semaphore for the root-level call,
#   so any synchronous reloadChildren() call will block the main thread for 300ms.
#   A 10ms repeating timer measures whether the run loop kept turning.
#
# EXIT CONTRACT
#   0  all 15 cases pass
#   1  real assertion failure
#   2  environmental (swiftc missing, build failed, objects missing, no window server)
#
# CASES
#   1. IDENTITY        — child node objects reused after refresh (green today)
#   2. EXPANSION       — expanded rows survive refresh (green today)
#   3. SAME-PATH       — setRoot same path skips listing (green today)
#   4. BLOCKING-SETROOT — heartbeat must fire during blocked listing
#   5. BLOCKING-REFRESH — same for refresh()
#   6. STALE-DROP       — setRoot(A), setRoot(B), A lands last: root B, no A rows
#   7. EDIT-DEFER       — landing during an inline edit is deferred, replayed after
#   8. MUTATION-INVALIDATES — a file op's sync refresh drops an in-flight async one
#   (6-8 live in check-tree-refresh-cases.swift)
#   9. NO-EMPTY-FRAME     — setRoot(B) in flight: outline keeps A's rows, never empty
#  10. REVEAL-IN-FLIGHT   — reveal during B's listing is queued and done on landing
#  11. SYNC-ADOPT         — refreshSynchronously() during B's listing shows B
#  12. NO-MAIN-LISTING    — no lister call from main during a landing
#  13. SELECTION-SURVIVES — selection reselected by URL after an async landing
#  14. SUBFOLDER-REFRESH  — a new file in an expanded subfolder appears on refresh
#  15. EXPAND-IN-FLIGHT   — a folder expanded mid-refresh keeps its children
#   (9-15 live in check-tree-refresh-invariants.swift)
#
# --falsify  runs check-tree-refresh-falsify.sh instead (mutation testing).
#
# HOW THE HANG IS AVOIDED
#   The blocking lister releases its semaphore from a background thread after 300ms,
#   so the harness always terminates (no infinite hang).  If main is blocked, the
#   timer simply cannot advance, and the tick count comes back 0.
#

set -uo pipefail

if [[ "${1:-}" == "--falsify" ]]; then
  exec "$(dirname "$0")/check-tree-refresh-falsify.sh"
fi

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HARNESS="$ROOT/Scripts/check-tree-refresh-harness.swift"
CASES="$ROOT/Scripts/check-tree-refresh-cases.swift"
INVARIANTS="$ROOT/Scripts/check-tree-refresh-invariants.swift"
PRODUCTS="$ROOT/.build/out/Products/Debug"

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found" >&2; exit 2; }
[[ -f "$HARNESS" && -f "$CASES" && -f "$INVARIANTS" ]] || {
  echo "error: harness not found: $HARNESS / $CASES / $INVARIANTS" >&2; exit 2; }

BFLAGS=()
swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)

say "==> building"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed" >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep 'error' | head -10 >&2
  exit 2
fi

TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/FileTreeViewController.o" ]] || {
  echo "error: GoblinPortal objects not found (expected FileTreeViewController.o)" >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Build a minimal temp tree the harness uses for identity/expansion tests.
#   a/  a/inner/  a/x.txt
#   b/  b/y.txt
TREE="$(mktemp -d "$TMP/tree.XXXXXX")"
mkdir -p "$TREE/a/inner" "$TREE/b"
echo "hello" > "$TREE/a/x.txt"
echo "world" > "$TREE/b/y.txt"

cp "$HARNESS" "$TMP/main.swift"
cp "$CASES" "$TMP/cases.swift"
cp "$INVARIANTS" "$TMP/invariants.swift"
OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')

say "==> compiling harness"
if ! swiftc -o "$TMP/gate" "$TMP/main.swift" "$TMP/cases.swift" "$TMP/invariants.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: harness compile failed" >&2
  grep 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

say "==> running gate"
out="$("$TMP/gate" "$TREE" 2>&1)"; hstatus=$?
say "$out"

# EXIT CONTRACT: pass harness exit code directly.
# 0 = all pass, 1 = real failure, 2 = environmental.
if [[ $hstatus -eq 0 ]]; then
  exit 0
elif [[ $hstatus -eq 1 ]]; then
  exit 1
else
  echo "error: harness exited with status $hstatus — treating as environmental" >&2
  exit 2
fi
