//
//  check-theme-contrast-harness.swift
//  The assertions for check-theme-contrast.sh. Copied to main.swift and compiled
//  against the SHIPPED ThemeValues.swift + ThemeContrast.swift — never a copy of them.
//
//  Two files rather than one for the same reason check-git-status.sh is two files: inline,
//  the shell half and the assertions run past the repo's 350-LOC ceiling, and the rule for
//  that is to find the seam rather than shave comments.
//
//  The verdict is this program's EXIT CODE. It also prints ALL-OK, but the shell half
//  checks the status, because a harness that crashes after printing its verdict would
//  otherwise read as a green gate — the exit-code discipline is shared by all check-*.sh
//  scripts for this reason.
//

import Foundation

var failures: [String] = []
var checks = 0

func expect(_ ok: Bool, _ what: String, _ detail: String) {
    checks += 1
    if !ok { failures.append("\(what): \(detail)") }
}

func rgb(_ hex: String, _ label: String) -> RGB? {
    guard let c = RGB(hex: hex) else {
        failures.append("\(label): '\(hex)' is not parseable as #rrggbb")
        checks += 1
        return nil
    }
    checks += 1
    return c
}

// ---------------------------------------------------------------- 1. parseability
// Every hex in every shipped palette must parse. Theme.swift force-unwraps all of them
// via NSColor.fromHex, so an unparseable literal is a launch-time trap; here it is a
// failed gate instead. This is the one case that must run before anything else.
for p in ThemePalette.all {
    for (label, hex) in [("background", p.background), ("foreground", p.foreground),
                         ("cursor", p.cursor), ("selection", p.selection)] {
        _ = rgb(hex, "\(p.name).\(label)")
    }
    expect(p.ansi.count == 16, "\(p.name).ansi", "has \(p.ansi.count) entries, not 16 — "
           + "SwiftTerm's installColors silently no-ops off-16")
    for (i, hex) in p.ansi.enumerated() { _ = rgb(hex, "\(p.name).ansi[\(i)]") }
}

// ------------------------------------------------------- 2. reachability from config
// The registry and resolver assertions live in check-theme-contrast-registry.swift — moved
// there when this file went 20 lines over the 350-LOC ceiling. `expect` is passed in so the
// counters stay owned here.
checkPresetRegistry(expect)
checkClassicRepaired(expect)

// --------------------------------------------- 3. WCAG luminance against the definition
// Values computed from the WCAG 2.1 definition, not from this implementation.
//
// NOTE ON SCOPE, corrected 2026-08-03: this section used to be titled "the two luminance
// models agree" and claimed to reconcile `WCAG.luminance` with `NSColor.relativeLuminance`
// (`Theme.swift:73-83`). It never did — that type imports AppKit and cannot be linked into
// this harness, so only the pure one is checked here. The AppKit twin, which is what
// `Config.appearance` actually uses to pick light/dark chrome, remains ungated. The two
// implementations agree by inspection and nothing mechanical holds them to it.
for (hex, want) in [("#000000", 0.0), ("#FFFFFF", 1.0), ("#808080", 0.2158605),
                    ("#FF0000", 0.2126), ("#00FF00", 0.7152), ("#0000FF", 0.0722)] {
    if let c = RGB(hex: hex) {
        expect(abs(WCAG.luminance(c) - want) < 0.0005, "WCAG.luminance(\(hex))",
               "got \(WCAG.luminance(c)), want ~\(want)")
    }
}

// ------------------------------ 3b. the hand-rolled models vs EXTERNAL reference values
// Moved to check-theme-contrast-reference.swift on 2026-08-05, when reconciling PR #26's
// syntax/selection sections pushed this file 5 lines over the 350-LOC ceiling. `expect` is
// passed in so the counters stay owned here — same pattern as §2's checkPresetRegistry.
checkExternalReferenceValues(expect)

// ------------------------------------------------------ 4. APCA's loClip is real
// ANSI 0 is judged by OKLab distance, never by APCA, because APCA reports exactly 0 below
// its invisibility threshold. If that stopped being true the ANSI-0 rule below would be
// measuring the wrong thing. Assert the clip directly so the reasoning stays checked.
if let a = RGB(hex: "#19120D"), let b = RGB(hex: "#1B140F") {
    expect(APCA.lc(text: b, background: a) == 0, "APCA loClip",
           "two near-identical darks gave Lc \(APCA.lc(text: b, background: a)), expected exactly 0")
}

