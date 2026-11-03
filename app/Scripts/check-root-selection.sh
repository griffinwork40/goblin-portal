#!/usr/bin/env bash
# check-root-selection.sh — T5.2 structural gate (#297)
#
# Asserts the "Spaces = project roots" invariant is structurally enforced:
# `defaultSpaceRoot` (the silent $HOME fallback) does not exist, and every
# Space-creation path routes through `selectProjectRoot()`.
#
# Part A: structural greps (no compilation needed).
# Part B: falsification — re-introducing `defaultSpaceRoot` on a COPY must fail.
#
# Exit codes: 0 = all pass, 1 = assertion failure, 2 = environmental.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${GATE_SRC_DIR:-$SCRIPT_DIR/../Sources/GoblinPortal}"

if [ ! -d "$SRC_DIR" ]; then
    echo "FAIL: Sources directory not found at $SRC_DIR" >&2
    exit 2
fi

PASS=0
FAIL=0

check() {
    local name="$1" result="$2"
    if [ "$result" -eq 0 ]; then
        echo "  PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Part A: structural assertions ==="

# A1: defaultSpaceRoot must NOT appear anywhere in Sources/
if grep -rq 'defaultSpaceRoot' "$SRC_DIR"; then
    check "A1 defaultSpaceRoot absent" 1
else
    check "A1 defaultSpaceRoot absent" 0
fi

# A2: selectProjectRoot must appear in AppDelegate.swift (the call sites)
if grep -q 'selectProjectRoot' "$SRC_DIR/AppDelegate.swift"; then
    check "A2 selectProjectRoot in AppDelegate.swift" 0
else
    check "A2 selectProjectRoot in AppDelegate.swift" 1
fi

# A3: selectProjectRoot must appear in SpaceRestore.swift (first-launch path)
if grep -q 'selectProjectRoot' "$SRC_DIR/SpaceRestore.swift"; then
    check "A3 selectProjectRoot in SpaceRestore.swift" 0
else
    check "A3 selectProjectRoot in SpaceRestore.swift" 1
fi

# A4: selectProjectRoot must be defined in AppDelegate+RootSelection.swift
if grep -q 'func selectProjectRoot' "$SRC_DIR/AppDelegate+RootSelection.swift"; then
    check "A4 selectProjectRoot defined in +RootSelection" 0
else
    check "A4 selectProjectRoot defined in +RootSelection" 1
fi

# A5: openDirectoryAsNewWindow must be defined in AppDelegate+RootSelection.swift
if grep -q 'func openDirectoryAsNewWindow' "$SRC_DIR/AppDelegate+RootSelection.swift"; then
    check "A5 openDirectoryAsNewWindow defined in +RootSelection" 0
else
    check "A5 openDirectoryAsNewWindow defined in +RootSelection" 1
fi

# A6: newSpace routes through selectProjectRoot, not defaultSpaceRoot
if grep -A3 'func newSpace' "$SRC_DIR/AppDelegate.swift" | grep -q 'selectProjectRoot'; then
    check "A6 newSpace calls selectProjectRoot" 0
else
    check "A6 newSpace calls selectProjectRoot" 1
fi

# A7: newSpaceInWindow routes through selectProjectRoot
if grep -A3 'func newSpaceInWindow' "$SRC_DIR/AppDelegate.swift" | grep -q 'selectProjectRoot'; then
    check "A7 newSpaceInWindow calls selectProjectRoot" 0
else
    check "A7 newSpaceInWindow calls selectProjectRoot" 1
fi

# A8: Menu items carry ellipsis (HIG: dialog follows)
if grep -q 'New Space\\u{2026}' "$SRC_DIR/AppMenu.swift"; then
    check "A8 New Space has ellipsis" 0
else
    check "A8 New Space has ellipsis" 1
fi

# A9: $HOME title shows "Home", not the username
if grep -q '"Home"' "$SRC_DIR/SpaceWindowController.swift" && \
   grep -q 'isHome' "$SRC_DIR/SpaceWindowController.swift"; then
    check "A9 Home title for \$HOME root" 0
else
    check "A9 Home title for \$HOME root" 1
fi

echo ""
echo "=== Part B: falsification ==="

# Create a temporary copy and re-introduce defaultSpaceRoot.
# The mutant must fail A1 (defaultSpaceRoot absent).
TMPDIR_COPY="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_COPY"' EXIT
cp -cR "$SRC_DIR" "$TMPDIR_COPY/src" 2>/dev/null || cp -R "$SRC_DIR" "$TMPDIR_COPY/src"

# Mutant: re-introduce defaultSpaceRoot in AppDelegate.swift
sed -i '' 's/func newSpace/private var defaultSpaceRoot: URL { FileManager.default.homeDirectoryForCurrentUser }\n    func newSpace/' "$TMPDIR_COPY/src/AppDelegate.swift"

if grep -rq 'defaultSpaceRoot' "$TMPDIR_COPY/src"; then
    check "F1 mutant detected (defaultSpaceRoot reintroduced)" 0
else
    # Mutant was NOT detected — the falsification itself failed
    check "F1 mutant detected (defaultSpaceRoot reintroduced)" 1
fi

echo ""
echo "--- $((PASS + FAIL)) checks: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
