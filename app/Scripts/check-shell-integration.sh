#!/bin/bash
#
# Does the OSC 133 parser correctly implement the A/C/D state machine, and does
# Osc7Directory correctly identify remote vs local OSC 7 hosts?
#
# WHAT IS UNDER TEST:
#   Sources/GoblinPortal/ShellIntegration.swift — OSC 133 parser + parseOsc7Directory wrapper
#   Sources/GoblinPortal/Osc7Directory.swift    — parse(_:localHostnames:) + currentLocalHostnames()
#   Scripts/check-shell-integration-harness.swift — all assertion cases
#
# Both Swift files are Foundation-only BY DESIGN: a pure-policy file compiles headless
# with swiftc. Same trick check-command-outcome.sh, check-cwd-follow.sh, and
# check-renderer-config.sh each use.
#
# WHY THIS HAS A HARNESS FILE. Adding Osc7Directory.swift and its host-check cases
# would push the inline Swift block past the 350-LOC ceiling. Same split-at-seam
# pattern as check-git-status-harness.swift and check-theme-contrast-registry.swift.
#
# WHY THE HOST CHECK MATTERS. OSC 7 carries file://<host>/<path>. The old parser
# discarded the host, so a remote shell reporting /tmp would re-root the local
# sidebar at /tmp. The host is the only signal that says which filesystem the path
# belongs to; a remote report must give .remote(host:), and the wrapper returns nil.
#
# FALSIFY MODE (--falsify). Copies the two Swift source files to isolated temp dirs,
# applies three named mutations (one per copy), compiles each, runs each against the
# harness, and asserts every mutant exits 1. Exits 0 only when ALL mutants fail; a mutant
# that does not compile, or whose pattern no longer applies, makes falsify exit 2.
# Mutation names: drop-host-check, double-decode, case-sensitive-compare.
#
# EXIT CODES: 0 = all cases pass. 1 = real failure. 2 = environmental (no toolchain,
# source missing, harness compile failure).
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC_SI="Sources/GoblinPortal/ShellIntegration.swift"
SRC_O7="Sources/GoblinPortal/Osc7Directory.swift"
HARNESS="Scripts/check-shell-integration-harness.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }
for f in "$SRC_SI" "$SRC_O7" "$HARNESS"; do
    [[ -f "$f" ]] || {
        echo "error: $f not found — did the file move?" >&2; exit 2; }
done

# ── helper: compile_and_run <dir> ────────────────────────────────────────────
# Compiles ShellIntegration.swift + Osc7Directory.swift + harness (as main.swift)
# from the given dir. Exits 2 on compile failure, returns runner exit code otherwise.
compile_and_run() {
    local dir="$1"
    local log="$dir/compile.log"
    if ! swiftc -o "$dir/si_check" \
        "$dir/ShellIntegration.swift" \
        "$dir/Osc7Directory.swift" \
        "$dir/main.swift" 2>"$log"; then
        echo "error: harness compile failed — the gate cannot run." >&2
        echo "  If this names AppKit or SwiftTerm, a source file has stopped being" >&2
        echo "  Foundation-only and THAT is the regression." >&2
        grep -E 'error:' "$log" | head -10 | sed 's/^/    /' >&2
        return 2
    fi
    "$dir/si_check" 2>&1
    return $?
}

# ── normal run ────────────────────────────────────────────────────────────────
if [[ "${1:-}" != "--falsify" ]]; then
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    cp "$SRC_SI" "$TMP/ShellIntegration.swift"
    cp "$SRC_O7" "$TMP/Osc7Directory.swift"
    cp "$HARNESS" "$TMP/main.swift"
    out="$(compile_and_run "$TMP")"; status=$?
    say "$out"
    exit $status
fi

