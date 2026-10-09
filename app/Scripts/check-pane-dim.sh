#!/bin/bash
#
# check-pane-dim.sh
# Assert that the unfocused-pane opacity computed by PaneDimming.effectiveOpacity keeps
# body text readable — and that the old flat-0.7 rule FAILS for classic-repaired.
#
# WHAT IS UNDER TEST
#
# `Sources/GoblinPortal/PaneDimming.swift` (the new pure function), compiled alongside
# `Sources/GoblinPortal/ThemeValues.swift`, `ThemeValues+CommunityPresets.swift`, and
# `Sources/GoblinPortal/ThemeContrast.swift`. All four are Foundation-only by design;
# their headers say so, and the UI-import check below enforces it. Same pattern as
# `check-theme-contrast.sh`.
#
# This gate also asserts the FLOOR SYNC GUARD: `SyntaxPalette.readableFloor` and
# `PaneDimming.dimFloor` are the same Lc 45 threshold compiled by different gates and
# cannot share a definition. The doc comment on `readableFloor` requires they stay equal;
# this script enforces it by extracting both literals and comparing them at run time.
#
# WHY IT EXISTS
#
# A UX audit confirmed that at the flat 0.7 default, the app's own default palette
# (classic-repaired, fg #8A8A8A on #000000) produces dimmed body text at APCA Lc 20.8
# — far below the Lc 45 floor the app already enforces for syntax comments and inactive
# tab-strip labels. The decision logic lives in PaneDimming.effectiveOpacity, which is
# pure/Foundation-only so it can be compiled standalone and asserted mechanically here.
# Without this gate, a future refactor could silently reintroduce the flat 0.7.
#
# WHAT IT CANNOT REACH
#
# The AppKit wiring: whether SpaceViewController+SplitPresentation.swift calls
# PaneDimming.effectiveOpacity, whether Config+Load.swift passes it to the right field,
# and whether the correct opacity reaches setFocusedChild. Those are daily-drive territory.
# This gate holds the POLICY (the function) to a number; integration holds the wiring.
#
# FALSIFICATION
#
# The gate requires that the OLD flat-0.7 rule fails for classic-repaired. If that case
# PASSES, the threshold is too loose and the other cases mean nothing.
#
# The floor-sync guard also includes a falsification: a temp copy of SyntaxPalette.swift
# has its `readableFloor` literal replaced with 99, and the guard must detect the mismatch.
# If the mutated copy reads back as equal to `dimFloor`, the grep extraction is blind and
# the whole floor-sync assertion is worthless — the gate exits 1 in that case. If the sed
# mutation itself did not apply (BSD sed portability issue), the gate exits 2 (environmental).
#
# Exit codes:
#   0  all assertions pass and the falsification case fails as expected
#   1  a real failure — a floor was violated, or the falsification case passed (too loose)
#   2  environmental — no swiftc, a source file missing, harness would not compile;
#      never conflated with 1
#
# Usage:
#   cd app && ./Scripts/check-pane-dim.sh
#   cd app && ./Scripts/check-pane-dim.sh --quiet

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."

VALUES="Sources/GoblinPortal/ThemeValues.swift"
COMMUNITY="Sources/GoblinPortal/ThemeValues+CommunityPresets.swift"
CONTRAST="Sources/GoblinPortal/ThemeContrast.swift"
DIMMING="Sources/GoblinPortal/PaneDimming.swift"
HARNESS="Scripts/check-pane-dim-harness.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2
    exit 2
}

for f in "$VALUES" "$COMMUNITY" "$CONTRAST" "$DIMMING" "$HARNESS"; do
    [[ -f "$f" ]] || { echo "error: $f not found (run from the app/ directory)." >&2; exit 2; }
done

# A pure file that has quietly acquired a UI import is a regression in the split that makes
# this gate possible — name it as such rather than leaving it as a compile error later.
for f in "$VALUES" "$COMMUNITY" "$CONTRAST" "$DIMMING"; do
    if grep -qE '^\s*import\s+(AppKit|SwiftUI|Cocoa|SwiftTerm)' "$f"; then
        echo "error: $f imports a UI framework — it is supposed to be Foundation-only." >&2
        echo "  That split is the only reason this gate can compile it standalone. Fix the" >&2
        echo "  import, not this script." >&2
        exit 2
    fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/pure"
cp "$HARNESS" "$TMP/pure/main.swift"

if ! swiftc -O -o "$TMP/panedimcheck" \
     "$VALUES" "$COMMUNITY" "$CONTRAST" "$DIMMING" "$TMP/pure/main.swift" \
     2>"$TMP/compile.log"; then
    echo "error: the pure sources would not compile standalone — the gate cannot run." >&2
    sed 's/^/    /' "$TMP/compile.log" >&2
    exit 2
fi

# The harness's EXIT CODE is the verdict. It also prints ALL-OK, but trusting only the
# string would let a crash after the verdict read as a pass — same discipline as all
# check-*.sh scripts. Any status other than 0 or 1 is environmental.
out="$("$TMP/panedimcheck" 2>&1)"; status=$?

