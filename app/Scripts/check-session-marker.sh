#!/bin/bash
#
# check-session-marker.sh — offscreen GUI gate: does a Source Control row whose path is
# in the session DRAW the accent marker, and only that row (#298, T5.5)?
#
# WHAT IS UNDER TEST. `SourceControlRowView.drawBackground(in:)` and `configure`, fed
# through the real fanout `SpaceViewController.updateSourceControl(snapshot:repository:)`
# and `resetSessionHighlights(_:)`. check-session-stage.sh gates WHICH files are staged;
# it cannot see a pixel. This gate renders the rows of a real panel in a real Space
# window to bitmaps (`cacheDisplay`, see the harness header for the measurement).
#
# WHY ITS OWN GATE. The row view is AppKit; the stage gate compiles Foundation-only
# units and runs in CI. This one needs a window server, so it stays local like the
# other offscreen GUI gates (check-sidebar-activity.sh, check-focus-cue.sh), whose
# build-and-link scaffolding it copies.
#
# CASES (in check-session-marker-harness.swift):
#   M4   the fanout hands the panel this tick's session set
#   M1   the session row's strip carries the fill; M1b the non-session row's does not;
#        M1c the fill is the accent colour
#   M2   the selected session row yields to the selection
#   M3   Clear's same-turn baseline seeding via gitStatusDidChange() empties the
#        session immediately; the cleared row also loses the marker pixel; M3b one row
#        view re-configured for a non-session file (what a recycle does) loses it too
#
# FALSIFICATION (--falsify; AFK.md Conventions). app/ is APFS-cloned, a mutant is
# applied to the CLONE's source with sed, the clone is rebuilt and the harness relinked
# against its objects. A mutant counts only when ITS declared case fails. A pattern
# that no longer applies, a clone that does not build, or a harness that exits 2 makes
# this script exit 2.
#   x1  drawBackground's fill deleted                     → M1
#   x2  configure no longer clears the flag on recycle    → M3b
#   x3  the fanout no longer pushes the set to the panel  → M4
#   x4  the selected-row guard deleted                    → M2
#   x5  gitStatusDidChange() removed from resetSession…   → M3 (same-turn baseline)
#
# exit 0 = all pass; 1 = a case failed or a mutant was missed; 2 = environmental.
#
set -uo pipefail

FALSIFY=0
[[ "${1:-}" == "--falsify" ]] && FALSIFY=1

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HARNESS="$ROOT/Scripts/check-session-marker-harness.swift"

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found." >&2; exit 2; }
[[ -f "$HARNESS" ]] || { echo "error: $HARNESS not found." >&2; exit 2; }
[[ -x /usr/bin/git ]] || { echo "error: /usr/bin/git missing." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)

TMP="$(mktemp -d)"; trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=gate GIT_AUTHOR_EMAIL=gate@goblin-portal
export GIT_COMMITTER_NAME=gate GIT_COMMITTER_EMAIL=gate@goblin-portal

# build_and_run APPDIR LABEL — build APPDIR, link the harness against its objects, run it
# on fresh temp dirs; echo the harness exit code (2 for any build or link failure).
build_and_run() {
    local appdir="$1" label="$2"
    if ! (cd "$appdir" && swift build "${BFLAGS[@]}" >"$TMP/$label.build.log" 2>&1); then
        echo "error: swift build failed for $label." >&2
        grep -E 'error' "$TMP/$label.build.log" | head -5 >&2
        echo 2; return
    fi
    local products="$appdir/.build/out/Products/Debug" tobj objs
    tobj="$(find "$appdir/.build/out/Intermediates.noindex" -type d \
        -path '*/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
    if [[ -z "$tobj" || ! -e "$products/SwiftTerm.o" ]]; then
        echo "error: objects or SwiftTerm.o missing for $label." >&2; echo 2; return
    fi
    objs=$(ls "$tobj"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
    mkdir -p "$TMP/$label"
    cp "$HARNESS" "$TMP/$label/main.swift"
    if ! swiftc -o "$TMP/$label/harness" "$TMP/$label/main.swift" \
        -I "$tobj" -I "$products" -I "$products/include" -L "$products" \
        $objs "$products/SwiftTerm.o" -framework AppKit 2>"$TMP/$label.link.log"; then
        echo "error: harness would not compile for $label." >&2
        grep -E 'error' "$TMP/$label.link.log" | head -5 >&2
        echo 2; return
    fi
    local space repo rc=0
    space="$(mktemp -d "$TMP/space.XXXXXX")"; repo="$(mktemp -d "$TMP/repo.XXXXXX")"
    "$TMP/$label/harness" "$space" "$repo" >"$TMP/$label.out" 2>&1 || rc=$?
    echo "$rc"
}

echo "==> shipped"
rc="$(build_and_run "$ROOT" shipped)"
grep -v 'Obj-C `-hash`' "$TMP/shipped.out" 2>/dev/null
case "$rc" in
    0) ;;
    1) echo "FAIL: session-marker cases" >&2; exit 1 ;;
    *) echo "ENV: shipped harness exited $rc" >&2; exit 2 ;;