# ── --falsify mode ────────────────────────────────────────────────────────────
# Three mutants, each in its own isolated temp dir. Every mutant MUST exit 1 (a
# real assertion failure) — if any exits 0, the gate is not catching what it
# should and falsify itself exits 1.
#
# Mutant 1: drop-host-check — remove the localHostnames comparison so every
#   file:// URL is treated as local regardless of host. The O5/osc7-remote-host
#   cases must catch this.
# Mutant 2: double-decode — apply removingPercentEncoding a second time after
#   URL.path, which URL.path already decoded once. The O10-%2520 case must catch
#   this (it expects /%20dir; double-decode gives /  dir with a space).
# Mutant 3: case-sensitive-compare — compare URL host to localHostnames without
#   lowercasing, so "MyMac" does not match "mymac". O2 must catch this.

echo "==> falsify: running 3 mutants"
FTMP="$(mktemp -d)"; trap 'rm -rf "$FTMP"' EXIT
all_caught=1
env_bad=0

run_mutant() {
    local mname="$1"
    local mdir="$FTMP/$mname"
    mkdir -p "$mdir"
    cp "$SRC_SI" "$mdir/ShellIntegration.swift"
    cp "$SRC_O7" "$mdir/Osc7Directory.swift"
    cp "$HARNESS" "$mdir/main.swift"
    # Apply mutation to Osc7Directory.swift (where parse logic lives)
    if [[ "$mname" == "drop-host-check" ]]; then
        # Replace the localHostnames.contains check with a hardcoded true so every
        # file:// URL is accepted as local — the host check is completely absent.
        sed -i '' 's/localHostnames.contains(urlHost)/true/' "$mdir/Osc7Directory.swift"
    elif [[ "$mname" == "double-decode" ]]; then
        # After URL.path (which already decodes once), add a second decode pass.
        # The O10-%2520 case expects /%20dir; double-decode gives / dir (a space).
        sed -i '' 's/let decoded = url\.path/let _raw = url.path; let decoded = _raw.removingPercentEncoding ?? _raw/' "$mdir/Osc7Directory.swift"
    elif [[ "$mname" == "case-sensitive-compare" ]]; then
        # Remove .lowercased() so comparison is case-sensitive; O2 (MyMac vs mymac) catches it.
        sed -i '' 's/urlHost = (url\.host ?? "")\.lowercased()/urlHost = (url.host ?? "")/' "$mdir/Osc7Directory.swift"
    fi

    local mlog="$mdir/compile.log"
    # A mutant that does not compile was never RUN, so it says nothing about the gate:
    # environmental (exit 2), never "caught". Counting it as caught let a stale sed
    # pattern that produced garbage pass falsify green.
    if ! swiftc -o "$mdir/si_check" \
        "$mdir/ShellIntegration.swift" \
        "$mdir/Osc7Directory.swift" \
        "$mdir/main.swift" 2>"$mlog"; then
        echo "  mutant $mname: ENVIRONMENTAL — the mutant did not compile"
        grep -E 'error:' "$mlog" | head -3 | sed 's/^/      /'
        env_bad=1
        return 0
    fi
    if cmp -s "$SRC_O7" "$mdir/Osc7Directory.swift"; then
        echo "  mutant $mname: ENVIRONMENTAL — the sed pattern no longer applies"
        env_bad=1
        return 0
    fi
    local mout mstatus
    mout="$("$mdir/si_check" 2>&1)"; mstatus=$?
    if [[ $mstatus -eq 1 ]]; then
        echo "  mutant $mname: caught (exit 1 — gate detected the mutation)"
    elif [[ $mstatus -eq 0 ]]; then
        echo "  mutant $mname: MISSED — gate exited 0; mutant should have been caught"
        all_caught=0
    else
        echo "  mutant $mname: unexpected exit $mstatus (environmental)"
        env_bad=1
    fi
}

run_mutant "drop-host-check"
run_mutant "double-decode"
run_mutant "case-sensitive-compare"

if [[ $env_bad -eq 1 ]]; then
    echo "==> falsify: ENVIRONMENTAL — at least one mutant could not be run (exit 2)"
    exit 2
elif [[ $all_caught -eq 1 ]]; then
    echo "==> falsify: all 3 mutants caught — gate is load-bearing"
    exit 0
else
    echo "==> falsify: FAIL — at least one mutant was not caught"
    exit 1
fi
