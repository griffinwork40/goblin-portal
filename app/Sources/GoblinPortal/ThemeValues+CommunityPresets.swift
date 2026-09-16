//
//  ThemeValues+CommunityPresets.swift
//  Community palette presets, split from ThemeValues.swift to respect the 350-LOC ceiling.
//
//  **Pure and view-free — Foundation only**, inheriting the constraint from the file it
//  extends. The gate (`check-theme-contrast.sh`) compiles both files together, so a UI
//  import here would break it the same way one in `ThemeValues.swift` would.
//
//  Each palette here is a verbatim port of its upstream source. The doc comment names the
//  canonical repository and maps each canonical role to its ANSI slot. Where a pair is
//  identical in both the normal and bright slots that is the upstream's design, recorded
//  faithfully rather than "fixed" — the `umber` doc comment explains why that design choice
//  makes bold text indistinguishable from plain; a port's job is to be what it claims to be.
//

import Foundation

extension ThemePalette {

    /// **Gruvbox Dark** — the "medium" contrast variant of Pavel Pertsev's retro-groove
    /// palette (https://github.com/morhetz/gruvbox). Verbatim port of the canonical 16-colour
    /// terminal mapping.
    ///
    /// Background is `bg0` (#282828), foreground is `fg1` (#ebdbb2), cursor matches
    /// foreground (gruvbox convention), selection is `bg2` (#665c54) — the standard
    /// selection surface in the gruvbox colour system.
    ///
    /// ANSI mapping follows the gruvbox spec verbatim:
    ///   0  bg0      1  red (bright)  2  green (bright)   3  yellow (bright)
    ///   4  blue (bright)  5  purple (bright)  6  aqua (bright)  7  fg4 / light gray
    ///   8  bg4 / gray     9–14  bright variants       15  fg1
    ///
    /// Like Nord and Catppuccin Mocha, gruvbox ships **identical normal and bright** chromatic
    /// ANSI pairs — that is the upstream design choice. The normal/bright blue pair, for
    /// example, is `#458588` / `#83a598` — these DO differ. Gruvbox is unusual in that its
    /// "bright" chromatic colours (#9, #10, … #14) are the brighter ring (red2, green2, …),
    /// while #1–6 are the dimmer normal ring (dark red, dark green, …). The resulting
    /// normal→bright separation is genuine and measured by `check-theme-contrast.sh`.
    static let gruvboxDark = ThemePalette(
        name: "gruvbox-dark",
        background: "#282828",   // bg0 — the characteristic gruvbox dark ground
        foreground: "#ebdbb2",   // fg1 — warm off-white, the canonical gruvbox body text
        cursor:     "#ebdbb2",   // fg1 — gruvbox uses foreground as cursor by convention
        selection:  "#665c54",   // bg2 — the gruvbox selection surface
        ansi: [
            "#282828",  //  0 black         bg0 (same as bg — surfaces, not text)
            "#cc241d",  //  1 red           dark red (normal ring)
            "#98971a",  //  2 green         dark green (normal ring)
            "#d79921",  //  3 yellow        dark yellow (normal ring)
            "#458588",  //  4 blue          dark aqua/blue (normal ring)
            "#b16286",  //  5 magenta       dark purple (normal ring)
            "#689d6a",  //  6 cyan          dark aqua (normal ring)
            "#a89984",  //  7 white         fg4 — dimmed foreground / light gray
            "#928374",  //  8 bright black  gray — the gruvbox comment colour
            "#fb4934",  //  9 bright red    red (bright ring)
            "#b8bb26",  // 10 bright green  green (bright ring)
            "#fabd2f",  // 11 bright yellow yellow (bright ring)
            "#83a598",  // 12 bright blue   aqua/blue (bright ring)
            "#d3869b",  // 13 bright magenta purple (bright ring)
            "#8ec07c",  // 14 bright cyan   aqua (bright ring)
            "#ebdbb2",  // 15 bright white  fg1 — full foreground
        ]
    )

    /// **Rosé Pine** — the base (main) variant of the Rosé Pine theme
    /// (https://rosepinetheme.com). Verbatim port of the canonical terminal colour mapping.
    ///
    /// Background is `base` (#191724), foreground is `text` (#e0def4), cursor matches
    /// foreground (Rosé Pine convention), selection is `highlight-med` (#403d52) — the
    /// standard selection surface, paired with `text` as documented in the palette spec.
    ///
    /// ANSI mapping follows the official Rosé Pine terminal spec:
    ///   0  overlay   1  love     2  pine    3  gold    4  foam    5  iris    6  rose   7  text
    ///   8  muted     9  love    10  pine   11  gold   12  foam   13  iris   14  rose  15  text
    ///
    /// Like Tokyo Night and Catppuccin Mocha, Rosé Pine ships **identical normal and bright**
    /// chromatic ANSI pairs (e.g. #1 love == #9 love, #2 pine == #10 pine). That is the
    /// upstream design, ported faithfully. The `umber` doc comment explains what this means
    /// for bold text; it is not a defect to repair in a port.
    static let rosePine = ThemePalette(
        name: "rose-pine",
        background: "#191724",   // base — deep plum-black, the Rosé Pine ground
        foreground: "#e0def4",   // text — soft lavender-white body text
        cursor:     "#e0def4",   // text — Rosé Pine uses foreground as cursor
        selection:  "#403d52",   // highlight-med — the spec's selection background
        ansi: [
            "#26233a",  //  0 black         overlay — a lifted surface, not a text colour
            "#eb6f92",  //  1 red           love — warm rose
            "#31748f",  //  2 green         pine — muted teal-green
            "#f6c177",  //  3 yellow        gold — warm amber
            "#9ccfd8",  //  4 blue          foam — soft teal-blue
            "#c4a7e7",  //  5 magenta       iris — lavender-purple
            "#ebbcba",  //  6 cyan          rose — warm pink (Rosé Pine maps rose to cyan)
            "#e0def4",  //  7 white         text — full foreground
            "#6e6a86",  //  8 bright black  muted — the Rosé Pine comment colour
            "#eb6f92",  //  9 bright red    love (same as normal — upstream spec)
            "#31748f",  // 10 bright green  pine (same as normal — upstream spec)
            "#f6c177",  // 11 bright yellow gold (same as normal — upstream spec)
            "#9ccfd8",  // 12 bright blue   foam (same as normal — upstream spec)
            "#c4a7e7",  // 13 bright magenta iris (same as normal — upstream spec)
            "#ebbcba",  // 14 bright cyan   rose (same as normal — upstream spec)
            "#e0def4",  // 15 bright white  text (same as normal — upstream spec)
        ]
    )
}
