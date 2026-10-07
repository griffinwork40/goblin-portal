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

if [[ $status -eq 0 ]]; then
    say "check-pane-dim: ALL-OK"
else
    say "check-pane-dim: FAIL"
fi
exit $status
