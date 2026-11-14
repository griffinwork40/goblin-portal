#!/bin/bash
#
# T4.0 live primitive probe — byte-feed harness for the vendored SwiftTerm
# (upstream c3436be + the patches in patches/swiftterm/).
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
# WHY THIS IS SPLIT INTO THREE FILES
# The harness Swift source would push this script past the 350-LOC ceiling
# (AFK.md convention): check-primitives-harness.swift (delegate, truth table, main)
# and check-primitives-probes.swift (one function per row) are the subject; this
# .sh is the build+run+falsify driver.
#
# REPORT
# The markdown report is written ONLY when PRIMITIVES_REPORT names a file. A plain
# run writes nothing: until 2026-11-14 every run rewrote the tracked
# .afk/research/primitives-probe-2026-10-21.md, so running the gate dirtied the tree
# and the dated record silently became "whatever the last run saw". That file is a
# 2026-10-21 snapshot; regenerate it deliberately, if ever, with
#   PRIMITIVES_REPORT=../.afk/research/<name>.md ./Scripts/check-primitives.sh
#
# FALSIFICATION
# With FALSIFY=1: three mutants, each applied ALONE to a fresh COPY of vendor/ and
# each counted only when exactly its own row(s) flip (see the FALSIFY block):
#   (a) kitty keyboard query reply removed      → kittyKbdQuery
#   (b) the CSI > q → cmdXTVERSION dispatch     → XTVERSION + XTVERSIONbare
#       routed back to DECSCUSR
#   (c) DEC 1007 defaults OFF, decl + RIS line  → altScroll1007
# A stale pattern, or fewer than three mutants run, exits 2.
#
# Usage:
#   ./Scripts/check-primitives.sh                         # run the truth table
#   ./Scripts/check-primitives.sh --quiet                 # only failures + summary
#   PRIMITIVES_REPORT=/tmp/p.md ./Scripts/check-primitives.sh   # + write the report
#   FALSIFY=1 ./Scripts/check-primitives.sh               # run the three mutants
#
# Exit codes:
#   0  all pinned assertions passed (FALSIFY=1: all three mutants caught)
#   1  a pinned assertion FAILED (verdict changed) — or a mutant was missed (FALSIFY=1)
#   2  ENVIRONMENT failure — vendor missing, no toolchain, build failed, harness
#      would not compile; also: FALSIFY=1 with a stale pattern or a mutant not run

set -euo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"
VENDOR="$REPO_ROOT/vendor/SwiftTerm"
HARNESS="$APP_ROOT/Scripts/check-primitives-harness.swift"
RESEARCH_OUT="${PRIMITIVES_REPORT:-}"   # empty = write no report (see REPORT above)

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
        # Everything after the sentinel → the report, only when one was asked for.
        if [[ -n "$RESEARCH_OUT" ]]; then
            tail -n "+$((SENTINEL_LINE + 1))" "$FULL_OUT" > "$RESEARCH_OUT"
            say ""
            say "report written → $RESEARCH_OUT"
        fi
        tail -n 1 "$FULL_OUT"   # the summary line prints after the markdown block
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
# Three mutants, each applied ALONE to a fresh COPY of vendor/ (never the shipped tree)
# and each judged by its OWN rows: caught only when the probe exits 1 AND the set of
# flagged rows is exactly the mutant's declared set. A different row failing is
# WRONG-CASE and counts as missed (AFK.md, "Falsification must mutate a copy").
#   A  kitty query reply removed           → kittyKbdQuery
#   B  CSI > q routed back to DECSCUSR     → XTVERSION + XTVERSIONbare
#   C  DEC 1007 defaults OFF (decl + RIS)  → altScroll1007
# A pattern that no longer matches the expected count exits 2 (stale mutant, nothing
# judged); a falsify run is never green unless all three ran and were caught.

