#!/bin/bash
#
# Assert that a `cursor` string in config.json maps to the caret it names, that an
# unrecognised one maps to NOTHING so AppConfig.load() can warn and degrade, and that every
# case still emits the DECSCUSR code it emitted before the enum moved.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/CursorStyle.swift` only. Foundation-only by design — its
# header says so — so it compiles standalone with swiftc and never links AppKit, SwiftTerm or
# libghostty. Same trick check-renderer-config.sh plays on Renderer.swift, check-keybindings.sh
# on KeyBindings.swift, check-cwd-follow.sh on ShellDirectory.swift. Compiling the SHIPPED
# file, not a copy, is the whole point: a check that restates the table proves only that the
# check agrees with itself.
#
# WHY IT EXISTS. On 2026-07-31 `CursorStyle` stopped being **SwiftTerm's** enum and became this
# project's own, so that a second engine-backed pane could read `AppConfig.cursorStyle` without
# importing the emulator (and so deleting SwiftTerm at Step 2 of the libghostty swap would not
# break Config.swift). That move carried two hand-maintained tables across a file boundary —
# the six config spellings and the six DECSCUSR codes — and a transcription slip in either is
# the quietest possible bug: a config line that reads correctly, parses without a warning, and
# either does nothing or silently selects a different caret. Nothing else in the repo would
# catch it. TerminalPane feeds `\e[<n> q` straight to the emulator, so a wrong `n` is a wrong
# cursor with no error anywhere, and `check-keybindings.sh` does not touch this file.
#
# THE CODES ARE ASSERTED AGAINST THE PRE-MOVE SOURCE, NOT AGAINST THE NEW ENUM. The six
# expected values below are transcribed from the switch as it stood in TerminalPane.swift
# BEFORE the refactor (blinkBlock=1 … steadyBar=6). That is what makes this a regression test
# rather than a tautology: if the move mistyped a code, this fails even though the new file is
# internally consistent.
#
# Validated by falsification, like check-reflow.sh and check-altbuffer-resize.sh: mistyping one
# DECSCUSR code fails 2 cases, dropping one config spelling fails 1, and breaking the shape/blink
# decomposition fails 2 — which is the only reason to believe the passes mean anything. Recorded
# here rather than in the pull request that introduced it, because a PR body is not something the
# next reader of this script will ever see.
#
# Usage:
#   ./Scripts/check-cursor-style.sh            # run all cases
#   ./Scripts/check-cursor-style.sh --quiet    # summary line and failures only
#
# Exit codes:
#   0  every spelling maps as promised, unknowns are rejected, every DECSCUSR code is unchanged
#   1  a real failure — a spelling, a code, the decomposition, or the default is wrong
#   2  environmental — no swiftc, source file missing, or a harness that would not compile.
#      Never conflated with 1: a broken environment must not read as a green gate.

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/CursorStyle.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
}
[[ -f "$SRC" ]] || { echo "error: $SRC missing." >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Swift only allows top-level code in a file literally named main.swift, hence the subdir.
mkdir -p "$TMP/pure"
cat > "$TMP/pure/main.swift" <<'SWIFT'
import Foundation

var bad = 0
func expect(_ raw: String, _ want: CursorStyle?, _ label: String) {
    let got = CursorStyle.named(raw)
    if got != want {
        print("FAIL \(label): CursorStyle.named(\"\(raw)\") -> \(String(describing: got)), "
              + "want \(String(describing: want))")
        bad += 1
    }
}

// ---- 1. Every spelling the config file has ever accepted -------------------------------
// Transcribed from Config.swift's switch as it stood before the enum moved. Dropping one of
// these silently turns a working user config into a warning on upgrade.
expect("block",             .blinkBlock,      "block")
expect("block-steady",      .steadyBlock,     "block-steady")
expect("steady-block",      .steadyBlock,     "steady-block")
expect("bar",               .blinkBar,        "bar")
expect("bar-steady",        .steadyBar,       "bar-steady")
expect("steady-bar",        .steadyBar,       "steady-bar")
expect("underline",         .blinkUnderline,  "underline")
expect("underline-steady",  .steadyUnderline, "underline-steady")
expect("steady-underline",  .steadyUnderline, "steady-underline")

// `underline-bar` -> .blinkBar looks like a typo in the original table and probably is. It is
// asserted anyway, deliberately: it has been accepted since the config file existed, so it is
// a compatibility promise now. If it is ever removed, that must be a decision made HERE.
expect("underline-bar",     .blinkBar,        "underline-bar (historical alias for bar)")

// Case folding is the one normalisation the mapping performs.
expect("BLOCK",             .blinkBlock,      "case folded")
expect("Steady-Bar",        .steadyBar,       "case folded hyphenated")

// ---- 2. The failures that must STAY failures -------------------------------------------
// nil is what lets AppConfig.load() append a warning and fall back. A mapping that guessed
// here would turn a typo into a silently different caret.
expect("bogus",    nil, "unknown value rejected")
expect("",         nil, "empty string rejected")
expect("block ",   nil, "trailing space not silently trimmed")
expect("steady",   nil, "bare 'steady' is not a style")
// Underscores are NOT folded here, unlike Renderer.named which explicitly folds them. That
// asymmetry is real and worth pinning: if it is ever unified, this line should be the thing
// that forces the decision rather than a user discovering it.
expect("steady_block", nil, "underscore NOT folded (differs from Renderer.named — intentional)")

// ---- 3. DECSCUSR codes, against the pre-move values ------------------------------------
// This is the regression half. TerminalPane feeds "\u{1b}[<code> q"; a wrong code is a wrong
// caret with no error anywhere.
func expectCode(_ style: CursorStyle, _ want: Int, _ label: String) {
    if style.decscusrCode != want {
        print("FAIL decscusr \(label): \(style).decscusrCode = \(style.decscusrCode), want \(want)")
        bad += 1
    }
}
expectCode(.blinkBlock,      1, "blinkBlock")
expectCode(.steadyBlock,     2, "steadyBlock")
expectCode(.blinkUnderline,  3, "blinkUnderline")
expectCode(.steadyUnderline, 4, "steadyUnderline")
expectCode(.blinkBar,        5, "blinkBar")
expectCode(.steadyBar,       6, "steadyBar")

// Codes must be unique and cover 1...6 exactly — DECSCUSR defines no others, and a duplicate
// would mean two styles are the same caret.
let codes = CursorStyle.allCases.map(\.decscusrCode).sorted()
if codes != [1, 2, 3, 4, 5, 6] {
    print("FAIL decscusr coverage: codes are \(codes), want [1, 2, 3, 4, 5, 6]")
    bad += 1
}

// ---- 4. shape/blinks decomposition -----------------------------------------------------
// libghostty takes shape and blink as two settings, so GhosttyPane reads these rather than the
// DECSCUSR code. They must agree with the case they came from, or the two engines would render
// the same config differently — the exact divergence the shared enum exists to prevent.
func expectParts(_ s: CursorStyle, _ shape: CursorStyle.Shape, _ blinks: Bool, _ label: String) {
    if s.shape != shape || s.blinks != blinks {
        print("FAIL parts \(label): \(s) -> shape=\(s.shape) blinks=\(s.blinks), "
              + "want shape=\(shape) blinks=\(blinks)")
        bad += 1
    }
}
expectParts(.blinkBlock,      .block,     true,  "blinkBlock")
expectParts(.steadyBlock,     .block,     false, "steadyBlock")
expectParts(.blinkUnderline,  .underline, true,  "blinkUnderline")
expectParts(.steadyUnderline, .underline, false, "steadyUnderline")
expectParts(.blinkBar,        .bar,       true,  "blinkBar")
expectParts(.steadyBar,       .bar,       false, "steadyBar")

// Every shape must be reachable, in both blink states. Written as a derivation over allCases
// so adding a seventh case cannot leave this assertion behind.
if CursorStyle.allCases.count != 6 {
    print("FAIL coverage: \(CursorStyle.allCases.count) cases, expected 6 — update this gate")
    bad += 1
}
for shape in [CursorStyle.Shape.block, .underline, .bar] {
    let matching = CursorStyle.allCases.filter { $0.shape == shape }
    if matching.count != 2 || Set(matching.map(\.blinks)) != [true, false] {
        print("FAIL shape \(shape): expected exactly one blinking and one steady case")
        bad += 1
    }
}

// ---- 5. The default -------------------------------------------------------------------
// AppConfig.defaults() reads CursorStyle.default rather than re-hardcoding a case, so this is
// the single source of truth. It must remain what the app shipped with.
if CursorStyle.default != .blinkBlock {
    print("FAIL default: CursorStyle.default is \(CursorStyle.default), expected .blinkBlock")
    bad += 1
}
// ...and the warning AppConfig.load() prints says "using block", so the default must actually
// BE a block. A default that drifted to a bar would make that message a lie.
if CursorStyle.default.shape != .block {
    print("FAIL default shape: AppConfig.load() warns 'using block' but default is "
          + "\(CursorStyle.default.shape)")
    bad += 1
}

print(bad == 0 ? "ALL-OK" : "SOME-FAILED")
SWIFT

if ! swiftc -O -o "$TMP/cursorcheck" "$SRC" "$TMP/pure/main.swift" 2>"$TMP/compile.log"; then
  echo "error: $SRC would not compile standalone — the gate cannot run." >&2
  echo "  That file is Foundation-only on purpose so this is possible. If it now needs" >&2
  echo "  AppKit, SwiftTerm or GhosttyTerminal, the pure mapping and the live action have" >&2
  echo "  been re-merged and the split that made CursorStyle.swift checkable is gone — that" >&2
  echo "  is the thing to fix, not this script." >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

out="$("$TMP/cursorcheck" 2>&1)"
if [[ "$out" == *"ALL-OK"* ]]; then
  say "  ok  all 10 config spellings map as promised; 5 unknowns rejected"
  say "  ok  all 6 DECSCUSR codes unchanged from the pre-move table, unique, covering 1-6"
  say "  ok  shape/blinks decomposition agrees with every case; default is a blinking block"
  echo
  echo "all cursor-style cases passed (15 mappings + 6 codes + 6 decompositions + default)"
  exit 0
fi

echo "✗ FAIL: $SRC's mapping or DECSCUSR table is wrong:" >&2
echo "$out" | sed 's/^/    /' >&2
exit 1
