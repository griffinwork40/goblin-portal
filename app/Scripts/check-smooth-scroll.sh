#!/bin/bash
#
# Does the smooth-scroll state machine honour the contracts its header promises?
# Compiles the SHIPPED SmoothScrollModel.swift (Foundation only) together with a
# separate harness file and runs a 10-case truth table.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/SmoothScrollModel.swift` only — the pure
# state machine that decides how many whole lines to scroll and what sub-cell pixel
# offset to carry. That file imports only Foundation, which is why a headless swiftc
# harness can compile it at all. Same trick check-paste-guard.sh plays on
# PasteGuardPolicy.swift, and check-renderer-config.sh on Renderer.swift.
#
# WHAT IT CANNOT REACH, stated rather than implied:
#   • NSEvent routing in SmoothScroll.swift and GoblinPortalTerminalView+SmoothScroll.swift
#     — those import AppKit and cannot be compiled headless.
#   • The real CALayer transform: layerTranslationY is tested arithmetically, but whether
#     a rendered frame visually moves in the correct direction requires a running Metal
#     compositor and a human or pixel-level screenshot.
#   • Native momentum feel: whether the OS-delivered momentumPhase stream feels right is
#     daily-drive territory.
#   • Grace timer wall-clock accuracy: graceExpired is called synchronously here; whether
#     the real Task.sleep(for: .milliseconds(100)) arm fires within the documented window
#     requires a live run loop.
#   • The reattach/reuse lifecycle of SmoothScroll (creation, attachment to a new pane after
#     a split) — that involves AppKit view hierarchy.
#
# TRUTH TABLE (10 cases):
#   1. Realistic flick (began → changed×8 → ended → momentum began/changed×2/ended) carries
#      scrolling past the finger-lift and finishes at offset 0.
#   2. Slow drag ending in .ended with no momentum; grace expiry settles to offset 0 with
#      path="touch".
#   3. Line conservation: total emitted lines == round(total pixels / cellHeight) under
#      the model's accumulate-then-settle rule.
#   4. Sign convention: positive deltaY → positive lines (scrollUp); layerTranslationY
#      returns -offset for an unflipped superview and +offset for a flipped one.
#   5. .began resets a stale offset: a new finger-down interrupts a partial drag and the
#      offset is zeroed before accumulation restarts.
#   6. .cancelled settles the gesture cleanly with path="cancelled" and offset 0.
#   7. Stale grace generation is ignored: a grace timer from an earlier gesture cannot
#      settle a later one (graceGeneration is bumped on every .ended).
#   8. snap(reason:) zeroes the offset without emitting lines.
#   9. shouldClaim refuses a new gesture when the pointer is outside the view, but keeps
#      a gesture already claimed even if the pointer drifts outside.
#  10. FALSIFICATION / control: a naive model that drops all momentum events and settles
#      immediately on .ended emits fewer lines than the shipped model on the same flick,
#      proving the momentum carry-forward is real and the harness can distinguish them.
#
# WHY IT EXISTS. The old CVDisplayLink implementation (PR #135 first cut) never started
# its animation loop: .ended carries a near-zero delta, seeding velocity ≈ 0, failing
# the 0.5 threshold. It also swallowed the OS momentum stream it was meant to replace,
# and passed an unretained self across a thread. Switching to the OS momentum-phase event
# stream gives native feel and refresh-rate independence with no timer thread. This gate
# is the mechanically-checkable evidence that the new path works correctly.
#
# EXIT CODES:
#   0 = all cases passed
#   1 = a REAL assertion failure (wrong lines, wrong offset, wrong path, etc.)
#   2 = environmental (no swiftc, source file missing, harness will not compile)
# A broken environment must never read as a green gate.
#
# Usage:
#   ./Scripts/check-smooth-scroll.sh

set -uo pipefail

cd "$(dirname "$0")/.."

MODEL_SRC="Sources/GoblinPortal/SmoothScrollModel.swift"
HARNESS_SRC="Scripts/check-smooth-scroll-harness.swift"

# --- Environmental checks -----------------------------------------------------------

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2
    exit 2
}
[[ -f "$MODEL_SRC" ]] || {
    echo "error: $MODEL_SRC not found — did the file move? This gate names its subject explicitly." >&2
    exit 2
}
[[ -f "$HARNESS_SRC" ]] || {
    echo "error: $HARNESS_SRC not found — harness is missing." >&2
    exit 2
}

TMP=$(mktemp -d) || { echo "error: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# --- Compile: copy shipped model + harness into a temp dir with a main.swift wrapper.
# swiftc treats a file named main.swift as the entry point when compiling multiple files;
# the harness is a plain Swift source (no @main, no top-level code) so it can be a peer.
# The harness file must NOT contain top-level expressions — all calls go through main.swift.

cp "$MODEL_SRC" "$TMP/SmoothScrollModel.swift"
cp "$HARNESS_SRC" "$TMP/SmoothScrollHarness.swift"

# main.swift: the entry point that runs the truth table defined in the harness.
cat > "$TMP/main.swift" <<'MAIN'
runAllCases()
MAIN

if ! swiftc -o "$TMP/smooth_scroll_check" \
    "$TMP/SmoothScrollModel.swift" \
    "$TMP/SmoothScrollHarness.swift" \
    "$TMP/main.swift" \
    2>"$TMP/compile.log"; then
    echo "error: the harness would not compile — the gate cannot run." >&2
    echo "  If SmoothScrollModel.swift now imports AppKit, that is the regression:" >&2
    echo "  the model must stay Foundation-only so this gate can reach it." >&2
    grep -E 'error:' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
fi

# --- Run and return the harness's exit code as the verdict -------------------------

"$TMP/smooth_scroll_check"
exit $?