# WHY A WHOLE-TREE COPY. Package.swift resolves SwiftTerm as `../vendor/SwiftTerm`
# (relative), so building against a mutated vendor needs that relative layout.
# Cloning app/ and vendor/ SIDE BY SIDE under $TMP reproduces it, and the real tree
# is never written. An earlier version of this block mutated the real vendor's
# Terminal.swift in place behind an EXIT trap: a SIGKILL or a crash between the
# mutation and the trap left the operator's emulator silently broken, and AFK.md
# forbids exactly that. `cp -c` is an APFS clone, so the copy is cheap; .build/ and
# build/ are skipped because SwiftPM's build directory holds absolute paths. app/ is
# copied once (its .build then carries over between mutants); vendor/ is re-cloned
# per mutant so no mutant sees another's edit.
# Physical path: $TMP is under /var, a symlink to /private/var, and SwiftPM reports
# the resolved form — the containment check below compares like with like.
MROOT="$(cd "$TMP" && pwd -P)/mutant-root"
mkdir -p "$MROOT/app"
for entry in "$APP_ROOT"/* "$APP_ROOT"/.[!.]*; do
    [[ -e "$entry" ]] || continue
    case "$(basename "$entry")" in .build|build) continue ;; esac
    cp -cR "$entry" "$MROOT/app/"
done
MSRC="$MROOT/vendor/SwiftTerm/Sources/SwiftTerm"

# mutate FILE WANT PERL-SUBST — apply in place to the COPY; exit 2 unless it hit WANT times.
mutate() {
    local file="$1" want="$2" expr="$3" hits
    hits="$(perl -i -ne "\$n += ($expr); print; END { print STDERR \$n+0 }" "$file" 2>&1 >/dev/null)"
    if [[ "$hits" != "$want" ]]; then
        echo "error: mutant pattern matched $hits time(s) in the COPY of $(basename "$file") (want $want) —" >&2
        echo "       the vendored source moved; update the pattern. Stale mutant, nothing judged." >&2
        exit 2
    fi
}

# run_mutant NAME "DECLARED ROWS" — build the mutated copy, run the probe, judge.
run_mutant() {
    local name="$1" declared="$2" products mexit=0 flagged
    say "  [$name] building SwiftTerm in the copy…"
    (cd "$MROOT/app" && resolve_vendored_module && echo "$PRODUCTS" > "$TMP/mutant-products") || exit 2
    products="$(cat "$TMP/mutant-products")"
    case "$products" in
        "$MROOT"/*) ;;
        *) echo "error: mutant build resolved to $products, outside the copy — refusing." >&2; exit 2 ;;
    esac
    if ! swiftc -O -o "$TMP/probe_$name" "$TMP/main.swift" "$PROBES" \
        -I "$products" -L "$products" "$products/SwiftTerm.o" -framework AppKit \
        2>"$TMP/mutant_compile.log"; then
        echo "error: harness did not compile against mutant $name — environment failure." >&2
        sed 's/^/  /' "$TMP/mutant_compile.log" >&2
        exit 2
    fi
    "$TMP/probe_$name" >"$TMP/mutant_$name.out" 2>&1 || mexit=$?
    flagged="$(grep '^✗ ' "$TMP/mutant_$name.out" | awk '{print $2}' | sort | tr '\n' ' ' | sed 's/ $//')"
    local want; want="$(echo "$declared" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$mexit" -ne 0 && "$mexit" -ne 1 ]]; then
        echo "FALSIFY [$name]: probe exited $mexit — environment failure, verdict unknown." >&2
        exit 2
    fi
    if [[ "$mexit" -eq 1 && "$flagged" == "$want" ]]; then
        say "  [$name] CAUGHT by its own row(s): $flagged ✓"
        CAUGHT=$((CAUGHT + 1))
    elif [[ "$mexit" -eq 1 ]]; then
        echo "FALSIFY [$name]: WRONG-CASE — flagged [$flagged], declared [$want]; counted as missed." >&2
    else
        echo "FALSIFY [$name]: NOT caught — probe passed against broken source; gate is BLIND." >&2
    fi
    RAN=$((RAN + 1))
}

fresh_vendor() {
    rm -rf "$MROOT/vendor"
    cp -cR "$REPO_ROOT/vendor" "$MROOT/vendor"
    chmod -R u+w "$MROOT/vendor"
}

RAN=0; CAUGHT=0
say "FALSIFY=1: three mutants, each alone on a fresh COPY of vendor/…"

fresh_vendor
mutate "$MSRC/Terminal.swift" 1 \
    's{sendResponse\(cc\.CSI, "\?\\\(keyboardEnhancementFlags\.rawValue\)u"\)}{// MUTANT-A: kitty query suppressed}'
run_mutant A "kittyKbdQuery"

# B: the one dispatch site for XTVERSION (EscapeSequenceParser.swift:650). Routing it to
# DECSCUSR is what the parser did before upstream added cmdXTVERSION, so the mutant is
# the realistic regression (a re-vendor or merge dropping the branch), not a contrived one.
fresh_vendor
mutate "$MSRC/EscapeSequenceParser.swift" 1 \
    's{terminal\.cmdXTVERSION\(pars, collect\)}{terminal.cmdSetCursorStyle(pars, collect) // MUTANT-B}'
run_mutant B "XTVERSION XTVERSIONbare"

# C: 1007 is UPSTREAM at c3436be (`alternateScrollMode`, Terminal.swift:706, reset at
# :1376); patch 0011's port notes say so. BOTH the declaration and the RIS line must flip:
# Terminal's init runs the reset, so flipping the declaration alone changes nothing. The
# reset line is anchored at 8-space indent so the DECSET case (:6809, 16 spaces) is untouched.
fresh_vendor
mutate "$MSRC/Terminal.swift" 2 \
    's{public private\(set\) var alternateScrollMode: Bool = true}{public private(set) var alternateScrollMode: Bool = false // MUTANT-C} + s{^        alternateScrollMode = true$}{        alternateScrollMode = false // MUTANT-C}'
run_mutant C "altScroll1007"

if [[ "$RAN" -ne 3 ]]; then
    echo "FALSIFY: only $RAN of 3 mutants ran — vacuous, environment failure." >&2
    exit 2
fi
if [[ "$CAUGHT" -eq 3 ]]; then
    say ""
    say "FALSIFY: all three mutants CAUGHT, each by its own row(s) ✓"
    exit 0
fi
echo "FALSIFY: $CAUGHT of 3 mutants caught by their own rows — gate is partly BLIND." >&2
exit 1
