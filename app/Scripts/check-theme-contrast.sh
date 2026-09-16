#!/bin/bash
#
# Assert that the shipped `umber` palette is measurably legible — and that the rules
# doing the asserting are strict enough to reject a palette known to be bad.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/ThemeValues.swift`, `Sources/GoblinPortal/ThemeContrast.swift`
# and `Sources/GoblinPortal/SyntaxPalette.swift` only. All three are Foundation-only BY DESIGN — their
# headers say so — precisely so they can be
# compiled here with swiftc and never link AppKit, SwiftTerm, or the app. Same trick
# check-renderer-config.sh plays on Renderer.swift and check-cwd-follow.sh plays on
# ShellDirectory.swift. Compiling the SHIPPED files, not copies, is the whole point: a check
# that restates the palette proves only that the check agrees with itself.
#
# WHY IT EXISTS. Every claim a theme makes about itself — "legible", "colour-blind safe",
# "the bright colours are actually brighter" — is a number, and a number nobody computed is
# a taste claim wearing a lab coat. Measured with this code, the well-regarded palettes fail
# badly and silently: Solarized Dark's comment colour is APCA Lc 0.0 (invisible), Tokyo
# Night's and Nord's are 10.3, and Tokyo Night, Catppuccin, Nord and Rosé Pine all ship
# *identical* values in their normal and bright chromatic slots, so bold text — which
# SwiftTerm draws from the bright half by default — is indistinguishable from plain. None of
# that is visible by reading hex. This gate is how Goblin Portal's palette avoids joining them.
#
# WHAT IT CANNOT REACH. Everything that needs AppKit: whether `Theme.swift` actually hands
# these values to either engine, whether `installColors` took, the sidebar's git tints (which
# are macOS system colours by design and deliberately do NOT follow the theme —
# GitStatus+Presentation.swift argues why), and anything about how the palette LOOKS. The
# last one is real: four automated search passes each satisfied more constraints than the
# last while producing, in order, noise, pastels, neon, and a green that measured well and
# read as mint. The rendered previews in .afk/research/theme-design-2026-08-03/ are the
# record of that, and taste remains a human gate. This script guards the floor, not the bar.
#
# Usage:
#   ./Scripts/check-theme-contrast.sh            # run all cases
#   ./Scripts/check-theme-contrast.sh --quiet    # summary line and failures only
#
# Exit codes:
#   0  every palette parses, and `umber` meets every contrast, ring and colour-vision rule
#   1  a real failure — a threshold missed, a palette that will not parse, a preset that is
#      unreachable from config, or the falsification case PASSING (which would mean the
#      thresholds are too loose for any of the other results to mean anything)
#   2  environmental — no swiftc, a source file missing, or a harness that would not compile.
#      Never conflated with 1: a broken environment must not read as a green gate.

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."

VALUES="Sources/GoblinPortal/ThemeValues.swift"
COMMUNITY="Sources/GoblinPortal/ThemeValues+CommunityPresets.swift"
CONTRAST="Sources/GoblinPortal/ThemeContrast.swift"
SYNTAX="Sources/GoblinPortal/SyntaxPalette.swift"
HARNESS="Scripts/check-theme-contrast-harness.swift"
SYNHARNESS="Scripts/check-theme-contrast-syntax.swift"
REGISTRY="Scripts/check-theme-contrast-registry.swift"
REPAIR="Scripts/check-theme-contrast-repair.swift"
REFERENCE="Scripts/check-theme-contrast-reference.swift"
THEME="Sources/GoblinPortal/Theme.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
}
for f in "$VALUES" "$COMMUNITY" "$CONTRAST" "$SYNTAX" "$HARNESS" "$SYNHARNESS" "$REGISTRY" "$REPAIR" "$REFERENCE" "$THEME"; do
  [[ -f "$f" ]] || { echo "error: $f not found (run from the app/ directory)." >&2; exit 2; }
