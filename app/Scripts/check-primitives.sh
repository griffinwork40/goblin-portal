#!/bin/bash
#
# T4.0 live primitive probe — byte-feed harness for SwiftTerm v1.15.0 + 16 patches.
#
# Replaces A1b static-analysis hypotheses with measured runtime behaviour. Each
# row feeds escape sequences to a headless Terminal, captures the bytes SwiftTerm
# sends back, and records PRESENT / ABSENT / PARTIAL. The pinned truth table (in
# check-primitives-harness.swift) is the regression gate: a row that changes
# verdict exits 1.
#
# Metal/CoreText pixel draw is DEFERRED — probing image rendering requires an
# offscreen NSWindow + GPU context (same constraint as check-metal-throughput.sh).
# The parser hooks for sixel, kitty graphics, and OSC 1337 ARE probed headlessly.
#
# WHY THIS IS SPLIT INTO TWO FILES
# The harness Swift source would push this script past the 350-LOC ceiling
# (AFK.md convention). This follows the same split as check-git-status-harness.swift
# and check-metal-throughput-harness.swift. The .swift file is the subject;
# this .sh is the build+run+falsify driver.
#
# FALSIFICATION
# With FALSIFY=1: copies vendor/ to a temp dir, breaks the kitty keyboard query
# handler (makes it send nothing), rebuilds against the mutant, and requires that
# the kittyKbdQuery row exits 1. A run where no mutant executed exits 2 so a
# zero-mutant falsification pass cannot silently report success. Mutant is applied
# to a COPY of shipped source, never in-place (AFK.md convention).
#
# Usage:
#   ./Scripts/check-primitives.sh            # run the truth table
#   ./Scripts/check-primitives.sh --quiet    # only failures + summary
#   FALSIFY=1 ./Scripts/check-primitives.sh  # run the falsification mutant
#
# Exit codes:
#   0  all pinned assertions passed
#   1  a pinned assertion FAILED (verdict changed) — or mutant was NOT caught (FALSIFY=1)
#   2  ENVIRONMENT failure — vendor missing, no toolchain, build failed, harness
#      would not compile; also: FALSIFY=1 but no mutant ran

set -euo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"
VENDOR="$REPO_ROOT/vendor/SwiftTerm"
HARNESS="$APP_ROOT/Scripts/check-primitives-harness.swift"
RESEARCH_OUT="$REPO_ROOT/.afk/research/primitives-probe-2026-10-21.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── environment gates, all exit 2 ────────────────────────────────────────────

if [[ ! -d "$VENDOR" ]]; then
    echo "error: vendor/SwiftTerm missing — run verify-vendor.sh first." >&2
    exit 2
fi

if [[ ! -f "$HARNESS" ]]; then
    echo "error: $HARNESS missing — cannot run gate." >&2
    exit 2
fi

if ! command -v swiftc >/dev/null 2>&1; then
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2
    exit 2
fi

# ── build SwiftTerm (vendored module) ────────────────────────────────────────
# Uses the same vendored-module.sh helper as check-reflow.sh and
# check-altbuffer-resize.sh: always rebuilds (never skips on a warm .build),
# selects the Swift Build backend so we get a merged SwiftTerm.o, exits 2 on
# any environment failure. See vendored-module.sh for the full rationale.

. Scripts/vendored-module.sh
resolve_vendored_module          # sets PRODUCTS, or exits 2

# ── compile the probe harness ────────────────────────────────────────────────

PROBES="$APP_ROOT/Scripts/check-primitives-probes.swift"
if [[ ! -f "$PROBES" ]]; then
    echo "error: $PROBES missing — cannot run gate." >&2
    exit 2
fi

say "compiling probe harness…"
# In multi-file swiftc, top-level executable code is only allowed in main.swift.
# Copy the harness (which contains runProbe() and the top-level call) to main.swift
# so swiftc treats it as the entry point; the probes file compiles as a regular module.
cp "$HARNESS" "$TMP/main.swift"
if ! swiftc -O \
    -o "$TMP/primitivesprobe" \
    "$TMP/main.swift" "$PROBES" \
    -I "$PRODUCTS" -L "$PRODUCTS" "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit \
    2>"$TMP/compile.log"; then
    echo "error: harness did not compile — environment failure, not an assertion failure." >&2
    sed 's/^/  /' "$TMP/compile.log" >&2
    exit 2
fi

# ── run the probe (normal path) ───────────────────────────────────────────────

if [[ "${FALSIFY:-0}" != "1" ]]; then
    say ""
    say "running primitive probe…"
    say ""

    # Capture all output; split at === MARKDOWN === sentinel.
    FULL_OUT="$TMP/full.txt"
    PROBE_EXIT=0
    "$TMP/primitivesprobe" > "$FULL_OUT" 2>&1 || PROBE_EXIT=$?

    # Everything before the sentinel goes to stdout.
    SENTINEL_LINE=$(grep -n "^=== MARKDOWN ===$" "$FULL_OUT" | head -1 | cut -d: -f1)
    if [[ -n "$SENTINEL_LINE" ]]; then
        head -n "$((SENTINEL_LINE - 1))" "$FULL_OUT"
        # Everything after the sentinel → research doc.
        tail -n "+$((SENTINEL_LINE + 1))" "$FULL_OUT" > "$RESEARCH_OUT"
        say ""
        say "research doc written → $RESEARCH_OUT"
    else
        cat "$FULL_OUT"
    fi

    if [[ "$PROBE_EXIT" -eq 2 ]]; then
        echo "error: probe exited 2 — environment failure inside the harness." >&2
        exit 2
    fi
    exit "$PROBE_EXIT"
