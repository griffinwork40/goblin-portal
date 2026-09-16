//
//  ThemeValues.swift
//  The shipped palettes, as hex strings, and nothing else.
//
//  **Pure and view-free — Foundation only, on purpose.** This is the half of theming
//  that `check-theme-contrast.sh` can compile standalone, which is the repo's only
//  mechanical gate (see `GitStatus.swift` and `Renderer.swift` for the same trick and
//  the same reason). `Theme.swift` imports AppKit *and* SwiftTerm, so a palette living
//  there is unreachable by any check — and a palette is exactly the kind of thing that
//  wants checking, because "is this legible" is a number and a number nobody computed
//  is a taste claim wearing a lab coat.
//
//  Why hex strings rather than parsed colours: different engines want the same palette in
//  different shapes — SwiftTerm takes a typed `SwiftTerm.Color`, others take a plain
//  `String` (see `NSColor.hexString`'s note in `Theme.swift`). Hex is the common ancestor
//  of both, it is what every upstream theme publishes, and it is what a gate can assert on
//  without linking a UI framework.
//
//  The OKLCH triple each colour was derived from is recorded in the comment beside it.
//  That is the actual design decision; the hex is a rendering of it. Full derivation,
//  the measurement tooling and the rejected alternatives are in
//  `.afk/research/theme-design-2026-08-03/`.
//

import Foundation

/// A 16-colour ANSI palette plus background/foreground/cursor, held as `#rrggbb`.
///
/// Deliberately a *value* with no behaviour: `Theme` (AppKit) converts one of these
/// into `NSColor`s, and `ThemeContrast` (pure) measures one. Neither concern belongs
/// here, so that adding a preset stays a one-line edit that cannot break either.
struct ThemePalette {
    let name: String
    let background: String
    let foreground: String
    let cursor: String
    /// The selection background. Consumed by the **editor** since 2026-08-03
    /// (`FileViewerPane+Document.swift`), and still not by the terminal engine —
    /// SwiftTerm can express it (`TerminalView.selectedTextBackgroundColor`) but
    /// is not told. That half of the gap stands, and the reason it went unnoticed for
    /// so long is worth keeping: the value was measured here from the start but `Theme`
    /// had no matching field, so it never crossed the AppKit bridge and no consumer
    /// could have read it even if one had tried.
    let selection: String
    /// Exactly 16: 8 normal then 8 bright. SwiftTerm's `installColors` silently does
    /// nothing if the array is not 16 long, so `Config` validates before `Theme` builds.
    let ansi: [String]

    /// Text colour for document chrome. Normally the terminal foreground; Classic Repaired
    /// deliberately keeps body text quiet, so its ANSI white supplies readable 11pt labels
    /// without brightening every terminal glyph to satisfy a tab-strip constraint.
    var chromeForeground: String { name == "classic-repaired" ? ansi[7] : foreground }
}

