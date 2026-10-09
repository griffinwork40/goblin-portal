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
#   0  all 5 cases pass (expected ONLY after async listing is implemented)
#   1  real assertion failure (expected TODAY for BLOCKING-SETROOT and BLOCKING-REFRESH)
#   2  environmental (swiftc missing, build failed, objects missing, no window server)
#
# CASES
#   1. IDENTITY        — child node objects reused after refresh (green today)
#   2. EXPANSION       — expanded rows survive refresh (green today)
#   3. SAME-PATH       — setRoot same path skips listing (green today)
#   4. BLOCKING-SETROOT — heartbeat must fire during blocked listing (RED today)
#   5. BLOCKING-REFRESH — same for refresh() (RED today)
#
# HOW THE HANG IS AVOIDED
#   The blocking lister releases its semaphore from a background thread after 300ms,
#   so the harness always terminates (no infinite hang).  If main is blocked, the
#   timer simply cannot advance, and the tick count comes back 0.
#

set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HARNESS="$ROOT/Scripts/check-tree-refresh-harness.swift"
PRODUCTS="$ROOT/.build/out/Products/Debug"

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found" >&2; exit 2; }
[[ -f "$HARNESS" ]] || { echo "error: harness not found: $HARNESS" >&2; exit 2; }

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
OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')

say "==> compiling harness"
if ! swiftc -o "$TMP/gate" "$TMP/main.swift" \
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
