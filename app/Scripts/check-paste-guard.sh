#!/bin/bash
#
# Does PasteGuard's threshold logic fire on the right pastes?
# Asserts the newline and character count policies in PasteGuardPolicy.swift.
#
# WHAT IS UNDER TEST. `Sources/Umber/PasteGuardPolicy.swift` only. That file is
# Foundation-only BY DESIGN — the *decision* (should this paste be confirmed?) is a pure
# function of the text being pasted, and a pure function compiles headless with swiftc: no
# NSAlert, no NSView, no window server. Same trick check-command-outcome.sh plays on
# CommandOutcome.swift, check-renderer-config.sh on Renderer.swift,
# check-cursor-style.sh on CursorStyle.swift. Compiling the SHIPPED file, not a restatement
# of its table, is the whole point: a check that restates the policy proves only that the
# check agrees with itself.
#
# WHY IT EXISTS. PasteGuard prevents the failure mode where a clipboard containing a
# shell script is pasted into a terminal that has no bracketed-paste support — each `\n`
# is a submitted command, and an accidental paste of a build script that includes `rm -rf`
# is the canonical worst case. The threshold decisions (1 newline, 1 500 chars) have no
# crash on regression: a wrongly-low threshold shows every single-line paste a dialog; a
# wrongly-high one silently pastes a script. Neither failure is loud. This gate is the
# only thing that would catch a constant change or a logic inversion before daily use.
#
# WHAT IT CANNOT REACH, stated rather than implied. Whether the NSAlert dialog renders
# correctly, whether the Paste / Cancel button wires to the right return value, whether
# `confirmIfNeeded` is called at the right point in the paste path, and whether the
# informative-text preview truncates at 200 characters as written. Those require AppKit,
# an NSView, and a window server — they are daily-drive and live-app territory. This owns
# the threshold mapping only.
#
# EXIT CODES: 0 = all cases passed. 1 = a REAL failure (a threshold mapped wrongly,
# or the constant moved). 2 = environmental (no toolchain, source file missing, harness
# would not compile). A broken environment must never read as a green gate.
#
# Usage:
#   ./Scripts/check-paste-guard.sh            # run all cases
#   ./Scripts/check-paste-guard.sh --quiet    # summary line and failures only

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/Umber/PasteGuardPolicy.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2
    exit 2
}
[[ -f "$SRC" ]] || {
    echo "error: $SRC not found — did the file move? This gate names its subject explicitly." >&2
    exit 2
}