done

# A pure file that has quietly acquired a UI import is a real regression in the split that
# makes this gate possible, so name it as that rather than as a compile error later.
for f in "$VALUES" "$COMMUNITY" "$CONTRAST" "$SYNTAX"; do
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

if ! swiftc -O -o "$TMP/themecheck" "$VALUES" "$COMMUNITY" "$CONTRAST" "$SYNTAX" "$SYNHARNESS" "$REGISTRY" "$REPAIR" \
     "$REFERENCE" "$TMP/pure/main.swift" \
     2>"$TMP/compile.log"; then
  echo "error: the pure theme sources would not compile standalone — the gate cannot run." >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

# The harness's EXIT CODE is the verdict. It also prints ALL-OK, but trusting the string
# alone would let a crash *after* the verdict read as a pass — exit-code discipline is shared
# by all check-*.sh scripts to prevent that class of false green.
out="$("$TMP/themecheck" 2>&1)"; status=$?

if [[ $status -ne 0 && $status -ne 1 ]]; then
  echo "error: the harness died with status $status rather than reporting a verdict." >&2
  echo "$out" | sed 's/^/    /' >&2
  exit 2
fi

if [[ $status -eq 1 ]]; then
  echo "✗ FAIL: the shipped palette does not meet its own stated rules:" >&2
  echo "$out" | sed 's/^/    /' >&2
  exit 1
fi

if [[ "$out" != *"ALL-OK"* ]]; then
  echo "error: harness exited 0 without printing a verdict — cannot confirm it ran." >&2
  echo "$out" | sed 's/^/    /' >&2
  exit 2
fi

# Reachability is asserted IN the harness now, by calling ThemePalette.named(_:) directly (see
# its round-trip section). This used to be a grep of Theme.preset(named:)'s switch, because the
# mapping lived behind AppKit; reconciling PR #24 moved it into the Foundation-only
# ThemeValues.swift, so the real resolver became callable and the grep proxy retired.
#
# What remains here is the one thing the harness cannot see: that Theme.swift still DELEGATES
# to that resolver instead of reintroducing a private switch, which would restore exactly the
# ungated second list the move removed.
#
# Comments are stripped FIRST. The obvious version of this check — grep for the bare quoted
# name — was written first and was BLIND: every preset name also appears in a doc comment in
# that file (`"preset": "umber"`), so deleting the real code still passed. Found by deliberately
# deleting it; the lesson is that a grep-based assertion must match the CONSTRUCT, not the
# vocabulary.
STRIPPED="$TMP/theme-nocomments.swift"
sed -e 's|//.*$||' "$THEME" > "$STRIPPED"
if ! grep -qE 'ThemePalette\.named\(.*\)\.map\(Theme\.init\)' "$STRIPPED"; then
  echo "✗ FAIL: Theme.preset(named:) no longer delegates to ThemePalette.named in $THEME." >&2
  echo "    Presets must resolve through the Foundation-only resolver — the one a gate can" >&2
  echo "    actually call. A local switch here is a second list, unreachable by any check" >&2
  echo "    and free to drift from ThemePalette.all." >&2
  exit 1
fi
if grep -qE '^[[:space:]]*case[[:space:]]+"(umber|afk-dark|afk-light|tokyo-night)"' "$STRIPPED"; then
  echo "✗ FAIL: $THEME has reintroduced per-preset case lines." >&2
  echo "    The name mapping belongs in ThemeValues.swift, where both gates can call it." >&2
  exit 1
fi