// ------------------------------------------------------------- 5. Umber's thresholds
// Only Umber is held to these. afk-dark, tokyo-night and afk-light are verbatim upstream
// ports (afk-light is GitHub Light Default, gated on WCAG ratios by check-light-theme.sh,
// which is what its source targeted) and
// they FAIL several of them (measured: tokyo-night's ANSI 8 is Lc 10.3, and six of its
// eight normal/bright pairs are identical) — that is recorded in ThemeValues.swift and is
// the point of the comparison, not a defect to launder by relaxing the rule for everyone.
let u = ThemePalette.umber
guard let bg = RGB(hex: u.background), let fg = RGB(hex: u.foreground),
      let cur = RGB(hex: u.cursor), let sel = RGB(hex: u.selection) else {
    print("FAIL: Umber's own base colours do not parse")
    exit(1)
}
let a = u.ansi.compactMap { RGB(hex: $0) }
guard a.count == 16 else { print("FAIL: Umber ansi did not parse to 16"); exit(1) }

// 5a. Background must keep the window's chrome DARK, checked against the live symbol —
// not a restated literal — so this assertion cannot silently drift from what
// AppConfig.appearance (Config.swift) actually compares against if the cutoff ever changes.
expect(WCAG.luminance(bg) <= WCAG.lightChromeCutoff, "Umber background",
       "luminance \(WCAG.luminance(bg)) is above WCAG.lightChromeCutoff \(WCAG.lightChromeCutoff), so the "
       + "window would adopt LIGHT chrome against a dark terminal")

// 5b. Background must actually be WARM — this is the design thesis, so it is asserted, not
// just described. OKLab b > 0 means yellow-ward; a > 0 means red-ward. A cold or neutral
// background silently turns Umber into another GitHub Dark.
let bgLab = OKLab.from(bg)
expect(bgLab.b > 0.008 && bgLab.a > 0.001, "Umber background warmth",
       "OKLab a=\(String(format: "%.4f", bgLab.a)) b=\(String(format: "%.4f", bgLab.b)) — "
       + "the background is not measurably warm")

// 5c. Body text. APCA 90 is 'preferred body'; 85 leaves room for the hex rounding.
expect(APCA.lc(text: fg, background: bg) >= 85, "Umber foreground",
       "APCA Lc \(String(format: "%.1f", APCA.lc(text: fg, background: bg))) < 85")

// 5d. ANSI 0 is a surface: visible against the background, but not a second background.
let d0 = OKLab.distance(a[0], bg)
expect(d0 >= 0.05 && d0 <= 0.14, "Umber ANSI 0",
       "dE-OK \(String(format: "%.3f", d0)) from background is outside 0.05…0.14")

// 5e. Per-slot APCA floors, by ROLE. The chromatic slots are categorical markers layered
// on an already-readable foreground, so APCA's large/headline tier (45) is the right floor,
// lifted for the ones that routinely carry whole lines. ANSI 8 is the comment colour and
// is the field's universal failure — floor 48, where every theme measured scores 0–34.
let floors: [Int: Double] = [1: 50, 2: 60, 3: 58, 4: 48, 5: 56, 6: 60, 7: 74, 8: 48,
                             9: 65, 10: 75, 11: 73, 12: 63, 13: 71, 14: 75, 15: 92]
let slotNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                 "bright black", "bright red", "bright green", "bright yellow",
                 "bright blue", "bright magenta", "bright cyan", "bright white"]
for (i, floor) in floors.sorted(by: { $0.key < $1.key }) {
    let lc = APCA.lc(text: a[i], background: bg)
    expect(lc >= floor, "Umber ANSI \(i) (\(slotNames[i]))",
           "APCA Lc \(String(format: "%.1f", lc)) < floor \(Int(floor))")
}

// 5f. Bright must be distinguishable from normal. SwiftTerm renders BOLD text from the
// bright half by default (useBrightColors), so a collapsed pair makes bold invisible —
// which is exactly what Tokyo Night, Catppuccin, Nord and Rosé Pine all ship (dE 0.000).
for i in 0..<8 {
    let de = OKLab.distance(a[i], a[i + 8])
    expect(de >= 0.085, "Umber ring \(i)/\(i + 8) (\(slotNames[i]))",
           "normal→bright dE-OK \(String(format: "%.3f", de)) < 0.085 — bold text would "
           + "be indistinguishable from plain")
    expect(OKLab.lightness(a[i + 8]) > OKLab.lightness(a[i]),
           "Umber ring \(i)/\(i + 8) direction", "the bright slot is not lighter")
}