TMP=$(mktemp -d) || { echo "error: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

var bad = 0

func expect(_ label: String, _ got: Bool, _ want: Bool) {
    if got == want { return }
    print("  FAIL \(label): shouldConfirm returned \(got), expected \(want)")
    bad += 1
}

func expectEval(_ label: String, result: PasteGuardPolicy.PasteResult,
                wantConfirm: Bool, wantNewlines: Int, wantChars: Int) {
    if result.shouldConfirm != wantConfirm {
        print("  FAIL \(label): evaluate.shouldConfirm = \(result.shouldConfirm), expected \(wantConfirm)")
        bad += 1
    }
    if result.newlineCount != wantNewlines {
        print("  FAIL \(label): evaluate.newlineCount = \(result.newlineCount), expected \(wantNewlines)")
        bad += 1
    }
    if result.characterCount != wantChars {
        print("  FAIL \(label): evaluate.characterCount = \(result.characterCount), expected \(wantChars)")
        bad += 1
    }
}

// Helpers for building test inputs
let newlineThreshold = PasteGuardPolicy.newlineThreshold
let charThreshold    = PasteGuardPolicy.characterThreshold

func lines(_ n: Int) -> String { (0..<n).map { "line\($0)" }.joined(separator: "\n") }
func chars(_ n: Int) -> String { String(repeating: "x", count: n) }

// --- 1. Empty and trivial inputs --------------------------------------------------------
// An empty paste should never trigger a dialog.
expect("empty string",            PasteGuardPolicy.shouldConfirm(""),         false)
expect("single space",            PasteGuardPolicy.shouldConfirm(" "),        false)

// --- 2. Single-line pastes below the character threshold --------------------------------
// These are the overwhelmingly common case: a command, a URL, a path.
expect("short single-line",       PasteGuardPolicy.shouldConfirm("ls -la"),   false)
expect("100-char single-line",    PasteGuardPolicy.shouldConfirm(chars(100)), false)

// One character below the threshold must NOT trigger.
let justUnder = charThreshold - 1
expect("charThreshold - 1",       PasteGuardPolicy.shouldConfirm(chars(justUnder)), false)

// --- 3. Character threshold, exact boundary (inclusive per `>=`) -----------------------
// AT the threshold must trigger.
expect("charThreshold exactly",   PasteGuardPolicy.shouldConfirm(chars(charThreshold)), true)
// Well above the threshold.
expect("3000 chars, no newlines", PasteGuardPolicy.shouldConfirm(chars(3_000)), true)

// --- 4. Newline threshold — any multiline paste triggers a dialog ----------------------
// Zero newlines but the text is non-trivial: already covered by the char cases above.
// One newline is AT the threshold (newlineThreshold == 1).
let twoLines = "first line\nsecond line"
expect("two lines (1 newline)",   PasteGuardPolicy.shouldConfirm(twoLines),    true)
expect("three lines (2 newlines)",PasteGuardPolicy.shouldConfirm(lines(3)),    true)
expect("ten lines",               PasteGuardPolicy.shouldConfirm(lines(10)),   true)
expect("100 lines",               PasteGuardPolicy.shouldConfirm(lines(100)),  true)

// A single trailing newline counts — it is still a multiline paste.
expect("trailing newline",        PasteGuardPolicy.shouldConfirm("cmd\n"),     true)

// --- 5. Both thresholds exceeded simultaneously -----------------------------------------
// A long multiline paste should still be caught by both checks independently.
let bigMultiline = lines(20) + chars(charThreshold)
expect("big multiline",           PasteGuardPolicy.shouldConfirm(bigMultiline), true)

// --- 6. Threshold pin — changing a constant is a deliberate act -----------------------
// If newlineThreshold moves, this line forces the decision and its cases move with it.
if newlineThreshold != 1 {
    print("  FAIL newlineThreshold moved: \(newlineThreshold), expected 1 — "
          + "if deliberate, update this case and the boundary cases above")
    bad += 1
}
// Same for characterThreshold.
if charThreshold != 1_500 {
    print("  FAIL characterThreshold moved: \(charThreshold), expected 1_500 — "
          + "if deliberate, update this case and the boundary cases above")
    bad += 1
}

// --- 7. FALSIFICATION PIN ---------------------------------------------------------------
// This gate must be capable of failing. To re-verify it is not vacuous, invert the
// return in `shouldConfirm` (return !(...)) — that must turn every "true" case red.
// Verified by doing exactly that during authoring: all multi-line and large-paste cases
// failed, and the empty/short cases stayed green as expected, which is the right asymmetry.
if PasteGuardPolicy.shouldConfirm(lines(5)) == false {
    print("  FAIL falsification pin: a 5-line paste must trigger confirmation")
    bad += 1
}
if PasteGuardPolicy.shouldConfirm("ls -la") == true {
    print("  FAIL falsification pin: a short single-line paste must NOT trigger confirmation")
    bad += 1
}

// --- 8. evaluate(_:) path — pre-computed counts -----------------------------------------
// Case 8a: a string at exactly charThreshold with exactly 1 newline tests both thresholds
// simultaneously and exercises the evaluate path that PasteGuard.confirmIfNeeded uses to
// avoid double-traversal.  charThreshold chars split as (charThreshold-1) x-chars + one
// newline = charThreshold total characters, 1 newline.
let boundary = chars(charThreshold - 1) + "\n"
expectEval("simultaneous boundary (charThreshold chars, 1 newline)",
           result: PasteGuardPolicy.evaluate(boundary),
           wantConfirm: true,
           wantNewlines: 1,
           wantChars: charThreshold)

// Case 8b: evaluate on a short safe string must return shouldConfirm=false with correct counts.
let safeText = "hello"
expectEval("evaluate safe string",
           result: PasteGuardPolicy.evaluate(safeText),
           wantConfirm: false,
           wantNewlines: 0,
           wantChars: 5)

// Case 8c: shouldConfirm must agree with evaluate for both branches.
let longText = chars(charThreshold)
if PasteGuardPolicy.shouldConfirm(longText) != PasteGuardPolicy.evaluate(longText).shouldConfirm {
    print("  FAIL evaluate/shouldConfirm agreement: results diverge on charThreshold string")
    bad += 1
}

if bad == 0 {
    print("  ok  empty and trivial pastes never trigger confirmation")
    print("  ok  single-line pastes below character threshold pass through")
    print("  ok  character threshold boundary is inclusive (charThreshold - 1 = safe, charThreshold = confirm)")
    print("  ok  any newline triggers confirmation (newlineThreshold = 1)")
    print("  ok  both thresholds exceeded simultaneously (charThreshold chars + 1 newline)")
    print("  ok  both thresholds pin to their documented values (1 newline, 1_500 chars)")
    print("  ok  falsification pin holds")
    print("  ok  evaluate(_:) returns correct shouldConfirm, newlineCount, and characterCount")
    print("\nall paste-guard cases passed (14 threshold cases + 2 constant pins + 2 falsification pins + 3 evaluate cases)")
} else {
    print("\n\(bad) paste-guard case(s) FAILED")
}
exit(bad == 0 ? 0 : 1)
SWIFT

if ! swiftc -o "$TMP/pasteguard" "$SRC" "$TMP/main.swift" 2>"$TMP/compile.log"; then
    echo "error: the harness would not compile — the gate cannot run." >&2
    echo "  If this names AppKit or NSAlert, PasteGuardPolicy.swift has stopped being" >&2
    echo "  Foundation-only and THAT is the regression: the policy must stay compilable" >&2
    echo "  without a view." >&2
    grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
fi

out="$("$TMP/pasteguard" 2>&1)"; status=$?
say "$out"
exit $status
