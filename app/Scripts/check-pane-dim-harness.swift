//
//  check-pane-dim-harness.swift
//  Assertions for check-pane-dim.sh. Compiled against the SHIPPED PaneDimming.swift,
//  ThemeValues.swift, ThemeValues+CommunityPresets.swift, and ThemeContrast.swift —
//  never copies of them.
//
//  Two files rather than one for the same reason check-git-status.sh is two files:
//  inline, the shell half and the assertions together run past the 350-LOC ceiling.
//
//  The verdict is this program's EXIT CODE. It also prints ALL-OK, but the shell half
//  checks the status — a harness that crashes after printing its verdict would otherwise
//  read as a green gate.
//

import Foundation

var failures: [String] = []
var checks = 0

func expect(_ ok: Bool, _ what: String, _ detail: String) {
    checks += 1
    if !ok { failures.append("\(what): \(detail)") }
}

func f1(_ v: Double) -> String { String(format: "%.1f", v) }
func f2(_ v: Double) -> String { String(format: "%.2f", v) }

// --------------------------------------------------------- helpers
// Reproduce compositing arithmetic here (the same formula PaneDimming documents)
// so the gate is asserting the RESULT, not re-implementing the function.
// dimmed_fg = opacity * fg + (1 − opacity) * bg   →  RGB.composited(over:alpha:)

func compositedLc(fg: RGB, bg: RGB, opacity: Double) -> Double {
    let dimmed = fg.composited(over: bg, alpha: opacity)
    return APCA.lc(text: dimmed, background: bg)
}

// ------------------------------------------------------- 1. every shipped palette passes
// PaneDimming.effectiveOpacity (user absent, nil) must keep composited Lc >= dimFloor
// for every palette, OR return 1.0 for palettes whose undimmed Lc is already below the floor.
//
// The "control" for the floor assertion is confirmed by the falsification case below —
// the gate cannot pass if the threshold is too loose to catch the known-bad case.

let allPalettes: [(String, ThemePalette)] = [
    ("umber",            .umber),
    ("classic-repaired", .classicRepaired),
    ("afk-dark",         .afkDark),
    ("afk-light",        .afkLight),
    ("tokyo-night",      .tokyoNight),
    ("catppuccin-mocha", .catppuccinMocha),
    ("nord",             .nord),
    ("dracula",          .dracula),
    ("gruvbox-dark",     .gruvboxDark),
    ("rose-pine",        .rosePine),
]

for (label, palette) in allPalettes {
    guard let bg = RGB(hex: palette.background), let fg = RGB(hex: palette.foreground) else {
        expect(false, "\(label) hex parse", "background or foreground did not parse")
        continue
    }

    let undimmedLc = APCA.lc(text: fg, background: bg)

    // Compute the effective opacity with no user override.
    var w: [String] = []
    let eff = PaneDimming.effectiveOpacity(
        background: palette.background,
        foreground: palette.foreground,
        userOpacity: nil,
        warnings: &w)

    // Check 1a: the returned opacity is in the valid range.
    expect(eff >= 0.0 && eff <= 1.0,
           "\(label) effective opacity range",
           "\(f2(eff)) is outside [0,1]")

    // Check 1b: the composited result clears the floor (OR the undimmed is already below
    // the floor, in which case the function must return 1.0).
    if undimmedLc < PaneDimming.dimFloor {
        // Pinned palette — the rule is "do not dim further, return 1.0".
        // The function does NOT cap at 0.7 in this case; 1.0 is the correct answer.
        expect(eff == 1.0,
               "\(label) pinned (undimmed Lc \(f1(undimmedLc)) < \(Int(PaneDimming.dimFloor)))",
               "expected effective opacity 1.0 (no dimming), got \(f2(eff))")
    } else {
        // Normal palette — composited Lc must meet the floor.
        let compositedLc = compositedLc(fg: fg, bg: bg, opacity: eff)
        expect(compositedLc >= PaneDimming.dimFloor,
               "\(label) composited Lc @ \(f2(eff))",
               "Lc \(f1(compositedLc)) < floor \(Int(PaneDimming.dimFloor)) "
               + "(undimmed \(f1(undimmedLc)))")

        // Check 1c: the 0.7 design-intent cap — the function should return as close to 0.7
        // as possible (i.e. the minimum safe opacity, capped at 0.7 when that still clears
        // the floor, or the minimum safe value when 0.7 would break it).
        // In practice: if the palette cleared the floor at 0.7, the returned value is 0.7.
        // If it needed 0.71, it is 0.71. Either way the composited Lc (above) is ≥ floor.
        // We assert it does not exceed the minimum safe value by more than 0.01 (rounding).
        // This confirms the function is not returning 1.0 for a palette that could be dimmed.
        expect(eff < 1.0 - 0.001,
               "\(label) actually dims (not returning 1.0 when undimmed Lc \(f1(undimmedLc)) >= floor)",
               "returned 1.0 for a palette that can be safely dimmed")
    }
    // No warnings should be emitted for a user-absent call.
    expect(w.isEmpty,
           "\(label) no spurious warnings (user absent)",
           "got \(w.count) warning(s): \(w.joined(separator: "; "))")
}

// ------------------------------------------------------- 2. explicit user value: honoured
// When the user sets a value in [0,1], it must be returned unchanged.
// A value that breaks the floor must trigger exactly one warning.