esac
if [[ $FALSIFY -eq 0 ]]; then
    echo ""; echo "all session-marker cases passed (run with --falsify for the 5 mutants)"
    exit 0
fi

echo ""
echo "==> falsification (APFS clone per mutant)"
CLONE_ROOT="$TMP/clone"
mkdir -p "$CLONE_ROOT"
cp -cR "$ROOT/" "$CLONE_ROOT/app/" 2>/dev/null || cp -R "$ROOT/" "$CLONE_ROOT/app/"
ln -sfn "$(cd "$ROOT/.." && pwd)/vendor" "$CLONE_ROOT/vendor"
SRC="$CLONE_ROOT/app/Sources/GoblinPortal"
caught=0; missed=0

# run_mutant NAME FILE SED_EXPR DECLARED DESCRIPTION — the clone is restored after each.
run_mutant() {
    local name="$1" file="$2" expr="$3" declared="$4" desc="$5"
    cp "$ROOT/Sources/GoblinPortal/$file" "$SRC/$file"
    sed -i '' "$expr" "$SRC/$file"
    if cmp -s "$ROOT/Sources/GoblinPortal/$file" "$SRC/$file"; then
        echo "ENV: $name pattern no longer applies to $file" >&2; exit 2
    fi
    local mrc
    mrc="$(build_and_run "$CLONE_ROOT/app" "$name")"
    cp "$ROOT/Sources/GoblinPortal/$file" "$SRC/$file"
    if [[ "$mrc" != 0 && "$mrc" != 1 ]]; then
        echo "ENV: $name did not build or run (exit $mrc)" >&2
        sed -n '1,15p' "$TMP/$name.out" >&2 2>/dev/null; exit 2
    fi
    if grep -q "FAIL  $declared[ :]" "$TMP/$name.out"; then
        echo "  ok  $name ($desc) caught by $declared"; caught=$((caught + 1))
    else
        echo "  FAIL  $name ($desc) not caught by its declared case $declared"; missed=$((missed + 1))
    fi
}

run_mutant x1 SourceControlRowView.swift \
    '/dirtyRect\.intersection(bounds)\.fill(using: \.sourceOver)/d' \
    M1 "fill deleted"
run_mutant x2 SourceControlRowView.swift \
    's/isSessionTouched = controller\.sessionTouchedPaths\.contains(entry\.path)/if controller.sessionTouchedPaths.contains(entry.path) { isSessionTouched = true }/' \
    M3b "flag never cleared on recycle"
run_mutant x3 SpaceViewController+SessionHighlight.swift \
    '/^        sourceControlPanel\.sessionTouchedPaths = effective$/d' \
    M4 "panel never handed the set"
run_mutant x4 SourceControlRowView.swift \
    's/guard isSessionTouched, !isSelected else { return }/guard isSessionTouched else { return }/' \
    M2 "selected-row guard deleted"
run_mutant x5 SpaceViewController+SessionHighlight.swift \
    '/fileTree\.gitStatusDidChange()/d' \
    M3 "gitStatusDidChange removed from resetSessionHighlights"

echo ""
echo "falsification: $caught caught, $missed missed"
[[ $caught -eq 0 && $missed -eq 0 ]] && { echo "ENV: no mutant ran" >&2; exit 2; }
[[ $missed -gt 0 ]] && { echo "FAIL: falsification" >&2; exit 1; }
echo ""; echo "all session-marker cases passed, 5 mutants caught"
