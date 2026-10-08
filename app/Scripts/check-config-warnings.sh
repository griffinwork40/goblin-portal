#!/bin/bash
#
# check-config-warnings.sh — gates the config-warnings banner policy (#166, T1.5).
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/ConfigWarningPolicy.swift` — the pure half of
# the banner that tells Finder/Dock users their config.json was partly or wholly ignored:
# show vs hide, de-duplication, the title and its count, the 3-line budget with "and N
# more", and `~` abbreviation of the home directory. Foundation-only BY DESIGN so it
# compiles headless with `swiftc`; the SHIPPED file is compiled, not a restatement of it
# (the same trick check-paste-guard.sh and check-file-ops.sh play). Assertions live in
# `check-config-warnings-harness.swift` (11 cases).
#
# WIRING (structural, comments stripped before grepping — a grep for vocabulary is blind,
# AFK.md records how check-theme-contrast.sh learned that):
#   W1  Config+Load.swift builds its invalid-JSON warning through
#       `ConfigWarningPolicy.invalidJSONWarning`, so the whole-file title can fire.
#   W2  AppDelegate.swift calls `ConfigWarningPresenter.shared.report(` exactly twice:
#       launch and `reloadConfig(_:)`.
#   W3  PreferencesWindow.swift's Apply still routes through `reloadConfig(`, so Settings
#       Apply reaches the presenter via W2 rather than needing a third call site.
#
# FALSIFICATION — REAL MUTATIONS. Two sed-mutated copies of the shipped policy must each
# make the SAME harness exit 1: (a) the de-dup rule disabled (DEDUP-RULE), (b) the home
# abbreviation's path-boundary check removed (HOME-BOUNDARY-RULE). If a mutant passes the
# gate is blind to that rule (exit 1); if sed changed nothing the falsification itself is
# blind (exit 2).
#
# WHAT IT CANNOT REACH, stated rather than implied: whether the AppKit banner
# (ConfigWarningBanner.swift) renders legibly under every theme, whether the ✕ and "Open
# config.json" buttons fire, whether the `.bottom` titlebar accessory pushes the terminal
# down rather than covering it, and whether the presenter reaches windows opened later.
# Those import AppKit and need a window server — daily-drive and `GOBLIN_PORTAL_DIAG=1`
# territory (the presenter prints one `[diag] config-banner:` line per decision).
#
# EXIT CODES: 0 = all cases passed and both mutants were caught. 1 = real failure.
# 2 = environmental (no toolchain, missing file, compile failure, crash, blind sed).
#
# Usage:  ./Scripts/check-config-warnings.sh [--quiet]

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/ConfigWarningPolicy.swift"
HARNESS="Scripts/check-config-warnings-harness.swift"
LOADER="Sources/GoblinPortal/Config+Load.swift"
DELEGATE="Sources/GoblinPortal/AppDelegate.swift"
PREFS="Sources/GoblinPortal/PreferencesWindow.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }
for f in "$SRC" "$HARNESS" "$LOADER" "$DELEGATE" "$PREFS"; do
    [[ -f "$f" ]] || { echo "error: $f not found — did the file move?" >&2; exit 2; }
done

TMP=$(mktemp -d) || { echo "error: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
cp "$HARNESS" "$TMP/main.swift"   # top-level code must be main.swift

build() {
    if ! swiftc -o "$2" "$1" "$TMP/main.swift" 2>"$TMP/compile.err"; then
        echo "error: harness failed to compile against $1" >&2
        echo "  If this names AppKit, ConfigWarningPolicy.swift stopped being Foundation-only" >&2
        echo "  and THAT is the regression." >&2
        grep -E 'error' "$TMP/compile.err" | head -10 | sed 's/^/    /' >&2
        exit 2
    fi
}
run() {
    local out
    out=$("$1" 2>&1); RUN_STATUS=$?
    [[ "$QUIET" == "1" && $RUN_STATUS -eq 0 ]] || echo "$out"
}

# ── Wiring: structural greps on comment-stripped source ──────────────────────
strip() { sed -E 's://.*$::' "$1"; }
wbad=0
if strip "$LOADER" | grep -q 'ConfigWarningPolicy\.invalidJSONWarning('; then
    say "  ok  W1 Config+Load.swift builds the invalid-JSON warning via the policy"
else
    echo "  FAIL W1 Config+Load.swift no longer calls ConfigWarningPolicy.invalidJSONWarning —" \
         "the whole-file title would never fire"; wbad=1
fi
n=$(strip "$DELEGATE" | grep -c 'ConfigWarningPresenter\.shared\.report(')
if [[ "$n" -eq 2 ]]; then
    say "  ok  W2 AppDelegate.swift reports warnings at launch and on reload (2 call sites)"
else
    echo "  FAIL W2 AppDelegate.swift has $n ConfigWarningPresenter.shared.report( call(s), expected 2"; wbad=1
fi
if strip "$PREFS" | grep -q 'reloadConfig('; then
    say "  ok  W3 Settings Apply routes through reloadConfig (reaches the presenter via W2)"
else
    echo "  FAIL W3 PreferencesWindow.swift no longer calls reloadConfig — Apply would skip the banner"; wbad=1
fi

# ── Real run ─────────────────────────────────────────────────────────────────
build "$SRC" "$TMP/harness"
say "==> running check-config-warnings (11 cases) against the shipped policy"
run "$TMP/harness"
if [[ $RUN_STATUS -gt 1 ]]; then
    echo "error: harness crashed (status $RUN_STATUS) — environmental, not a verdict" >&2; exit 2
fi
[[ $RUN_STATUS -eq 0 && $wbad -eq 0 ]] || exit 1

# ── Falsification: each sed-mutated copy of the shipped policy must FAIL ──────
# mutate <tag> <sed-expr> <description>
mutate() {
    local dir="$TMP/mutant-$1" mut
    mkdir -p "$dir"; mut="$dir/ConfigWarningPolicy.swift"
    sed "$2" "$SRC" > "$mut"
    if cmp -s "$SRC" "$mut"; then
        echo "error: falsification is BLIND — sed changed nothing ($1 line moved?)" >&2; exit 2
    fi
    build "$mut" "$dir/harness"
    say "==> falsification: $3"
    "$dir/harness" >"$dir/out.log" 2>&1; RUN_STATUS=$?   # a mutant's FAIL lines are expected noise
    case $RUN_STATUS in
        1) say "falsification: mutant rejected, as required" ;;
        0) echo "FAIL: the $1 mutant PASSED — this gate cannot see that rule" >&2; exit 1 ;;
        *) echo "error: $1 mutant harness crashed (status $RUN_STATUS)" >&2; exit 2 ;;
    esac
}
mutate dedup 's|seen.insert(w).inserted else { continue }  // DEDUP-RULE|true else { continue }  // DEDUP-RULE|' \
    "policy with de-duplication disabled"
mutate boundary 's|if after.isEmpty \|\| after.hasPrefix("/") {  // HOME-BOUNDARY-RULE|if true {  // HOME-BOUNDARY-RULE|' \
    "policy that abbreviates home without a path-component boundary"

say "check-config-warnings: exit 0 — 11 cases + 3 wiring checks passed, both mutants caught"
exit 0