// 5g. Colour-vision deficiency, tiered by whether a reader must tell the pair apart to
// read output CORRECTLY. Tier 1 is the load-bearing set: diff +/-, pass/fail/warn.
// The three accepted shortfalls are deliberate and argued — red/yellow/green cannot all
// clear 0.105 under deuteranopia without a ~0.21 lightness span, which washes green out
// (proved in .afk/research/theme-design-2026-08-03/solve_warm.py and rejected on the
// rendered evidence in preview2.html). They are pinned at their measured values so they
// cannot silently degrade further.
let cvdFloors: [(Int, Int, Double, String)] = [
    (1, 2, 0.105, "red/green — diff -/+, fail/pass"),
    (1, 3, 0.080, "red/yellow — accepted shortfall, see design doc"),
    (2, 3, 0.080, "green/yellow — accepted shortfall, see design doc"),
    (4, 5, 0.080, "blue/magenta"),
    (2, 6, 0.080, "green/cyan"),
    (4, 6, 0.080, "blue/cyan"),
    (1, 5, 0.080, "red/magenta"),
    (1, 4, 0.080, "red/blue"),
    (5, 6, 0.025, "magenta/cyan — tier 3, cosmetic adjacency only"),
    (3, 5, 0.050, "yellow/magenta"),
    (3, 6, 0.050, "yellow/cyan"),
    (2, 4, 0.050, "blue/green"),
]
for (x, y, floor, why) in cvdFloors {
    for off in [0, 8] {
        let w = CVD.worstDistance(a[x + off], a[y + off])
        let ring = off == 0 ? "normal" : "bright"
        expect(w >= floor, "Umber CVD \(ring) \(slotNames[x + off])/\(slotNames[y + off])",
               "worst dichromacy dE-OK \(String(format: "%.3f", w)) < \(floor) — \(why)")
    }
}

// 5h. Selection must be visible as a lift of the background without swallowing text.
// Umber's design floor only; the all-palette and user-override cases are §5l. The threshold
// is read from `SelectionPairing` rather than written here — see that type on why.
let dSel = OKLab.distance(sel, bg)
expect(dSel >= 0.08 && dSel <= 0.22, "Umber selection",
       "dE-OK \(String(format: "%.3f", dSel)) from background is outside 0.08…0.22")
expect(APCA.lc(text: fg, background: sel) >= SelectionPairing.readableFloor,
       "Umber foreground on selection",
       "APCA Lc \(String(format: "%.1f", APCA.lc(text: fg, background: sel))) < "
       + "\(Int(SelectionPairing.readableFloor)) — selected text would be hard to read")

// 5i. The cursor must be visible against the background it sits on.
expect(APCA.lc(text: cur, background: bg) >= 45, "Umber cursor",
       "APCA Lc \(String(format: "%.1f", APCA.lc(text: cur, background: bg))) < 45")

