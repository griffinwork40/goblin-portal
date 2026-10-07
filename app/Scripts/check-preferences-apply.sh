#!/bin/bash
#
# Does the preferences panel seed controls from the correct defaults, and write
# only changed keys back to config.json?
#
# WHAT IS UNDER TEST.
#   `Sources/GoblinPortal/PreferencesDiff.swift`  — pure seeding + diff logic.
#   `Sources/GoblinPortal/CursorStyle.swift`      — CursorStyle.default / .configName.
#   `Sources/GoblinPortal/Renderer.swift`         — Renderer.default / .configName.
#   `Sources/GoblinPortal/ThemeValues.swift`      — ThemePalette.classicRepaired.name.
#   All four are Foundation-only by design, so this gate compiles them together with
#   swiftc and no AppKit.  Same discipline as check-paste-guard.sh, check-renderer-config.sh,
#   and check-cursor-style.sh.
#
# WHY IT EXISTS — two bugs, one gate.
#   BUG 1: WRONG SEED DEFAULTS.  loadCurrentValues seeded the renderer popup with
#   "coretext" and the cursor popup with "block" when those keys were absent.
#   Renderer.default is .metal ("metal") and CursorStyle.default is .steadyBlock
#   ("steady-block").  Opening ⌘, and pressing Apply on a fresh config silently
#   wrote "coretext", downgrading the renderer.
#   BUG 2: OVERLY BROAD WRITE.  When ANY preference changed, ALL managed keys were
#   written.  A font-size change silently added renderer, cursor, and theme to config.json.
#   PreferencesDiff.changedKeys now returns the exact set of changed keys; saveValues
#   writes only those.
#
# WHAT IT CANNOT REACH.  The NSPopUpButton/NSTextField UI layer, writeConfigDict disk
# writes, and the live AppDelegate.reloadConfig call — all require AppKit and a window
# server and are daily-drive territory.
#
# SPLIT HARNESS.  The Swift assertions live in Scripts/check-preferences-apply-harness.swift
# (compiled and copied to main.swift in a temp dir).  Same pattern as check-git-status.sh /
# check-git-status-harness.swift — the combined shell+inline-Swift form pushed past 350 LOC.
#
# FALSIFICATION.  Part B mutates a temp copy of PreferencesDiff.swift to replace
# `Renderer.default.configName` with the literal `"coretext"`.  The harness must exit 1
# (case S1 catches the seed mismatch).  If it exits 0 the gate is blind.
#
# EXIT CODES.  0 = all passed.  1 = real failure.  2 = environmental (no toolchain,
# missing source, harness won't compile, falsification sed didn't mutate).

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."

SRC_DIFF="Sources/GoblinPortal/PreferencesDiff.swift"
SRC_CURSOR="Sources/GoblinPortal/CursorStyle.swift"
SRC_RENDERER="Sources/GoblinPortal/Renderer.swift"
SRC_THEME="Sources/GoblinPortal/ThemeValues.swift"
# ThemeValues+CommunityPresets.swift extends ThemePalette with gruvboxDark and
# rosePine, both referenced in ThemePalette.all — the extension must be compiled
# together with ThemeValues.swift or the linker cannot resolve those members.
SRC_THEME_EXT="Sources/GoblinPortal/ThemeValues+CommunityPresets.swift"
HARNESS="Scripts/check-preferences-apply-harness.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2
}
for f in "$SRC_DIFF" "$SRC_CURSOR" "$SRC_RENDERER" "$SRC_THEME" "$SRC_THEME_EXT" "$HARNESS"; do
    [[ -f "$f" ]] || {
        echo "error: $f not found — did the file move?" >&2; exit 2
    }
done

TMP=$(mktemp -d) || { echo "error: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# swiftc requires top-level code in a file named main.swift.
cp "$HARNESS" "$TMP/main.swift"

# ---------------------------------------------------------------------------
# Part A: compile and run against the shipped sources.
# ---------------------------------------------------------------------------
if ! swiftc -o "$TMP/prefsapply" \
        "$SRC_DIFF" "$SRC_CURSOR" "$SRC_RENDERER" "$SRC_THEME" "$SRC_THEME_EXT" \
        "$TMP/main.swift" 2>"$TMP/compile.log"; then
    echo "error: harness would not compile against shipped sources." >&2
    echo "  If this names AppKit, PreferencesDiff.swift is no longer Foundation-only" >&2
    echo "  — that is the regression, not a compile flag issue." >&2
    grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
fi

say "Part A — shipped sources:"
OUT="$("$TMP/prefsapply" 2>&1)"; STATUS=$?
say "$OUT"
if [[ "$STATUS" != "0" ]]; then
    echo "✗ FAIL: check-preferences-apply.sh — shipped sources (exit $STATUS)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Part B: FALSIFICATION.
# Mutate PreferencesDiff.swift — replace Renderer.default.configName with "coretext".
# The harness must exit 1 (case S1 catches it).  Exit 0 means the gate is blind.
# ---------------------------------------------------------------------------
say ""
say "Part B — falsification (mutating renderer seed to literal \"coretext\"):"

MUTATED="$TMP/PreferencesDiff_mutated.swift"
sed 's/Renderer\.default\.configName/"coretext"/g' "$SRC_DIFF" > "$MUTATED"

if diff -q "$SRC_DIFF" "$MUTATED" >/dev/null 2>&1; then
    echo "error: falsification sed did not mutate — gate is blind." >&2; exit 2
fi

if ! swiftc -o "$TMP/prefsapply_mutated" \
        "$MUTATED" "$SRC_CURSOR" "$SRC_RENDERER" "$SRC_THEME" "$SRC_THEME_EXT" \
        "$TMP/main.swift" 2>"$TMP/compile_mutated.log"; then
    echo "error: mutated harness would not compile — check the sed pattern." >&2
    grep -E 'error' "$TMP/compile_mutated.log" | head -5 | sed 's/^/    /' >&2
    exit 2
fi

FALSIFY_OUT="$("$TMP/prefsapply_mutated" 2>&1)"; FALSIFY_STATUS=$?
if [[ "$FALSIFY_STATUS" == "0" ]]; then
    say "$FALSIFY_OUT"
    echo "error: falsification FAILED — mutated harness exited 0." >&2
    echo "  Gate cannot detect the literal-'coretext' bug.  Gate is BLIND (exit 2)." >&2
    exit 2
fi

say "  ok  mutated harness correctly exited $FALSIFY_STATUS (case S1 caught the literal)"
say ""
echo "check-preferences-apply.sh: all parts passed (Part A: shipped, Part B: falsification)"
exit 0