if [[ $status -ne 0 && $status -ne 1 ]]; then
    echo "error: harness exited with unexpected status $status (expected 0 or 1)." >&2
    echo "$out" >&2
    exit 2
fi

if [[ "$QUIET" == "0" ]]; then
    echo "$out"
elif [[ $status -ne 0 ]]; then
    echo "$out" | grep -E '^(FAIL|  -)'
fi

# CONSUMER GUARD. The harness measures PaneDimming; it cannot link the AppKit code that
# must CALL it. Both call sites are asserted structurally, comments stripped first so a
# comment naming the function cannot satisfy the grep (the blind spot check-theme-
# contrast.sh's preset grep had): load computes the value, and a light/dark flip of an
# "auto" theme must recompute it for the new palette (review of ce34a6a2 found it did not).
SRC="Sources/GoblinPortal"
for consumer in "$SRC/Config+Load.swift" "$SRC/AppearanceObserver.swift"; do
    if ! sed 's://.*$::' "$consumer" | grep -q 'PaneDimming\.effectiveOpacity('; then
        echo "FAIL consumer guard: $consumer no longer calls PaneDimming.effectiveOpacity(" >&2
        status=1
    fi
done

# FLOOR SYNC GUARD. SyntaxPalette.readableFloor and PaneDimming.dimFloor are the same
# Lc 45 threshold, but compiled by different gates, so they cannot share a definition.
# The doc comment on readableFloor says they must stay equal; this grep enforces it.
# Comments are stripped first (sed 's://.*$::') so a comment naming either value cannot
# satisfy the match — the blind spot check-theme-contrast.sh's preset grep once had.
SYNTAX="$SRC/SyntaxPalette.swift"
DIMMING_SRC="$SRC/PaneDimming.swift"

extract_floor_literal() {
    local file="$1" varname="$2"
    # Strip // comments, find the let declaration, take only the value after =,
    # then normalise to an integer (drop trailing .0) for comparison.
    sed 's://.*$::' "$file" \
        | grep -E "let ${varname}[^=]*=" \
        | sed -E 's/.*=[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/' \
        | head -1 \
        | sed 's/\.[0]*$//'   # 45.0 -> 45, 45 -> 45, 45.5 -> 45.5
}

readable_val="$(extract_floor_literal "$SYNTAX" "readableFloor")"
dim_val="$(extract_floor_literal "$DIMMING_SRC" "dimFloor")"

if [[ -z "$readable_val" ]]; then
    echo "FAIL floor-sync: could not find 'let readableFloor' literal in $SYNTAX" >&2
    status=1
elif [[ -z "$dim_val" ]]; then
    echo "FAIL floor-sync: could not find 'let dimFloor' literal in $DIMMING_SRC" >&2
    status=1
elif [[ "$readable_val" != "$dim_val" ]]; then
    echo "FAIL floor-sync: SyntaxPalette.readableFloor=$readable_val != PaneDimming.dimFloor=$dim_val" >&2
    echo "  Both constants must be equal — edit one to match the other." >&2
    status=1
else
    say "  floor-sync: readableFloor == dimFloor == $readable_val  ok"
fi

# FLOOR SYNC FALSIFICATION. Mutate a temp copy of SyntaxPalette.swift so its
# readableFloor literal differs (45 -> 99), then re-run the grep logic. The
# mutated copy MUST be detected as a mismatch. If the mutated copy reads back
# as equal to dim_val, the grep above is blind and we must fail the gate.
# BSD sed: use [[:space:]]* not \s (macOS /usr/bin/sed is POSIX, not GNU).
# The sed replaces the integer part of the literal with 99, e.g. 45 -> 99 or
# 45.0 -> 99.0 — either way the normalised value becomes 99, not equal to dim_val.
TMP_SYNTAX="$TMP/SyntaxPalette_mutated.swift"
sed 's/\(let readableFloor[^=]*=[[:space:]]*\)[0-9][0-9]*/\199/' "$SYNTAX" > "$TMP_SYNTAX"

# Sanity-check: if the mutation didn't apply (sed produced no change), the harness
# itself is broken — exit 2 (environmental), not 1 (logic failure).
mutated_val="$(extract_floor_literal "$TMP_SYNTAX" "readableFloor")"
if [[ "$mutated_val" == "$readable_val" ]]; then
    echo "error: floor-sync falsification: sed mutation did not apply — harness bug." >&2
    echo "  Expected readableFloor != $readable_val in $TMP_SYNTAX, but got $mutated_val." >&2
    exit 2
fi

# Now check that our floor-sync logic DETECTS the mismatch.
# "Detected" means the mutated value differs from dim_val (i.e. the guard would fire).
if [[ -z "$mutated_val" || "$mutated_val" == "$dim_val" ]]; then
    echo "FAIL floor-sync falsification: mutated copy (readableFloor=$mutated_val) was not detected as a mismatch — the grep is blind" >&2
    status=1
else
    say "  floor-sync falsification: mutation detected as expected (readableFloor=$mutated_val != dimFloor=$dim_val)  ok"
fi

if [[ $status -eq 0 ]]; then
    say "check-pane-dim: ALL-OK"
else
    say "check-pane-dim: FAIL"
fi
exit $status