// ------------------------------------- 5j. the tab strip's DERIVED chrome, all palettes
// The document tab strip does not use theme colours directly — it derives them:
// `railBackground` is the terminal background lifted 7% toward white, and tab labels are
// the theme foreground drawn at an alpha. Until now that was the one theme-derived surface
// the gate could not reach, because `DocumentTabStrip+Drawing.swift` imports AppKit. It is
// reachable after all: alpha compositing over an opaque backdrop is arithmetic, so
// `RGB.blended`/`RGB.composited` reproduce it exactly and the result can be measured here.
//
// Asserted for ALL THREE palettes, not just umber, because this is APP CHROME — the same
// constants apply whichever theme is installed, so a failure here is the strip's fault and
// not the palette's. That is how the 0.55 inactive alpha was caught: it put inactive tab
// text at APCA Lc 37.3 under umber, 33.0 under afk-dark and 32.1 under tokyo-night — the
// least legible text anywhere in the app, and below APCA's Lc 45 floor for ANY readable
// text in all three cases. The constants below must stay in step with the shipped ones;
// `check-theme-contrast.sh` greps the drawing file to enforce that, because a harness
// testing a stale constant is worse than no harness at all.
let RAIL_LIFT = 0.07          // DocumentTabStrip+Drawing.swift railBackground
let ALPHA_ACTIVE = 0.95       // DocumentTabStrip+Drawing.swift textAlpha, active
let ALPHA_INACTIVE = 0.72     // DocumentTabStrip+Drawing.swift textAlpha, inactive
for p in ThemePalette.all {
    guard let pbg = RGB(hex: p.background), let pfg = RGB(hex: p.chromeForeground) else { continue }
    // The app lifts the rail toward WHITE on a dark background and toward BLACK on a light one
    // (`DocumentTabStrip+Drawing.swift`, contentIsDark/railBackground). Hardcoding white was
    // correct until afk-light shipped: on #FFFFFF it made rail == bg, so the ratio assertion
    // below failed for a reason that was the HARNESS's fault, not the theme's.
    // CRITICAL: contentIsDark tests NSColor.brightnessComponent < 0.5 — HSB brightness, i.e.
    // the MAX of R/G/B — NOT WCAG luminance. Reproduce that exact test, or this measures a
    // colour the app never draws.
    let isDark = max(pbg.r, max(pbg.g, pbg.b)) < 0.5
    let rail = pbg.blended(withFraction: RAIL_LIFT, toward: isDark ? .white : .black)
    // The rail must read as a shade of the terminal, not as separate chrome bolted on.
    let railRatio = WCAG.ratio(rail, pbg)
    expect(railRatio > 1.05 && railRatio < 1.45, "\(p.name) tab rail",
           "contrast vs background is \(String(format: "%.3f", railRatio)):1 — outside "
           + "1.05…1.45, so the rail reads either invisible or as a separate surface")
    // Active label: this is the tab you are reading.
    let active = pfg.composited(over: pbg, alpha: ALPHA_ACTIVE)
    expect(APCA.lc(text: active, background: pbg) >= 65, "\(p.name) active tab label",
           "APCA Lc \(String(format: "%.1f", APCA.lc(text: active, background: pbg))) < 65")
    // Inactive label: deliberately de-emphasised, but APCA's Lc 45 is the floor below
    // which text is not readable at any size, and these are 11pt labels.
    let inactive = pfg.composited(over: rail, alpha: ALPHA_INACTIVE)
    let inLc = APCA.lc(text: inactive, background: rail)
    expect(inLc >= 45, "\(p.name) inactive tab label",
           "APCA Lc \(String(format: "%.1f", inLc)) < 45 — the least legible text in the app")
    // ...and it must still be clearly weaker than the active one, or the strip stops
    // telling you which document you are looking at.
    expect(APCA.lc(text: active, background: pbg) - inLc >= 12,
           "\(p.name) active/inactive tab separation",
           "only \(String(format: "%.1f", APCA.lc(text: active, background: pbg) - inLc)) Lc "
           + "apart — the active tab is no longer distinguishable by its label")
}

// ----------------------------------------- 5k. the editor's SYNTAX roles
// Extracted to Scripts/check-theme-contrast-syntax.swift — see that file's header.
// The call stays here so the section order a reader follows is still 1…6.
checkSyntaxRoles(expect)

// ------------------------------------- 5l. the editor's SELECTION pair, all palettes
// Also in Scripts/check-theme-contrast-syntax.swift — the app-policy half of §5h, which a
// config file can break without touching a palette at all.
checkSelectionPairing(expect)

// ------------------------------------------------------------------- 6. falsification
// A gate that cannot fail proves nothing. Feed it a palette known to be bad — the xterm
// default 16 on pure black, whose ANSI 4 (#0000EE) is the canonical unreadable blue — and
// require the SAME rules to reject it. If this passes, the thresholds are not doing work.
if let black = RGB(hex: "#000000"), let badBlue = RGB(hex: "#0000EE") {
    let lc = APCA.lc(text: badBlue, background: black)
    expect(lc < 48, "falsification",
           "xterm's #0000EE on black measured Lc \(String(format: "%.1f", lc)), which PASSES "
           + "the ANSI-4 floor — the thresholds are too loose to detect the canonical "
           + "unreadable-blue case, so the other results mean nothing")
}
// And a collapsed bright pair must be caught by the ring rule.
if let c = RGB(hex: "#F7768E") {
    expect(OKLab.distance(c, c) < 0.085, "falsification (ring)",
           "an identical normal/bright pair was not rejected by the 0.085 rule")
}
// The syntax rules' own falsification lives beside them, in
// Scripts/check-theme-contrast-syntax.swift.
checkSyntaxFalsification(expect)

// ---------------------------------------------------------------------------- verdict
if failures.isEmpty {
    print("ALL-OK  \(checks) assertions passed")
    exit(0)
}
print("FAIL  \(failures.count) of \(checks) assertions failed:")
for f in failures { print("  - \(f)") }
exit(1)
