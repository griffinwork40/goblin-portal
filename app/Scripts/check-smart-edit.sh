#!/bin/bash
#
# check-smart-edit.sh — the re-entrancy guard pattern, statically.
#
# WHAT IS UNDER TEST. `FileViewerPane+SmartEditing.swift` uses a boolean flag
# (`isHandlingSmartEdit`) to guard against AppKit re-entering the delegate method
# `textView(_:shouldChangeTextIn:replacementString:)` during smart-edit transforms
# (tab→spaces, auto-indent, auto-pair, delete-pair). The correctness invariant is:
# every `isHandlingSmartEdit = true` assignment must be immediately followed by
# `defer { isHandlingSmartEdit = false }`, so the flag is always cleared on any
# exit path — including early `return false` — rather than relying on a trailing
# inline assignment that a future edit might accidentally skip or reorder.
#
# WHAT IT CANNOT CHECK, stated rather than implied. Whether the flag actually
# prevents infinite recursion at runtime, whether the four guarded blocks are all
# the sites that need guarding, or whether the delegate method is called at all.
# Those are live-AppKit territory: `textView(_:shouldChangeTextIn:replacementString:)`
# calls `insertText(_:replacementRange:)` which re-enters via the delegate, a
# path that requires a real `NSTextView` and a window server. A static analysis
# gate owns the structural invariant; daily use owns the dynamic behaviour.
#
# WHY STATIC ANALYSIS, NOT A COMPILED HARNESS. `FileViewerPane+SmartEditing.swift`
# imports AppKit and references `NSTextView`, `NSRange`, and the rest of the pane's
# stored properties — it cannot be compiled standalone the way Foundation-only files
# like `CommandOutcome.swift` or `Renderer.swift` can. An offscreen harness
# like `check-sidebar-toggle.sh` would work but requires `swift build` (30-60s) and
# linking all of Goblin Portal's objects, which is disproportionate for a two-line structural
# invariant that grep can verify in under a second. The check uses awk to enforce
# line adjacency: `defer { isHandlingSmartEdit = false }` must appear on the line
# IMMEDIATELY following `isHandlingSmartEdit = true`, with no intervening lines.
#
# EXIT CODES: 0 = invariant holds at all four sites. 1 = at least one `= true`
# assignment is missing its adjacent `defer` — a real structural regression.
# 2 = environmental: no swiftc on PATH (sanity check that the toolchain is present),
# or the source file is missing. A broken environment must never read as a green gate.
#
# Usage: ./Scripts/check-smart-edit.sh
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/FileViewerPane+SmartEditing.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }
[[ -f "$SRC" ]] || {
  echo "error: $SRC not found — did the file move? This gate names its subject explicitly." >&2
  exit 2; }

bad=0

# --- 1. Count `isHandlingSmartEdit = true` assignments. --------------------------------
# Each guarded block (tab→spaces, auto-indent, auto-pair, delete-pair) has exactly one.
# If the count drifts from 4, either a block was removed (gate is stale) or a new block
# was added without a corresponding check — both are signals worth surfacing.
true_count=$(grep -c 'isHandlingSmartEdit = true' "$SRC" || true)
if [[ "$true_count" -eq 4 ]]; then
    say "  ok  found exactly 4 'isHandlingSmartEdit = true' assignments"
else
    say "  FAIL expected 4 'isHandlingSmartEdit = true' assignments, found $true_count"
    say "       If a block was added, add a corresponding defer and update this gate."
    bad=$(( bad + 1 ))
fi

# --- 2. Every `= true` must be IMMEDIATELY followed by the defer line. -----------------
# awk reads pairs of consecutive lines. When line N matches `= true` and line N+1 does
# NOT match `defer { isHandlingSmartEdit = false }`, it is a violation.
# The adjacency requirement is load-bearing: the defer must appear before any work that
# could return early, so it must be the very next statement after the flag is set.
awk '
    /isHandlingSmartEdit = true/ {
        pending = NR
        next
    }
    pending > 0 {
        if ($0 !~ /defer \{ isHandlingSmartEdit = false \}/) {
            print "  line " pending ": isHandlingSmartEdit = true not followed by defer on next line"
            print "  line " NR ": found: " $0
            bad++
        }
        pending = 0
        next
    }
    END { exit bad }
' "$SRC"
awk_exit=$?

if [[ "$awk_exit" -ne 0 ]]; then
    say "  FAIL $awk_exit site(s) missing adjacent defer"
    bad=$(( bad + 1 ))
else
    say "  ok  every 'isHandlingSmartEdit = true' is immediately followed by defer"
fi

# --- 3. No stray inline `isHandlingSmartEdit = false` remain. --------------------------
# The inline assignment pattern (without defer) is what the fix replaces. Any surviving
# instance is either a missed site or a regression. The defer lines themselves contain
# this substring, so we exclude them.
stray=$(grep -n 'isHandlingSmartEdit = false' "$SRC" | grep -v 'defer' || true)
if [[ -z "$stray" ]]; then
    say "  ok  no stray inline 'isHandlingSmartEdit = false' (non-defer) found"
else
    say "  FAIL stray non-defer 'isHandlingSmartEdit = false' found:"
    while IFS= read -r line; do
        say "       $line"
    done <<< "$stray"
    bad=$(( bad + 1 ))
fi

# --- 4. FALSIFICATION PIN. ------------------------------------------------------------
# This gate must be capable of failing. The pin checks that the source file is not
# empty (which would trivially satisfy every grep above). Verified by running the gate
# against the pre-fix file (with inline = false instead of defer): checks 2 and 3
# both failed, confirming the gate is not vacuous.
line_count=$(wc -l < "$SRC" | tr -d ' ')
if [[ "$line_count" -lt 50 ]]; then
    say "  FAIL falsification pin: $SRC has only $line_count lines — looks truncated"
    bad=$(( bad + 1 ))
else
    say "  ok  falsification pin holds ($line_count lines in source)"
fi

echo
if [[ "$bad" -eq 0 ]]; then
    say "all smart-edit guard checks passed (assignment count + defer adjacency + no stray inline + falsification pin)"
    exit 0
else
    say "$bad smart-edit guard check(s) FAILED"
    exit 1
fi