extension ThemePalette {
    /// **Umber** — the theme designed for this app, and the only one here that was
    /// measured rather than transcribed.
    ///
    /// Three things make it different from the field, each verified by
    /// `check-theme-contrast.sh` rather than asserted:
    ///
    /// 1. **The base is warm.** OKLCH hue 56 (raw-umber earth pigment, which is what
    ///    the app is named after) at chroma 0.016 — enough to read warm beside macOS's
    ///    cool sidebar material, low enough not to read brown. Every widely-used dark
    ///    theme measured sits at hue 219–291 (cold) or at chroma 0.000 (neutral grey);
    ///    gruvbox looks warm and measures `#282828`, a pure neutral. The niche is empty.
    ///
    /// 2. **ANSI 8 is legible.** It is the colour nearly every tool uses for de-emphasised
    ///    output — compiler progress, timings, paths — and every theme measured leaves it
    ///    unreadable: APCA Lc 0.0 for Solarized Dark, 10.3 for Tokyo Night and Nord, 13.1
    ///    for this repo's own afk-dark, against a floor of 45. Goblin Portal's is 51.5. For a
    ///    terminal whose job is hosting a coding agent's output, this is the single
    ///    biggest legibility win available.
    ///
    /// 3. **Bright is actually brighter.** Tokyo Night, Catppuccin, Nord and Rosé Pine
    ///    all ship *identical* values in the normal and bright chromatic slots (measured
    ///    dE-OK 0.000), so bold text — which SwiftTerm renders from the bright half by
    ///    default (`useBrightColors`) — is indistinguishable from plain. Goblin Portal's
    ///    smallest normal→bright separation is 0.088.
    ///
    /// Lightness is *staggered* across the ring rather than constant. That is not
    /// sloppiness: constant OKLCH lightness and constant readability are mutually
    /// exclusive in sRGB, because APCA weights luminance per channel (R .213, G .715,
    /// B .072), so a saturated red at a green's lightness is far less readable. The
    /// stagger is also what keeps red and green apart for a red-green colour-blind
    /// reader, where hue is gone and lightness is the only surviving signal.
    static let umber = ThemePalette(
        name: "umber",
        background: "#19120D",   // OKLCH 0.190 0.016  56 — warm umber-black
        foreground: "#E5DFD6",   // OKLCH 0.905 0.014  80 — warm paper, Lc 87.0
        cursor:     "#FF9B5A",   // OKLCH 0.780 0.145  52 — umber-orange caret
        selection:  "#453021",   // OKLCH 0.330 0.040  56 — a warm lift of the background
        ansi: [
            "#342C26",  //  0 black          0.300 0.016  56 — a surface, not text
            "#EF7F74",  //  1 red            0.720 0.140  27
            "#8AE49E",  //  2 green          0.844 0.131 150
            "#D7AA32",  //  3 yellow         0.759 0.140  87
            "#739EF0",  //  4 blue           0.702 0.130 262
            "#FFACE9",  //  5 magenta        0.843 0.123 337
            "#42CBC8",  //  6 cyan           0.770 0.115 193
            "#D3CDC5",  //  7 white          0.851 0.013  74
            "#AAA19B",  //  8 bright black   0.715 0.014  56 — the comment colour
            "#FDAAA0",  //  9 bright red     0.816 0.100  27
            "#B4FCC3",  // 10 bright green   0.929 0.106 150
            "#F7D179",  // 11 bright yellow  0.875 0.115  87
            "#9DBEFC",  // 12 bright blue    0.800 0.096 262
            "#FFD2F2",  // 13 bright magenta 0.912 0.078 337
            "#80E5E2",  // 14 bright cyan    0.860 0.095 193
            "#F9F6F2",  // 15 bright white   0.974 0.006  74
        ]
    )

    /// **Classic Repaired** — Terminal.app Basic's structure with only its demonstrable
    /// defects repaired. It keeps the true-black ground, quiet `#8A8A8A` body text and
    /// saturated ANSI ring that make `classic` attractive, but raises blue out of the
    /// canonical-unreadable range and restores a visible normal/bright blue step.
    ///
    /// Every other chromatic ANSI value is SwiftTerm's `terminalAppColors` verbatim
    /// (`Colors.swift:91-108`); bright white is lifted to restore its collapsed pair too.
    /// The two blues were derived with the shipped OKLab/APCA
    /// implementation: ANSI 4 reaches Lc 45.1, ANSI 12 reaches 58.9, and their dE-OK
    /// separation is 0.092. `check-theme-contrast-repair.swift` pins those properties.
    static let classicRepaired = ThemePalette(
        name: "classic-repaired",
        background: "#000000", foreground: "#8A8A8A", cursor: "#A1A8FD",
        selection: "#262952",
        ansi: [
            "#000000", "#C23621", "#25BC24", "#ADAD27",
            "#818AFC", "#D338D3", "#33BBC8", "#CBCCCD",
            "#818383", "#FC391F", "#31E722", "#EAEC23",
            "#A1A8FD", "#F935F8", "#14F0F0", "#FFFFFF",
        ]
    )