# CONSTANT-DRIFT GUARD. The harness measures the tab strip's derived colours from its own
# copies of three constants, and asserts the app's DEFAULT palette. If either file drifts,
# the harness keeps passing while testing numbers the app no longer draws — which is worse
# than having no harness, because it reads as a green gate.
#
# Comments are stripped before matching, for the same reason as the preset check above and
# with a sharper edge here: the rationale comment beside `textAlpha` names the OLD value
# (0.55) and the new one, so a naive grep would match prose and pass whatever the code said.
#
# This block was deleted by the #25 reconciliation merge (f8b6d38) and restored here. The
# deletion was silent in the worst way: the `say` line below still claimed "harness constants
# match" while nothing checked it, and `AFK.md`'s falsification note still described a guard
# that was gone. Reachability moved into the harness legitimately; THIS is a separate concern
# that could not follow it, because `DocumentTabStrip+Drawing.swift` imports AppKit and can
# never be linked into a Foundation-only harness — a shell-side grep is the only instrument
# that reaches it (PR #24 review, finding 1).
DRAW="Sources/GoblinPortal/DocumentTabStrip+Drawing.swift"
[[ -f "$DRAW" ]] || { echo "error: $DRAW not found." >&2; exit 2; }
STRIP_DRAW="$TMP/draw-nocomments.swift"
STRIP_CFG="$TMP/config-nocomments.swift"
sed -e 's|//.*$||' "$DRAW" > "$STRIP_DRAW"
sed -e 's|//.*$||' "Sources/GoblinPortal/Config.swift" > "$STRIP_CFG"

drift=()
grep -qE 'isActive \? 0\.95 : 0\.72' "$STRIP_DRAW" \
  || drift+=("tab label alpha is no longer 'isActive ? 0.95 : 0.72' — update ALPHA_ACTIVE/ALPHA_INACTIVE in the harness")
grep -qE 'blended\(withFraction: 0\.07' "$STRIP_DRAW" \
  || drift+=("railBackground no longer lifts by 0.07 — update RAIL_LIFT in the harness")
grep -qE '^[[:space:]]*theme: \.classicRepaired,' "$STRIP_CFG" \
  || drift+=("AppConfig.defaults() no longer installs .classicRepaired — the gate's floors no longer describe what the app ships by default")

# CONSUMER GUARD. A measured colour with no consumer is the failure this repo has already
# shipped once: `ThemePalette.selection` was designed, measured and asserted from the day the
# palettes landed, and for the whole time it reached NOTHING — `Theme` had no such field, so
# the value could not cross the AppKit bridge even in principle, and no check noticed because
# every check was about the number rather than about its reaching anything. Measuring a colour
# nobody draws is the same class of error as drawing a colour nobody measured.
#
# So: assert the wiring exists. Necessarily a grep — `Theme.swift` and the pane import AppKit
# and cannot be linked here — and therefore weak: it proves the expression is present, not
# that a selected range renders in it. That remains daily-drive territory. Comments stripped
# first and matched on the CONSTRUCT for the reason the preset check below documents at length.
VIEWER="Sources/GoblinPortal/FileViewerPane+Document.swift"
CHROME="Sources/GoblinPortal/Config+Chrome.swift"
TERMINAL="Sources/GoblinPortal/TerminalPane.swift"
[[ -f "$VIEWER" ]]   || { echo "error: $VIEWER not found." >&2; exit 2; }
[[ -f "$CHROME" ]]   || { echo "error: $CHROME not found." >&2; exit 2; }
[[ -f "$TERMINAL" ]] || { echo "error: $TERMINAL not found." >&2; exit 2; }
STRIP_VIEWER="$TMP/viewer-nocomments.swift"
STRIP_THEME="$TMP/theme-nocomments-fields.swift"
STRIP_CHROME="$TMP/chrome-nocomments.swift"
STRIP_TERMINAL="$TMP/terminal-nocomments.swift"
sed -e 's|//.*$||' "$VIEWER"   > "$STRIP_VIEWER"
sed -e 's|//.*$||' "$THEME"    > "$STRIP_THEME"
sed -e 's|//.*$||' "$CHROME"   > "$STRIP_CHROME"
sed -e 's|//.*$||' "$TERMINAL" > "$STRIP_TERMINAL"
grep -qE 'selection = NSColor\.fromHex\(palette\.selection\)' "$STRIP_THEME" \
  || drift+=("Theme no longer builds .selection from the palette — the measured value has stopped crossing the AppKit bridge, which is exactly how it went unused before")