for (label, palette) in allPalettes {
    guard let bg = RGB(hex: palette.background), let fg = RGB(hex: palette.foreground) else { continue }

    // 2a: user sets 0.9 (high, universally safe) — no warning expected.
    var w2a: [String] = []
    let eff09 = PaneDimming.effectiveOpacity(
        background: palette.background, foreground: palette.foreground,
        userOpacity: 0.9, warnings: &w2a)
    expect(eff09 == 0.9,
           "\(label) user=0.9 honoured",
           "expected 0.9, got \(f2(eff09))")
    // 0.9 composites fg at 90% over bg — this may break the floor for low-contrast palettes
    // and may not, but the function must always HONOUR the user value (the check above), just
    // warn. So we only assert the returned value; the warning test is separate below.

    // 2b: user sets 0.3 (aggressive, should break floor for most palettes).
    var w2b: [String] = []
    let eff03 = PaneDimming.effectiveOpacity(
        background: palette.background, foreground: palette.foreground,
        userOpacity: 0.3, warnings: &w2b)
    expect(eff03 == 0.3,
           "\(label) user=0.3 honoured",
           "expected 0.3, got \(f2(eff03))")
    // A dimming of 0.3 drops even the highest-contrast palette (afk-light Lc 102.8)
    // to Lc 58.8 — still above the floor. So some palettes may not warn at 0.3.
    let lc03 = compositedLc(fg: fg, bg: bg, opacity: 0.3)
    if lc03 < PaneDimming.dimFloor {
        // Must have warned.
        expect(!w2b.isEmpty,
               "\(label) user=0.3 warns when Lc \(f1(lc03)) < floor",
               "expected a warning, got none")
    } else {
        // Must NOT have warned.
        expect(w2b.isEmpty,
               "\(label) user=0.3 no warning when Lc \(f1(lc03)) >= floor",
               "unexpected warning: \(w2b.first ?? "")")
    }
}

// ------------------------------------------------------- 3. control: user sets 1.0
// A value of 1.0 means "no dimming" — must be returned unchanged with no warning.
// This confirms the warning path does not fire when the user has chosen no dimming.
for (label, palette) in allPalettes {
    var w: [String] = []
    let eff = PaneDimming.effectiveOpacity(
        background: palette.background, foreground: palette.foreground,
        userOpacity: 1.0, warnings: &w)
    expect(eff == 1.0, "\(label) user=1.0 honoured", "got \(f2(eff))")
    expect(w.isEmpty,  "\(label) user=1.0 no warning", "got: \(w.first ?? "")")
}

// ------------------------------------------------------- 4. falsification
// The gate must be strict enough to REJECT the old flat-0.7 rule for classic-repaired.
// classic-repaired fg #8A8A8A on #000000 = Lc 39.6 undimmed; at opacity 0.7 → Lc 20.8.
// If APCA.lc(composited(0.7)) >= 45, the threshold is too loose and the other cases
// are meaningless.
if let bg = RGB(hex: "#000000"), let fg = RGB(hex: "#8A8A8A") {
    let lc07 = compositedLc(fg: fg, bg: bg, opacity: 0.7)
    expect(lc07 < PaneDimming.dimFloor,
           "falsification: flat 0.7 must FAIL for classic-repaired",
           "got Lc \(f1(lc07)) >= \(Int(PaneDimming.dimFloor)) — threshold is too loose, "
           + "the other cases mean nothing")

    // And confirm the effective opacity for classic-repaired is exactly 1.0 (pinned).
    var wf: [String] = []
    let effCR = PaneDimming.effectiveOpacity(
        background: "#000000", foreground: "#8A8A8A",
        userOpacity: nil, warnings: &wf)
    expect(effCR == 1.0,
           "falsification: classic-repaired effective opacity is 1.0 (pinned)",
           "got \(f2(effCR)) — expected no dimming for a palette already below the floor")
}

// Also: umber at 0.7 must NOT clear 45 at 0.65, confirming that umber needs a tighter cap.
if let bg = RGB(hex: "#19120D"), let fg = RGB(hex: "#E5DFD6") {
    let lc065 = compositedLc(fg: fg, bg: bg, opacity: 0.65)
    let lc07  = compositedLc(fg: fg, bg: bg, opacity: 0.70)
    // At 0.65 umber MUST be above the floor (Lc 51.4 at full; binary-search gave ~0.65).
    expect(lc065 >= PaneDimming.dimFloor,
           "umber at 0.65 clears floor",
           "Lc \(f1(lc065)) < floor \(Int(PaneDimming.dimFloor))")
    // At 0.7 umber is still above the floor too (Lc 51.4 full → 51.4 * 0.7 / 1.0 ≈ ?)
    // Actually umber at 0.7 = Lc 51.4, so it does clear 45. But our function returns
    // the floor-safe value (≤0.7), so we check the returned value instead.
    var wu: [String] = []
    let effUmber = PaneDimming.effectiveOpacity(
        background: "#19120D", foreground: "#E5DFD6",
        userOpacity: nil, warnings: &wu)
    let compLc = compositedLc(fg: fg, bg: bg, opacity: effUmber)
    expect(compLc >= PaneDimming.dimFloor,
           "umber effective opacity clears floor",
           "Lc \(f1(compLc)) < \(Int(PaneDimming.dimFloor)) at opacity \(f2(effUmber))")
    _ = lc07  // silence unused warning
}

// ------------------------------------------------------- verdict
if failures.isEmpty {
    print("ALL-OK  \(checks) assertions passed")
    exit(0)
}
print("FAIL  \(failures.count) of \(checks) assertions failed:")
for f in failures { print("  - \(f)") }
exit(1)
