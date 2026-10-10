#!/bin/bash
#
# check-file-tree-ops.sh — offscreen GUI behavioural gate for the file tree.
#
# WHAT IS UNDER TEST. FileTreeViewController (assembled by SpaceWindowController),
# its +FileOps, +Mutation, +DragDrop extensions, FileTreeOutlineView and
# FileOperationPolicy. Drives the real controller through its public seams.
#
# The Swift assertions are split across two files compiled together:
#   check-file-tree-ops-harness.swift — scaffolding, helpers, cases 1–5, entry point.
#   check-file-tree-ops-cases.swift   — cases 6–11.
# Same two-file split as check-sidebar-activity.sh / check-sidebar-activity-harness.swift.
# Both files are under the 350-LOC ceiling.
#
# EXIT CONTRACT:
#   0 = all cases passed.
#   1 = real assertion failure.
#   2 = environmental (swiftc missing, build failed, objects missing,
#       compile error, harness crash before any case was printed).
#
# CASES (in the harness):
#   1.  fileOpsDelegate is set after loadView (H1).
#   2.  New File committed as "Makefile" creates a regular file (C1, extension).
#   3.  New Folder creates a directory; cancelled New File creates nothing new.
#   4.  Case-only rename b/y.txt → Y.txt: directory shows "Y.txt", not "y.txt".
#   5.  Trash: false confirmation keeps file; true confirmation removes it.
#   6.  Context-menu action targets representedObject, not the selection.
#   7.  setRoot during inline edit is deferred; applied after commit.
#   8.  Cut+Paste moves; Copy+Paste to different folder keeps name; Duplicate suffixes.
#   9.  Drag: pasteboardWriterForItem returns non-nil; validateDrop refuses descendant.
#  10.  Expansion survives a sibling rename.
#  11.  CONTROL: a deliberately wrong assertion must fail inside a sub-check.
#  12.  Rename of the Space's sole FileViewerPane keeps the window open; tab URL
#       updated (PR #157 window-survival fix — close-before-open regression guard).
#  13.  Trash of the Space's sole FileViewerPane keeps the window open; tab left
#       open with stale URL rather than closing the Space (PR #157 fix).
#  14.  Rename onto a path that already has an open tab reorders THAT tab, not
#       the last one (openFile dedupes; PR #157 round-2 fix).
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"
HARNESS="$ROOT/Scripts/check-file-tree-ops-harness.swift"
CASES="$ROOT/Scripts/check-file-tree-ops-cases.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

[[ -f "$HARNESS" ]] || {
  echo "error: $HARNESS not found — harness file is missing." >&2; exit 2; }
[[ -f "$CASES" ]] || {
  echo "error: $CASES not found — cases file is missing." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
say "==> building (the harness links Goblin Portal's own objects)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/FileTreeViewController.o" ]] || {
  echo "error: GoblinPortal objects not found (expected FileTreeViewController.o)." >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Build the small temp tree the harness expects:
#   a/  a/inner/  a/x.txt
#   b/  b/y.txt
TREE="$(mktemp -d "$TMP/filetree.XXXXXX")"
mkdir -p "$TREE/a/inner" "$TREE/b"
echo "hello" > "$TREE/a/x.txt"
echo "world" > "$TREE/b/y.txt"

# Copy both source files. The harness file is renamed main.swift so swiftc
# treats it as the module's entry point; the cases file keeps its name.
cp "$HARNESS" "$TMP/main.swift"
cp "$CASES"   "$TMP/check-file-tree-ops-cases.swift"

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/filetreeops" "$TMP/main.swift" "$TMP/check-file-tree-ops-cases.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

# Exit-code contract: pass harness exit directly.
# 0 = pass, 1 = real failure, 2 = environmental.
out="$("$TMP/filetreeops" "$TREE" 2>&1)"; hstatus=$?
say "$out"

if [[ $hstatus -eq 0 ]]; then
  exit 0
elif [[ $hstatus -eq 1 ]]; then
  # Exit code is the verdict: harness exit 1 = real assertion failure.
  # No stdout-substring check — the exit code alone is authoritative.
  exit 1
else
  echo "error: harness exited with status $hstatus — treating as environmental." >&2
  exit 2
fi