fi

# ── FALSIFY=1 path ────────────────────────────────────────────────────────────
# Mutant: make the kitty keyboard query handler send nothing, so kittyKbdQuery
# changes from PRESENT → ABSENT and the pinned assertion fails (exit 1).
#
# Applied to a COPY of the vendored source — never the shipped tree.
# The mutation target is Terminal.swift's handleKittyKeyboardProtocol, which
# sends the CSI?<flags>u response (Terminal.swift ~line 921).
# We replace `sendResponse(cc.CSI, "?\(keyboardEnhancementFlags.rawValue)u")`
# with a comment so the query returns nothing.
#
# A run where no mutation was found/applied exits 2 (not 0) so a vacuous
# falsification cannot silently report success.

say "FALSIFY=1: applying kittyKbdQuery mutant to a COPY of app/ + vendor/…"

# WHY A WHOLE-TREE COPY. Package.swift resolves SwiftTerm as `../vendor/SwiftTerm`
# (relative), so building against a mutated vendor needs that relative layout.
# Cloning app/ and vendor/ SIDE BY SIDE under $TMP reproduces it, and the real tree
# is never written. An earlier version of this block mutated the real vendor's
# Terminal.swift in place behind an EXIT trap: a SIGKILL or a crash between the
# mutation and the trap left the operator's emulator silently broken, and AFK.md
# ("Falsification must mutate a copy of SHIPPED source") forbids exactly that.
# `cp -c` is an APFS clone, so the copy is cheap; .build/ and build/ are skipped
# because SwiftPM's build directory holds absolute paths and is rebuilt anyway.
# Physical path: $TMP is under /var, a symlink to /private/var, and SwiftPM reports
# the resolved form — the containment check below compares like with like.
MROOT="$(cd "$TMP" && pwd -P)/mutant-root"
mkdir -p "$MROOT/app"
for entry in "$APP_ROOT"/* "$APP_ROOT"/.[!.]*; do
    [[ -e "$entry" ]] || continue
    case "$(basename "$entry")" in .build|build) continue ;; esac
    cp -cR "$entry" "$MROOT/app/"
done
cp -cR "$REPO_ROOT/vendor" "$MROOT/vendor"
chmod -R u+w "$MROOT/vendor"
MUTANT_SRC="$MROOT/vendor/SwiftTerm/Sources/SwiftTerm/Terminal.swift"

# Exactly one substitution, or the mutant is stale and the run is environmental.
HITS="$(perl -i -ne '
    $n += s{sendResponse\(cc\.CSI, "\?\\\(keyboardEnhancementFlags\.rawValue\)u"\)}{// MUTANT: kitty query suppressed};
    print; END { print STDERR $n+0 }' "$MUTANT_SRC" 2>&1 >/dev/null)"
if [[ "$HITS" != "1" ]]; then
    echo "error: kitty-query mutant matched $HITS time(s) in the COPY of Terminal.swift (want 1) —" >&2
    echo "       the source moved; update the pattern. No mutant ran." >&2
    exit 2
fi
say "  mutant applied to the copy (kitty query response suppressed)"

say "  building SwiftTerm in the copy…"
# Same helper, same backend selection and exit-2 contract as the normal path, run
# from the copied app/ so `../vendor` is the mutated vendor.
(cd "$MROOT/app" && resolve_vendored_module && echo "$PRODUCTS" > "$TMP/mutant-products") || exit 2
MUTANT_PRODUCTS="$(cat "$TMP/mutant-products")"
case "$MUTANT_PRODUCTS" in
    "$MROOT"/*) ;;
    *) echo "error: mutant build resolved to $MUTANT_PRODUCTS, outside the copy — refusing." >&2; exit 2 ;;
esac

say "  compiling harness against mutant…"
if ! swiftc -O \
    -o "$TMP/primitivesprobe_mutant" \
    "$TMP/main.swift" "$PROBES" \
    -I "$MUTANT_PRODUCTS" -L "$MUTANT_PRODUCTS" "$MUTANT_PRODUCTS/SwiftTerm.o" \
    -framework AppKit \
    2>"$TMP/mutant_compile.log"; then
    echo "error: harness did not compile against mutant — environment failure." >&2
    sed 's/^/  /' "$TMP/mutant_compile.log" >&2
    exit 2
fi

say "  running probe against mutant binary…"
MUTANT_EXIT=0
"$TMP/primitivesprobe_mutant" >"$TMP/mutant.out" 2>&1 || MUTANT_EXIT=$?
grep -E "✗|REGRESSION|kittyKbdQuery" "$TMP/mutant.out" || true

# Caught only when kittyKbdQuery itself is the case that flipped.
if [[ "$MUTANT_EXIT" -eq 1 ]] && grep -E "kittyKbdQuery" "$TMP/mutant.out" | grep -qE "✗|REGRESSION"; then
    say ""
    say "FALSIFY: mutant CAUGHT — kittyKbdQuery changed PRESENT→ABSENT, gate exited 1 ✓"
    exit 0
elif [[ "$MUTANT_EXIT" -eq 1 ]]; then
    echo "FALSIFY: gate exited 1 but NOT on kittyKbdQuery — WRONG-CASE, counted as missed." >&2
    exit 1
elif [[ "$MUTANT_EXIT" -eq 0 ]]; then
    echo "FALSIFY: mutant NOT caught — gate passed against broken source; gate is BLIND." >&2
    exit 1
else
    echo "FALSIFY: probe exited $MUTANT_EXIT against mutant — environment failure, verdict unknown." >&2
    exit 2
fi