    /// AFK Dark — a 1:1 port of the `terminal` block of `themes/terax/afk-dark.terax-theme`
    /// in the agent-afk repo: a GitHub-Dark skeleton with that project's warm-orange
    /// accent (#E67E4C). Kept verbatim, including its measured weaknesses (ANSI 8 at
    /// Lc 13.1, and normal/bright pairs that are identical in six of eight slots), because
    /// a preset's job is to be the thing it claims to be — silently "fixing" a port makes
    /// it a different theme wearing the same name.
    static let afkDark = ThemePalette(
        name: "afk-dark",
        background: "#0D1117", foreground: "#C9D1D9", cursor: "#E67E4C",
        selection: "#264F78",
        ansi: [
            "#161B22", "#F85149", "#9CB04A", "#E5C07B",
            "#5BA8FF", "#9F7CE0", "#56B5A8", "#C9D1D9",
            "#484F58", "#F85149", "#A8E060", "#E67E4C",
            "#5BA8FF", "#F08AC4", "#5FE0C0", "#ECEFF4",
        ]
    )

    /// **AFK Light** — `"preset": "afk-light"`, and the only light palette here.
    ///
    /// A verbatim port of GitHub's Light Default, so it is NOT held to umber's floors
    /// below — the same exemption `afkDark` and `tokyoNight` get, and for the same
    /// reason: measuring someone else's published palette against a standard it was
    /// never designed for tells you about them, not about this app. `check-light-theme.sh`
    /// gates it on WCAG ratios (3.0/4.5), which is what its source targeted.
    ///
    /// Its real job is structural: it is the first shipped preset whose background sits
    /// ABOVE `WCAG.lightChromeCutoff` (0.179, `ThemeContrast.swift`), so it is the only thing that exercises
    /// `AppConfig.appearance` returning `.aqua` and the whole light-chrome derivation
    /// underneath it. Before this existed that path was written but never run.
    ///
    /// `selection` is the one value NOT copied verbatim: GitHub publishes its selection
    /// as `#0969DA26` — a 15%-alpha blue — and `ThemePalette.selection` is opaque, so
    /// this is Primer's `blue.2` (`#B6E3FF`), the flattened equivalent of that tint over
    /// a white background. Noted because it is the single hex here that is derived
    /// rather than ported.
    static let afkLight = ThemePalette(
        name: "afk-light",
        background: "#FFFFFF", foreground: "#1F2328", cursor: "#0969DA",
        selection: "#B6E3FF",
        ansi: [
            "#24292F", "#CF222E", "#116329", "#4D2D00",
            "#0969DA", "#8250DF", "#1B7C83", "#6E7781",
            "#57606A", "#A40E26", "#1A7F37", "#633C01",
            "#218BFF", "#A475F9", "#3192AA", "#8C959F",
        ]
    )

    /// Tokyo Night — the v0.1 default, kept as a preset. Also transcribed verbatim.
    static let tokyoNight = ThemePalette(
        name: "tokyo-night",
        background: "#1A1B26", foreground: "#C0CAF5", cursor: "#C0CAF5",
        selection: "#283457",
        ansi: [
            "#15161E", "#F7768E", "#9ECE6A", "#E0AF68",
            "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
            "#414868", "#F7768E", "#9ECE6A", "#E0AF68",
            "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5",
        ]
    )

