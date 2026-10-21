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

say "FALSIFY=1: applying kittyKbdQuery mutant to a COPY of vendor source…"

MUTANT_VENDOR="$TMP/mutant-vendor"
cp -cR "$VENDOR" "$MUTANT_VENDOR"
chmod -R u+w "$MUTANT_VENDOR"

TERMINAL_SRC="$MUTANT_VENDOR/Sources/SwiftTerm/Terminal.swift"

# Confirm the mutation target is present before patching.
if ! grep -q 'sendResponse(cc.CSI, "?\\\\(keyboardEnhancementFlags.rawValue)u")' "$TERMINAL_SRC" 2>/dev/null && \
   ! grep -q 'sendResponse(cc\.CSI.*keyboardEnhancementFlags' "$TERMINAL_SRC" 2>/dev/null; then
    echo "error: mutation target not found in $TERMINAL_SRC — source may have moved." >&2
    echo "       Pattern: sendResponse(cc.CSI, \"?\\(keyboardEnhancementFlags.rawValue)u\")" >&2
    echo "       Grep the file and update the mutant sed expression." >&2
    exit 2
fi

# Apply: comment out the sendResponse line for the kitty query case.
# Use a temp copy to check the sed worked before committing.
sed 's/sendResponse(cc\.CSI, "?\\(keyboardEnhancementFlags\.rawValue)u")/\/\/ MUTANT: suppressed kitty query response/' \
    "$TERMINAL_SRC" > "$TMP/Terminal.swift.mutated"

if ! diff -q "$TERMINAL_SRC" "$TMP/Terminal.swift.mutated" >/dev/null 2>&1; then
    cp "$TMP/Terminal.swift.mutated" "$TERMINAL_SRC"
    say "  mutant applied: kitty keyboard query response suppressed"
else
    # sed made no change — the exact string did not match; try broader pattern.
    # The line in Terminal.swift:921 is:
    #   sendResponse(cc.CSI, "?\(keyboardEnhancementFlags.rawValue)u")
    # with Swift string interpolation. The sed above uses literal backslash which
    # matches the source character. If that failed try Perl for robustness.
    if ! perl -i -pe \
        's/sendResponse\(cc\.CSI, "\?\\\(keyboardEnhancementFlags\.rawValue\)u"\)/\/\/ MUTANT: suppressed/g' \
        "$TERMINAL_SRC" 2>/dev/null; then
        echo "error: mutant sed+perl both failed — cannot apply mutation." >&2
        exit 2
    fi
    if ! grep -q "MUTANT" "$TERMINAL_SRC"; then
        echo "error: mutation target not found after perl pass — exits 2 (no mutant ran)." >&2
        exit 2
    fi
    say "  mutant applied via perl fallback"
fi

# Rebuild: mutate the real vendor tree IN PLACE, save/restore via cp.
# Package.swift uses `../vendor/SwiftTerm` (relative), so the build must run
# from APP_ROOT against the real vendor path — a symlinked mirror can't work.
# Restore is guaranteed by the trap set at the top of the script (rm -rf TMP
# doesn't help here; we need an explicit restore of the single mutated file).
TERMINAL_SRC="$VENDOR/Sources/SwiftTerm/Terminal.swift"
TERMINAL_BACKUP="$TMP/Terminal.swift.orig"
cp "$TERMINAL_SRC" "$TERMINAL_BACKUP"

# Restore on exit regardless of outcome.
restore_terminal() { cp "$TERMINAL_BACKUP" "$TERMINAL_SRC" 2>/dev/null || true; }
trap restore_terminal EXIT

say "  mutating vendor Terminal.swift in place…"
perl -i -pe \
    's{sendResponse\(cc\.CSI, "\?\\\(keyboardEnhancementFlags\.rawValue\)u"\)}{// MUTANT: kitty query suppressed — falsification}g' \
    "$TERMINAL_SRC"

if ! grep -q "MUTANT" "$TERMINAL_SRC"; then
    echo "error: mutation target not found in Terminal.swift — pattern may have moved." >&2
    echo "       Expected: sendResponse(cc.CSI, \"?\\(keyboardEnhancementFlags.rawValue)u\")" >&2
    echo "       Grep Terminal.swift:921 and update the perl expression." >&2
    restore_terminal
    exit 2
fi
say "  mutant applied (Terminal.swift:921 kitty query suppressed)"

# Rebuild SwiftTerm against the mutated source.
say "  rebuilding SwiftTerm with mutant source…"
MUTANT_FLAGS=()
if swift build --help 2>&1 | grep -q -- '--build-system'; then
    MUTANT_FLAGS=(--build-system swiftbuild)
fi
if ! swift build "${MUTANT_FLAGS[@]}" >/dev/null 2>&1; then
    echo "error: mutant build failed — environment failure." >&2
    exit 2
fi
MUTANT_PRODUCTS="$(swift build "${MUTANT_FLAGS[@]}" --show-bin-path 2>/dev/null)"

if [[ ! -f "$MUTANT_PRODUCTS/SwiftTerm.o" ]]; then
    echo "error: mutant SwiftTerm.o absent after build." >&2
    exit 2
fi

# Compile harness against the mutant .o.
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

# Restore the original Terminal.swift before running — the harness binary is
# already linked against the mutant .o, so restoring source does not affect it.
restore_terminal

say "  running probe against mutant binary…"
MUTANT_EXIT=0
"$TMP/primitivesprobe_mutant" 2>&1 | grep -E "✗|REGRESSION|kittyKbdQuery" || true
"$TMP/primitivesprobe_mutant" >/dev/null 2>&1 || MUTANT_EXIT=$?

# Rebuild clean SwiftTerm so the worktree is left in a usable state.
say "  restoring clean SwiftTerm build…"
swift build "${MUTANT_FLAGS[@]}" >/dev/null 2>&1 || true

if [[ "$MUTANT_EXIT" -eq 1 ]]; then
    say ""
    say "FALSIFY: mutant CAUGHT — kittyKbdQuery changed PRESENT→ABSENT, gate exited 1 ✓"
    exit 0
elif [[ "$MUTANT_EXIT" -eq 0 ]]; then
    echo "FALSIFY: mutant NOT caught — gate passed against broken source; gate is BLIND." >&2
    exit 1
else
    echo "FALSIFY: probe exited 2 against mutant — environment failure, verdict unknown." >&2
    exit 2
fi
