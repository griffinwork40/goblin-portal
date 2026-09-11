#!/bin/bash
#
# check-light-theme.sh — the shipped palettes are well-formed, and `afk-light` is
# actually light enough to flip the window chrome.
#
# WHAT IS UNDER TEST. `Sources/Umber/ThemeValues.swift` only. That file is
# Foundation-only BY DESIGN — its header says so — precisely so it can be compiled on
# its own with swiftc and never link AppKit or SwiftTerm. Same trick
# check-renderer-config.sh plays on Renderer.swift and check-cursor-style.sh plays on
# CursorStyle.swift. Compiling the SHIPPED file, not a copy of its values, is the whole
# point: a check that restates the palette proves only that the check agrees with itself.
#
# `Theme.swift` is deliberately NOT the subject and cannot be: it imports AppKit *and*
# SwiftTerm, so `swiftc Sources/Umber/Theme.swift` exits 1 on `no such module 'SwiftTerm'`
# and nothing in it has ever been gateable. That is why the palettes and the luminance
# formula were moved out — the split is what created something checkable.
#
# WHY IT EXISTS AT ALL. `AppConfig.appearance` (`Config.swift:175-176`) derives the window's
# light/dark chrome from the theme background's relative luminance:
#
#     NSAppearance(named: Double(effectiveBackground.relativeLuminance) > WCAG.lightChromeCutoff
#                        ? .aqua : .darkAqua)
#
# So a "light" preset whose background lands at or below that cutoff installs its
# colours and leaves the sidebar, titlebar and scrollers DARK. The result is a config
# line that parses, warns about nothing, and half-works — the quietest possible failure
# and exactly the class check-renderer-config.sh exists to prevent for `renderer`.
# Nothing else in this repo can catch it, because the deciding comparison lives in a
# file that imports AppKit. Case 2 below is that assertion, and it is why this script
# exists; the other six are there to stop case 2 passing for the wrong reason.
#
# `lightChromeCutoff` itself is declared in `ThemeContrast.swift`, one of the two files THIS
# script compiles, and `Config.swift:176` reads that exact symbol rather than a second literal —
# there used to be two independent `0.179`s, one production read and one this gate read,
# and nothing tied them together (PR #24 review, item 1). Cases 2–3 below now constrain
# the same constant `AppConfig.appearance` compares against.
#
# WHAT THIS CANNOT SEE, stated plainly the way check-cwd-follow.sh states its blindness:
# it never renders a pixel. It cannot tell you the sidebar's vibrant material actually
# changed, that the tab strip picked the right rail blend, that the caret is visible
# inside a selection, or that `.aqua` chrome looks right against #FFFFFF. Those import
# AppKit and are UMBER_DIAG and daily-drive territory. It also says nothing about ANSI
# 16-255: Umber pins `ansi256PaletteStrategy = .xterm` (`TerminalPane.swift:165`) so
# those 240 indices are the emulator's fixed xterm cube, not ours — and being dark-tuned,
# many of them are low-contrast on a white background. That is a known, documented
# limitation (app/README.md), not something this gate can measure or fix.
#
# Usage:
#   ./Scripts/check-light-theme.sh            # run all cases
#   ./Scripts/check-light-theme.sh --quiet    # summary line and failures only
#
# Exit codes:
#   0  every palette is well-formed, afk-light flips the chrome, the dark ones do not,
#      and every content slot is legible on its own background
#   1  a real failure — a malformed palette, a light theme that would render dark
#      chrome, a broken luminance formula, or an illegible slot
#   2  environmental — no swiftc, source file missing, or a harness that would not
#      compile. Never conflated with 1: a broken environment must not read as a green
#      gate.

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
VALUES="Sources/Umber/ThemeValues.swift"
COMMUNITY="Sources/Umber/ThemeValues+CommunityPresets.swift"
CONTRAST="Sources/Umber/ThemeContrast.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
}
for f in "$VALUES" "$COMMUNITY" "$CONTRAST"; do
  [[ -f "$f" ]] || { echo "error: $f missing." >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Swift only allows top-level code in a file literally named main.swift, hence the subdir
# rather than a descriptive filename.
mkdir -p "$TMP/pure"
cat > "$TMP/pure/main.swift" <<'SWIFT'
import Foundation

var bad = 0
func fail(_ m: String) { print("FAIL \(m)"); bad += 1 }

// ---- 1. Every shipped hex parses, and every palette is exactly 16 long. ----
// SwiftTerm's installColors is a NO-OP unless the array is exactly 16
// (`vendor/SwiftTerm/Sources/SwiftTerm/Terminal.swift:717-723`), so a 15-entry preset
// would install bg/fg and silently keep the previous palette. This case is also what
// makes `Theme.init(_:)`'s force-unwraps safe: it parses every literal before ship.
for t in ThemePalette.all {
    if t.ansi.count != 16 { fail("\(t.name): ansi has \(t.ansi.count) entries, need exactly 16") }
    for (i, h) in ([t.background, t.foreground, t.cursor] + t.ansi).enumerated() {
        if WCAG.luminance(hex: h) == nil { fail("\(t.name): slot \(i) '\(h)' is not parseable hex") }
    }
}

// ---- 2. THE KILL CRITERION. ----
// `AppConfig.appearance` (`Config.swift:175-176`) picks .aqua only when
// background.relativeLuminance > lightChromeCutoff. A "light" preset whose background
// lands at or below that cutoff installs its colours and leaves the sidebar, titlebar
// and scrollers dark — a config line that parses, warns about nothing, and half-works.
// This is the assertion the whole feature rests on, and `cutoff` below is read off
// `WCAG.lightChromeCutoff` — the SAME symbol `Config.swift:176` compares
// against, not a restated literal — so this case constrains the value production reads.
let cutoff = WCAG.lightChromeCutoff
func assertSide(_ name: String, wantLight: Bool) {
    guard let t = ThemePalette.named(name), let l = WCAG.luminance(hex: t.background) else {
        fail("\(name): not resolvable, or its background is not hex"); return
    }
    let isLight = l > cutoff
    if isLight != wantLight {
        fail("\(name): background \(t.background) luminance \(String(format: "%.5f", l)) "
             + "is \(isLight ? "ABOVE" : "at or BELOW") the \(cutoff) cutoff, so chrome would be "
             + "\(isLight ? "light" : "DARK") — wanted \(wantLight ? "light" : "dark")")
    }
}
assertSide("afk-light", wantLight: true)

// ---- 3. CONTROL for case 2. ----
// Both dark presets must stay BELOW the cutoff. If a bug made `luminance` return
// something monotonic-but-wrong (or a constant above the cutoff), the light assertion
// above would pass for the wrong reason and this catches it. A gate that can only say
// "yes" is measuring nothing.
// Derived from `ThemePalette.all` rather than named one by one, so a palette added later is
// covered without editing this gate. That gap was real: `umber` shipped as the DEFAULT on
// 2026-08-03 and this control named only afk-dark and tokyo-night, so the one palette almost
// every user now sees was the one whose chrome side went unasserted.
for pal in ThemePalette.all where pal.name != "afk-light" {
    assertSide(pal.name, wantLight: false)
}

// ---- 4. The formula itself, against values computable by hand. ----
// Guards the gamma expansion specifically: a version that skipped it would return
// 0.5 for mid-grey instead of 0.21586, and would still order the presets correctly —
// so cases 2 and 3 would both stay green while every contrast number was wrong.
if abs(WCAG.luminance(red: 1, green: 1, blue: 1) - 1.0) > 1e-9 { fail("luminance(white) != 1.0") }
if abs(WCAG.luminance(red: 0, green: 0, blue: 0)) > 1e-9 { fail("luminance(black) != 0.0") }
if let g = WCAG.luminance(hex: "#808080"), abs(g - 0.2158605) > 1e-5 {
    fail("luminance(#808080) = \(g), want ~0.21586 — the gamma expansion is missing or wrong")
}

// ---- 5. Name resolution, and the values that must stay unresolvable. ----
for t in ThemePalette.all where ThemePalette.named(t.name)?.name != t.name {
    fail("round-trip: '\(t.name)' does not resolve back to itself")
}
if ThemePalette.named("afklight")?.name != "afk-light" { fail("'afklight' should fold to afk-light") }
if ThemePalette.named("AFK-Light")?.name != "afk-light" { fail("case folding") }
// `named(_:)` reads `_` as `-` (`ThemeValues.swift`'s `raw.lowercased().replacingOccurrences(of:
// "_", with: "-")`), which widened accepted spellings beyond the old `Theme.preset(named:)` switch
// without a case asserting it — untested and undocumented until PR #24 review, item 4.
if ThemePalette.named("afk_light")?.name != "afk-light" { fail("'afk_light' should fold to afk-light") }
if ThemePalette.named("tokyo_night")?.name != "tokyo-night" { fail("'tokyo_night' should fold to tokyo-night") }
// `classic` MUST stay nil — it is the one accepted value meaning "install nothing".
// `AppConfig.resolveTheme` (`Config+Theme.swift:38-40`) distinguishes it from a typo by testing
// the raw string BEFORE resolving, so merging the two nils in a tidy-up would turn a
// mistyped preset into a silent no-theme.
if ThemePalette.named("classic") != nil { fail("'classic' must resolve to nil, not a preset") }
if ThemePalette.named("bogus") != nil { fail("unknown preset must resolve to nil so load() can warn") }
if !ThemePalette.configNames.contains("classic") { fail("configNames must name 'classic' — the warning lists it") }
if !ThemePalette.configNames.contains("afk-light") { fail("configNames must name 'afk-light'") }

// ---- 6. Legibility of the light palette against its OWN background. ----
// Dark-theme ANSI on a light background is the failure this preset exists to avoid, so
// assert it is actually avoided rather than assuming the source was good. WCAG 3.0 is
// the floor for non-body marks; the twelve slots below are the ones a TUI colours text
// with (0/7/8/15 are structural bg/fg tones and are exempt).
func contrast(_ a: String, _ b: String) -> Double {
    guard let x = WCAG.luminance(hex: a), let y = WCAG.luminance(hex: b) else { return 0 }
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
// `contentSlots` reaches index 14, so indexing either palette's `.ansi` below is only safe
// when it is exactly 16 long. Case 1 already fails loudly (and non-fatally) on any other
// length; without this guard a 15-entry palette passed case 1's non-fatal `fail()` and then
// TRAPPED here with an index-out-of-range instead of the SOME-FAILED exit the gate exists to
// produce (PR #24 review, item 5) — the one case where a bad palette crashes the harness
// instead of reporting on it.
let contentSlots = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
if let light = ThemePalette.named("afk-light"), light.ansi.count == 16 {
    for i in contentSlots {
        let c = contrast(light.ansi[i], light.background)
        if c < 3.0 {
            fail("afk-light ANSI \(i) (\(light.ansi[i])) is CR \(String(format: "%.2f", c)) on "
                 + "\(light.background) — below the WCAG 3.0 floor, i.e. illegible")
        }
    }
    if contrast(light.foreground, light.background) < 4.5 {
        fail("afk-light foreground is below WCAG AA 4.5 on its own background")
    }
}

// ---- 7. CONTROL for case 6. ----
// The dark palette on the LIGHT background must FAIL the same test — that is the entire
// reason a separate light preset is needed rather than reusing afk-dark. If a dark
// palette read as legible on white, the contrast function is not measuring contrast and
// every green assertion in case 6 is void.
//
// Guarded the same way as case 6, and for the same reason: `dark.ansi[$0]` reaches index 14,
// so a short `afk-dark` palette must fall through to case 1's diagnostic rather than trap here.
if let dark = ThemePalette.named("afk-dark"), let light = ThemePalette.named("afk-light"),
   dark.ansi.count == 16 {
    let illegible = contentSlots.filter { contrast(dark.ansi[$0], light.background) < 3.0 }
    if illegible.count < 4 {
        fail("CONTROL: only \(illegible.count) afk-dark ANSI slots are illegible on "
             + "\(light.background). Expected many. The contrast function is not measuring contrast.")
    }
}

print(bad == 0 ? "ALL-OK" : "SOME-FAILED")
SWIFT

if ! swiftc -O -o "$TMP/lightcheck" "$VALUES" "$COMMUNITY" "$CONTRAST" "$TMP/pure/main.swift" 2>"$TMP/compile.log"; then
  echo "error: $VALUES + $COMMUNITY + $CONTRAST would not compile standalone — the gate cannot run." >&2
  echo "  That file is Foundation-only on purpose so this is possible. If it now needs" >&2
  echo "  AppKit or SwiftTerm, the palettes-as-data and the live NSColor bridging have" >&2
  echo "  been re-merged and the split that made those files checkable is gone —" >&2
  echo "  that is the thing to fix, not this script." >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

# `set -uo pipefail` (`:61`) has no `-e`, so this command substitution not aborting the
# script on a nonzero exit is exactly what lets `rc` be captured below instead of the
# script dying here with no diagnostic.
out="$("$TMP/lightcheck" 2>&1)"
rc=$?
# The Swift harness always exits 0 — its LAST line is `print(bad == 0 ? "ALL-OK" :
# "SOME-FAILED")` below, never a nonzero `exit()` — so `rc` 0 and `rc` 1 are both
# ordinary outcomes distinguished by the stdout substring below, not by the exit code.
# Only `rc > 1` means the process itself died — SIGABRT, a dyld failure, a codesign
# refusal — which is an environmental failure, not "the palettes are wrong", and must
# not fall through to the `exit 1` at the bottom (PR #24 review, item 3): this script's
# own documented contract (`:52-59`) is 1 = real assertion failure, 2 = environmental.
if (( rc > 1 )); then
  echo "error: $TMP/lightcheck died (exit $rc) instead of printing ALL-OK/SOME-FAILED." >&2
  echo "  That is a harness crash, not a palette or luminance failure — environmental," >&2
  echo "  not a real gate failure. Output captured before it died:" >&2
  echo "$out" | sed 's/^/    /' >&2
  exit 2
fi

if [[ "$out" == *"ALL-OK"* ]]; then
  say "  ok  every shipped hex parses; every palette is exactly 16 colours"
  say "  ok  afk-light clears the lightChromeCutoff, so the window chrome goes .aqua"
  say "  ok  every other shipped preset stays below it — the cutoff still discriminates"
  say "  ok  luminance is gamma-expanded: white 1.0, black 0.0, #808080 ~0.21586"
  say "  ok  every preset name round-trips; classic and typos both stay nil"
  say "  ok  all 12 content slots clear WCAG 3.0 on afk-light's own background"
  say "  ok  control: afk-dark's ANSI is illegible on white, as it must be"
  echo
  echo "all light-theme cases passed (7 cases over every shipped preset)"
  exit 0
fi

echo "✗ FAIL: the palettes or luminance maths in $VALUES + $CONTRAST are wrong:" >&2
echo "$out" | sed 's/^/    /' >&2
exit 1