    /// **Catppuccin Mocha** — the most-starred Catppuccin flavour and one of the most-used
    /// dark themes in the community. Verbatim port of the official Mocha terminal palette
    /// (https://github.com/catppuccin/catppuccin). Background is `base` (#1e1e2e), foreground
    /// is `text` (#cdd6f4), cursor is `rosewater` (#f5e0dc), selection is `surface1` (#45475a).
    ///
    /// Transcribed verbatim — including the documented weakness that **all eight chromatic
    /// normal/bright ANSI pairs are identical** (dE-OK 0.000, just like Tokyo Night and Nord).
    /// That is recorded in ThemeValues.swift's `umber` doc comment and is a property of the
    /// upstream palette, not a defect to fix here. `check-theme-contrast.sh` does not hold
    /// community ports to Goblin Portal's ring-separation floor — only Umber is measured against it.
    static let catppuccinMocha = ThemePalette(
        name: "catppuccin-mocha",
        background: "#1e1e2e",   // base
        foreground: "#cdd6f4",   // text
        cursor:     "#f5e0dc",   // rosewater
        selection:  "#45475a",   // surface1 — an opaque lift of the background
        ansi: [
            "#45475a",  //  0 black         surface1
            "#f38ba8",  //  1 red           red
            "#a6e3a1",  //  2 green         green
            "#f9e2af",  //  3 yellow        yellow
            "#89b4fa",  //  4 blue          blue
            "#f5c2e7",  //  5 magenta       pink
            "#94e2d5",  //  6 cyan          teal
            "#bac2de",  //  7 white         subtext1
            "#585b70",  //  8 bright black  surface2
            "#f38ba8",  //  9 bright red    red (same as normal — upstream spec)
            "#a6e3a1",  // 10 bright green  green (same as normal — upstream spec)
            "#f9e2af",  // 11 bright yellow yellow (same as normal — upstream spec)
            "#89b4fa",  // 12 bright blue   blue (same as normal — upstream spec)
            "#f5c2e7",  // 13 bright magenta pink (same as normal — upstream spec)
            "#94e2d5",  // 14 bright cyan   teal (same as normal — upstream spec)
            "#a6adc8",  // 15 bright white  subtext0
        ]
    )

    /// **Nord** — the Arctic, north-bluish palette by Arctic Ice Studio. Verbatim port of
    /// the official Nord terminal colour mapping (https://www.nordtheme.com). Background is
    /// `nord0` (#2e3440), foreground is `nord4` (#d8dee9), cursor is `nord4`, selection is
    /// `nord2` (#434c5e). The Frost and Aurora colour groups fill the ANSI ring.
    ///
    /// Like Catppuccin Mocha, Nord ships **identical chromatic normal/bright pairs** in
    /// several slots — that is the upstream design, transcribed faithfully here. The comment-
    /// colour weakness (ANSI 8 is `nord3` #4c566a, APCA Lc ~10.3) is noted in `umber`'s
    /// doc comment as the field's universal failure; it is NOT fixed here because a port's
    /// job is to be the thing it claims to be.
    static let nord = ThemePalette(
        name: "nord",
        background: "#2e3440",   // nord0 — Polar Night origin
        foreground: "#d8dee9",   // nord4 — Snow Storm origin
        cursor:     "#d8dee9",   // nord4
        selection:  "#434c5e",   // nord2 — active-line/selection shade
        ansi: [
            "#3b4252",  //  0 black         nord1 — elevated dark
            "#bf616a",  //  1 red           nord11 — Aurora red
            "#a3be8c",  //  2 green         nord14 — Aurora green
            "#ebcb8b",  //  3 yellow        nord13 — Aurora yellow
            "#81a1c1",  //  4 blue          nord9 — Frost blue
            "#b48ead",  //  5 magenta       nord15 — Aurora purple
            "#88c0d0",  //  6 cyan          nord8 — Frost primary accent
            "#e5e9f0",  //  7 white         nord5 — Snow Storm mid
            "#4c566a",  //  8 bright black  nord3 — comment colour
            "#bf616a",  //  9 bright red    nord11 (same as normal — upstream spec)
            "#a3be8c",  // 10 bright green  nord14 (same as normal — upstream spec)
            "#ebcb8b",  // 11 bright yellow nord13 (same as normal — upstream spec)
            "#81a1c1",  // 12 bright blue   nord9 (same as normal — upstream spec)
            "#b48ead",  // 13 bright magenta nord15 (same as normal — upstream spec)
            "#8fbcbb",  // 14 bright cyan   nord7 — calmer Frost teal, distinct from nord8
            "#eceff4",  // 15 bright white  nord6 — Snow Storm brightest
        ]
    )

