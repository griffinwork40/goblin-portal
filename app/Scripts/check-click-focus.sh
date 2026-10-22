#!/bin/bash
#
# check-click-focus.sh
# Offscreen GUI gate: does CLICKING a split pane move focus AND the focus cue?
#
# WHAT IS UNDER TEST
#
# SpaceViewController+FirstResponderObserver.swift — KVO on NSWindow.firstResponder that
# re-runs updateSplitDimming (dimming + accent border). Before it, the only click hook was
# SplitContainerView.mouseDown, which a terminal click never reaches because SwiftTerm's
# MacTerminalView.mouseDown (vendor/.../Mac/MacTerminalView.swift:2496) never calls super.
# Keyboard focus moved on click; the visible cue stayed on the old pane.
#
# The cases live in check-click-focus-harness.swift (split harness, same pattern as
# check-focus-cue-k4.swift): a real ⌘⇧\ split and synthesized clicks by
# hit-testing each pane and calling mouseDown on the hit view directly (sendEvent
# delivers nothing in a never-key offscreen window), with each case split into a
# first-responder half and a cue half.
#
# FALSIFICATION (AFK.md Conventions: mutate a COPY of shipped source)
#
# app/ is APFS-cloned into $TMP once per mutant, the mutant applied to the CLONE, the clone
# rebuilt and the same harness linked against it. Three mutants, covering both halves of the
# fix and the 3-pane per-leaf path:
#   M1  subscribeToFirstResponderChanges(in:) removed from +WindowLifecycle.swift's
#       viewDidAppear → must fail C1-CUE with C1-FR still green (focus moves, cue stays)
#   M2  the makeFirstResponder line removed from GoblinPortalTerminalView+SmoothScroll.swift's
#       mouseDown → must fail C1-FR (the click no longer takes focus — the original bug)
#   M5  peerSubSplit leaf removed from gatherLeaves in +SplitFocus.swift:100 → must
#       fail C3-CUE with C1/C2 still green (no sub-split in C1/C2 so those leaves are
#       unaffected; sub-peer never enters the leaves array so updateFocusCue never moves
#       the border to it; exercises the leaves.count > 2 path in +SplitPresentation.swift)
# A mutant counts only if its declared case fails; failing some other way is WRONG-CASE
# (exit 1). A mutation that did not apply, or a clone that would not build, is exit 2.
#
# EXIT: 0 pass + mutant caught · 1 real failure or blind/wrong-case control · 2 environmental.
# THE VERDICT IS THE EXIT CODE; stdout lines only attribute a mutant's failure to its case.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HARNESS="$ROOT/Scripts/check-click-focus-harness.swift"
[[ -f "$HARNESS" ]] || { echo "error: $HARNESS not found." >&2; exit 2; }
command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# build_and_link <app-dir> <out-binary>: swift build the package at <app-dir>, then link
# the harness against its @testable GoblinPortal objects and SwiftTerm.o. Exit 2 on failure.
build_and_link() {
    local dir="$1" out="$2"
    if ! (cd "$dir" && swift build "${BFLAGS[@]}" >"$TMP/build.log" 2>&1); then
        echo "error: swift build failed in $dir" >&2
        grep -E 'error' "$TMP/build.log" | head -10 | sed 's/^/    /' >&2; exit 2
    fi
    local products="$dir/.build/out/Products/Debug" tobj
    tobj="$(find "$dir/.build/out/Intermediates.noindex" -type d \
        -path '*/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
    [[ -n "$tobj" && -f "$tobj/SpaceViewController.o" && -e "$products/SwiftTerm.o" ]] || {
        echo "error: GoblinPortal objects or SwiftTerm.o not found under $dir/.build" >&2; exit 2; }
    local objs; objs=$(ls "$tobj"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
    # shellcheck disable=SC2086
    if ! swiftc -o "$out" "$HARNESS" -I "$tobj" -I "$products" -I "$products/include" \
        -L "$products" $objs "$products/SwiftTerm.o" -framework AppKit 2>"$TMP/link.log"; then
        echo "error: harness would not compile against $dir" >&2
        grep -E 'error' "$TMP/link.log" | head -10 | sed 's/^/    /' >&2; exit 2
    fi
}

# ---------------------------------------------------------------------------
# Shipped code
# ---------------------------------------------------------------------------
say "==> building shipped app + harness"
build_and_link "$ROOT" "$TMP/click_focus"
out="$("$TMP/click_focus" 2>&1)"; status=$?
say "$out"
if [[ $status -eq 2 ]] || ! grep -qE '^  (ok|FAIL) ' <<<"$out"; then
    echo "error: harness reached no case (exit $status) — environmental." >&2; exit 2
fi
[[ $status -eq 0 ]] || { say ""; say "click-focus: shipped code FAILED."; exit 1; }

# ---------------------------------------------------------------------------
# Falsification — each mutant in its own CLONE; shipped source is never touched.
# ---------------------------------------------------------------------------
# Comment-stripped presence check: grep the construct, not the vocabulary.
has_line() { grep -v '^[[:space:]]*//' "$1" | grep -qF "$2"; }

# run_mutant <id> <rel-path> <literal-to-delete> <case-that-must-FAIL> [case-that-must-stay-ok]
run_mutant() {
    local id="$1" rel="$2" lit="$3" must_fail="$4" must_ok="${5:-}"
    local clone_root="$TMP/clone_$id" clone_app="$TMP/clone_$id/app"
    say ""; say "==> falsification $id: removing '$lit' from a clone of $rel"
    has_line "$ROOT/$rel" "$lit" || { echo "error: shipped $rel lacks '$lit' — gate out of date." >&2; exit 2; }
    mkdir -p "$clone_root"
    cp -cR "$ROOT/" "$clone_app/" 2>/dev/null || cp -R "$ROOT/" "$clone_app/"
    ln -sfn "$(cd "$ROOT/.." && pwd)/vendor" "$clone_root/vendor"
    python3 - "$clone_app/$rel" "$lit" <<'PY2'
import sys
path, lit = sys.argv[1], sys.argv[2]
src = open(path).read()
open(path, "w").write(src.replace(lit, "", 1))
PY2
    has_line "$clone_app/$rel" "$lit" && { echo "error: $id mutation did not apply." >&2; exit 2; }
    has_line "$ROOT/$rel" "$lit" || { echo "error: SHIPPED $rel was modified." >&2; exit 2; }
    build_and_link "$clone_app" "$TMP/mutant_$id"
    local mout mstatus; mout="$("$TMP/mutant_$id" 2>&1)"; mstatus=$?
    say "$mout" | grep -E '^  (ok|FAIL) ' | sed 's/^/    /'
    if [[ $mstatus -eq 2 ]]; then
        echo "error: $id run was environmental (exit 2) — control inconclusive." >&2; exit 2
    elif [[ $mstatus -eq 0 ]]; then
        say "  FAIL $id: mutant PASSED — the gate is blind to this half of the fix"; exit 1
    elif ! grep -q "FAIL $must_fail " <<<"$mout"; then
        say "  FAIL $id: WRONG-CASE — mutant failed, but $must_fail did not"; exit 1
    elif [[ -n "$must_ok" ]] && ! grep -q "ok   $must_ok " <<<"$mout"; then
        say "  FAIL $id: WRONG-CASE — $must_ok should stay green under this mutant"; exit 1
    fi
    say "  ok   $id caught by $must_fail${must_ok:+ (with $must_ok still green)}"
}

run_mutant M1 "Sources/GoblinPortal/SpaceViewController+WindowLifecycle.swift" \
    "subscribeToFirstResponderChanges(in: window)" C1-CUE C1-FR
run_mutant M2 "Sources/GoblinPortal/GoblinPortalTerminalView+SmoothScroll.swift" \
    "if window?.firstResponder !== self { window?.makeFirstResponder(self) }" C1-FR

# M5: remove the peerSubSplit leaf from gatherLeaves
# (SpaceViewController+SplitFocus.swift:100). Without it the sub-peer is never included
# in the leaves array, updateFocusCue never sees it, the border is never moved to it,
# and C3-CUE fails. C1/C2 have no peerSubSplit so they are unaffected — this is the
# only path that exercises the leaves.count > 2 branch in +SplitPresentation.swift:64-79.
run_mutant M5 "Sources/GoblinPortal/SpaceViewController+SplitFocus.swift" \
    "if let sub = entry.peerSubSplit { addLeaf(sub.document) }" C3-CUE C1-CUE

say ""
say "all click-focus cases passed (C0, C1, C2, C3) and all mutants were caught (M1, M2, M5)"
exit 0