grep -qE 'selectedTextAttributes' "$STRIP_VIEWER" \
  || drift+=("FileViewerPane no longer sets selectedTextAttributes — the editor has stopped consuming theme.selection and nothing else does")
# The greps below are NOT redundant with it, and it alone was BLIND. It matches the
# identifier, so it survives any mutation that keeps the assignment and changes what is
# assigned — including `= [.backgroundColor: NSColor.selectedTextBackgroundColor]`, the
# ORIGINAL BUG restored verbatim: the measured colour reaches nothing and the gate stays
# green. That is this script's own stated lesson (match the CONSTRUCT, not the vocabulary —
# see the preset check above) applied to the check that documents it.
#
# Anchored to the CALL SITE, not to the helper. `effectiveSelectionColors()` was promoted
# to Config+Chrome.swift (#31) so both panes share the rule; the helper name changed too.
# Grepping the viewer for the old `Self.readableSelection(for:)` after promotion would PASS
# while the wiring was severed — which is precisely the failure mode the comment above warns
# about. The new check matches the shared-method call instead.
grep -qE 'config\.effectiveSelectionColors\(\)\.map' "$STRIP_VIEWER" \
  || drift+=("FileViewerPane no longer maps config.effectiveSelectionColors() into selectedTextAttributes — the call-site wiring to the measured palette has been severed")
# SelectionPairing.isReadable moved to Config+Chrome.swift with the promotion (#31).
# Grepping the viewer for it would pass only if someone inlined the rule back there, which
# would be the duplication the promotion was meant to eliminate.
grep -qE 'SelectionPairing\.isReadable' "$STRIP_CHROME" \
  || drift+=("Config+Chrome.effectiveSelectionColors() no longer applies SelectionPairing.isReadable — a user override can pair a dark foreground with a preset's dark selection at APCA Lc 0.0 (invisible selected text)")
# Terminal consumer guard (#31): both bg+fg must be wired. A wiring that sets only bg
# would mix the theme colour with SwiftTerm's hardcoded black selectedTextForegroundColor.
grep -qE 'selectedTextBackgroundColor' "$STRIP_TERMINAL" \
  || drift+=("TerminalPane no longer sets selectedTextBackgroundColor — the terminal is back to SwiftTerm's hardcoded teal (#31 regressed)")
grep -qE 'selectedTextForegroundColor' "$STRIP_TERMINAL" \
  || drift+=("TerminalPane no longer sets selectedTextForegroundColor — selected terminal text will render against the hardcoded black, not the theme foreground")
if (( ${#drift[@]} )); then
  echo "✗ FAIL: the harness's assumptions have drifted from the shipped code:" >&2
  for d in "${drift[@]}"; do echo "    - $d" >&2; done
  exit 1
fi

say "  ok  presets resolve through the gated Foundation-only resolver"
say "  ok  tab-strip chrome measured for every shipped palette; harness constants match"
say "  ok  syntax roles: distinct non-surface slots, readable in every palette but one documented"
say "      exception (classic-repaired's comment — see check-theme-contrast-syntax.swift), comments"
say "      dimmer than body text"
say "  ok  syntax clamp: both branches reachable (umber raw, tokyo-night clamped) and it raises Lc"
say "  ok  runtime selection pair readable in every palette; unreadable user overrides fall back"
say "      to the complete system pair; the falsification's Lc 0.0 override is REJECTED"
say "  ok  terminal selection wired: both bg+fg set in TerminalPane from effectiveSelectionColors"
say "      (#31 — SwiftTerm's hardcoded teal is replaced by the theme-aware pair)"
echo
echo "${out%%$'\n'*}"
echo "all theme-contrast cases passed"
exit 0