    /// **Dracula** — the popular dark theme by Zeno Rocha. Verbatim port of the official
    /// Dracula terminal colour mapping (https://draculatheme.com). Background is #282a36,
    /// foreground is #f8f8f2, cursor is #f8f8f2, selection is #44475a (the official
    /// "Selection" colour from the Dracula spec).
    ///
    /// Dracula does provide distinct bright variants for most slots, so its ring separation
    /// is better than Catppuccin Mocha or Nord. The comment colour ANSI 8 (`#6272a4`) is at
    /// APCA Lc ~36.5 — below Goblin Portal's 48 floor but above the field's typical 10–13 range.
    static let dracula = ThemePalette(
        name: "dracula",
        background: "#282a36",   // Background
        foreground: "#f8f8f2",   // Foreground
        cursor:     "#f8f8f2",   // Foreground (Dracula uses fg as cursor)
        selection:  "#44475a",   // Selection
        ansi: [
            "#21222c",  //  0 black         slightly deeper than bg
            "#ff5555",  //  1 red           Red
            "#50fa7b",  //  2 green         Green
            "#f1fa8c",  //  3 yellow        Yellow
            "#bd93f9",  //  4 blue          Purple (maps to ANSI blue)
            "#ff79c6",  //  5 magenta       Pink
            "#8be9fd",  //  6 cyan          Cyan
            "#f8f8f2",  //  7 white         Foreground
            "#6272a4",  //  8 bright black  Comment / current-line
            "#ff6e6e",  //  9 bright red    brighter Red
            "#69ff94",  // 10 bright green  brighter Green
            "#ffffa5",  // 11 bright yellow brighter Yellow
            "#d6acff",  // 12 bright blue   brighter Purple
            "#ff92df",  // 13 bright magenta brighter Pink
            "#a4ffff",  // 14 bright cyan   brighter Cyan
            "#ffffff",  // 15 bright white  pure white
        ]
    )

    /// Every shipped palette, so the gate can iterate them without a second list to
    /// forget to update. `preset(named:)` in `Theme.swift` resolves config strings; this
    /// is the enumeration, and the two must not drift — `check-theme-contrast.sh`
    /// asserts that every name here is reachable from config.
    static let all: [ThemePalette] = [.umber, .classicRepaired, .afkDark, .tokyoNight, .afkLight,
                                       .catppuccinMocha, .nord, .dracula, .gruvboxDark, .rosePine]

    /// Resolve a `"preset"` string to a palette. Case-insensitive, reads `_` as `-`, and
    /// accepts the hyphen-stripped spelling (`afkdark`), which is what users actually type.
    ///
    /// This lives in the pure file rather than as a `switch` in `Theme.swift` deliberately:
    /// `Theme.swift` imports AppKit *and* SwiftTerm, so a mapping there is unreachable by
    /// any gate and could only be checked by grepping the source for `case` lines — a proxy
    /// that passes whenever the spelling is present and says nothing about what it returns.
    /// Here both gates call the real resolver. It also removes the second list: `all` is now
    /// the only place a palette is registered, so a preset cannot exist while being
    /// unreachable from config, which was previously a drift the gate could only approximate.
    ///
    /// `"classic"` is deliberately absent and must resolve to nil — it means "install
    /// nothing and let the engine's own defaults stand". A typo also yields nil; the two are
    /// told apart one layer up in `AppConfig.resolveTheme` (`Config+Theme.swift`), where
    /// classic stays nil and a typo warns and falls back to `classic-repaired`.
    static func named(_ raw: String) -> ThemePalette? {
        let key = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        return all.first { $0.name == key || $0.name.replacingOccurrences(of: "-", with: "") == key }
    }

    /// The canonical spellings, for the fail-soft warning in `AppConfig.resolveTheme`.
    /// `classic` is appended by hand because it is the one accepted value resolving to no
    /// palette at all — a user who typo'd needs to see it listed.
    static var configNames: [String] { all.map(\.name) + ["classic"] }
}
