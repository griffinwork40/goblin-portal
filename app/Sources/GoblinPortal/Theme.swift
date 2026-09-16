//
//  Theme.swift
//  Hex colour parsing, and the AppKit half of a theme.
//
//  The palettes themselves are NOT here any more — they are pure data in
//  `ThemeValues.swift`, along with the name resolver, while the WCAG luminance
//  formula lives in `ThemeContrast.swift`. This file turns that data into live `NSColor` and
//  `SwiftTerm.Color`. The split is forced by verification: this file imports
//  AppKit *and* SwiftTerm, so `swiftc Sources/GoblinPortal/Theme.swift` alone exits 1 on
//  `no such module 'SwiftTerm'` and nothing in it has ever been gateable, while
//  `ThemeValues.swift` and `ThemeContrast.swift` are Foundation-only and BOTH
//  `check-theme-contrast.sh` and `check-light-theme.sh` compile them directly.
//  Same decision as `Renderer.swift` / `TerminalPane+Renderer.swift`: the pure
//  decision is checkable, the live action is not, so they live apart.
//
//  Its own file because this is the only *pure value* layer in the config path:
//  `NSColor.fromHex` and the presets have no UserDefaults, no filesystem and
//  no AppConfig behind them, so they are the one part of theming that can be read
//  and judged without holding the loader in context. `relativeLuminance` and
//  `asSwiftTermColor` live here rather than next to their callers because they are
//  colour-space conversions on `NSColor` with two consumers each, across files:
//  `TerminalPane.apply(config:)` installs the palette and logs bg luminance
//  (`TerminalPane.swift:86,111`), while `AppConfig.appearance` derives the window's
//  light/dark chrome from it (`Config+Chrome.swift`).
//

import AppKit
import SwiftTerm

// MARK: - Hex colors

extension NSColor {
    /// Parse `#rrggbb` / `rrggbb` (and the 3-digit shorthand). Returns nil on
    /// anything unparseable so a typo in config degrades to the default rather
    /// than crashing the terminal.
    static func fromHex(_ raw: String) -> NSColor? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xff) / 255.0,
            green: CGFloat((v >> 8) & 0xff) / 255.0,
            blue: CGFloat(v & 0xff) / 255.0,
            alpha: 1.0
        )
    }

    /// The inverse of `fromHex`, as `#rrggbb`.
    ///
    /// Exists because some engines take colours as strings rather than typed values,
    /// while SwiftTerm takes a typed `SwiftTerm.Color` (what `asSwiftTermColor` below
    /// is for). Both conversions belong here beside the parsing rather than in whichever
    /// pane needed one first, so neither engine's pane has to reimplement hex formatting.
    ///
    /// Converted to sRGB first for the same reason the other two conversions do it: the
    /// no-theme fallback is `NSColor.black`, which lives in a generic grey colour space
    /// where `.redComponent` traps rather than returning 0.
    ///
    /// Emitted WITH the leading `#`. The prefixed form is chosen because it is unambiguous
    /// and round-trips through `fromHex` above without any normalisation step.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// WCAG 2.1 relative luminance, 0…1. Used to decide whether the window's
    /// system chrome (sidebar, titlebar, scrollers) should render dark or light.
    ///
    /// Converted to sRGB first for the same reason `asSwiftTermColor` does it: the
    /// no-theme fallback is `NSColor.black`, which lives in a generic *grey* colour
    /// space, and asking a grey colour for `.redComponent` traps rather than
    /// returning 0.
    ///
    /// The maths itself is `WCAG.luminance` (`ThemeContrast.swift`) and not inlined here,
    /// so there is exactly one implementation of the formula and both gates can compile
    /// it. This wrapper is the sRGB conversion and nothing else.
    var relativeLuminance: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        return CGFloat(WCAG.luminance(
            red: Double(c.redComponent),
            green: Double(c.greenComponent),
            blue: Double(c.blueComponent)))
    }

    /// SwiftTerm's palette type wants 16-bit components.
    var asSwiftTermColor: SwiftTerm.Color {
        let c = usingColorSpace(.sRGB) ?? self
        return SwiftTerm.Color(
            red: UInt16(c.redComponent * 65535),
            green: UInt16(c.greenComponent * 65535),
            blue: UInt16(c.blueComponent * 65535)
        )
    }
}

// MARK: - Theme

/// A 16-colour ANSI palette plus background/foreground/cursor.
struct Theme {
    var background: NSColor
    var foreground: NSColor
    /// Foreground for AppKit chrome; may be brighter than terminal body text when a palette
    /// deliberately reserves the latter as a quiet layer (`ThemePalette.chromeForeground`).
    var chromeForeground: NSColor
    var cursor: NSColor
    /// The selection background.
    ///
    /// Added 2026-08-03, and its absence until then is the more interesting half: the value
    /// existed in `ThemePalette` from the day the palettes were measured, but it never
    /// crossed this bridge, so *nothing downstream could consume it even in principle*. The
    /// gap was recorded as "not yet wired to either engine" — accurate about the engines and
    /// quietly understating the cause, which was this struct's field list. The editor
    /// consumes it now (`FileViewerPane+Document.swift`); both terminal engines still do not,
    /// and that half of the gap stands.
    var selection: NSColor
    /// Exactly 16 entries: 8 normal then 8 bright. SwiftTerm's `installColors`
    /// silently does nothing if the array is not 16 long, so this is validated
    /// at construction rather than trusted.
    var ansi: [NSColor]

    /// Build from a `ThemePalette` — the pure, Foundation-only hex values in
    /// `ThemeValues.swift`.
    ///
    /// The hex used to live *here*, inline, which meant the palettes sat behind this
    /// file's `import AppKit` and `import SwiftTerm` and were therefore unreachable by
    /// any check (`check-theme-contrast.sh` compiles Foundation-only files standalone —
    /// the same argument `GitStatus+Presentation.swift` makes about its own narrowing).
    /// Now this file does one thing: bridge measured values into the two engines' colour
    /// types. The force-unwraps are safe by the same rule as the rest of this file —
    /// compile-time-known literals — and BOTH gates parse every one of them
    /// independently, so a typo fails a gate rather than trapping at launch.
    ///
    /// The `precondition` is a runtime backstop for the same invariant the gates check
    /// at ship time, not a duplicate concern (PR #24 review, item 6). `Theme.init` is
    /// called ONLY from `preset(named:)` and the statics below, every one resolving a
    /// fixed `ThemePalette`; a user's `theme.ansi` override is validated separately in
    /// `AppConfig.load()` (`Config+Theme.swift`) and lands here as a direct mutation
    /// AFTER construction, never through this initialiser. So a count violation reaching
    /// this line can only mean a `ThemeValues.swift` edit shipped without running the
    /// gates — a programmer error, not user input, which is exactly the
    /// trap-rather-than-silently-corrupt trade a `precondition` is for.
    init(_ palette: ThemePalette) {
        precondition(palette.ansi.count == 16,
            "ThemePalette '\(palette.name)' has \(palette.ansi.count) ANSI colours, need exactly 16 — "
                + "check-theme-contrast.sh should have caught this before ship")
        background = NSColor.fromHex(palette.background)!
        foreground = NSColor.fromHex(palette.foreground)!
        chromeForeground = NSColor.fromHex(palette.chromeForeground)!
        cursor = NSColor.fromHex(palette.cursor)!
        selection = NSColor.fromHex(palette.selection)!
        ansi = palette.ansi.map { NSColor.fromHex($0)! }
    }

    /// **Umber** — designed for this app and measured, not transcribed. Selected with
    /// `"theme": {"preset": "umber"}`. Rationale and the numbers behind it are on
    /// `ThemePalette.umber`; the derivation is in `.afk/research/theme-design-2026-08-03/`.
    static let umber = Theme(.umber)

    /// Classic Repaired — `"preset": "classic-repaired"`. The engine's vivid Basic
    /// palette with its unreadable blue and collapsed blue bright step repaired.
    static let classicRepaired = Theme(.classicRepaired)

    /// AFK Dark — `"preset": "afk-dark"`. A verbatim port; see `ThemePalette.afkDark`.
    static let afkDark = Theme(.afkDark)

    /// AFK Light — `"preset": "afk-light"`. The only light preset, and therefore the
    /// only one that makes `AppConfig.appearance` (`Config.swift`) return `.aqua`, so
    /// the sidebar and titlebar follow the terminal instead of fighting it.
    static let afkLight = Theme(.afkLight)

    /// Tokyo Night — the v0.1 default, kept as a preset: `"preset": "tokyo-night"`.
    static let tokyoNight = Theme(.tokyoNight)

    /// Catppuccin Mocha — `"preset": "catppuccin-mocha"`. The most-starred Catppuccin
    /// flavour. Verbatim port; see `ThemePalette.catppuccinMocha`.
    static let catppuccinMocha = Theme(.catppuccinMocha)

    /// Nord — `"preset": "nord"`. The Arctic, north-bluish palette.
    /// Verbatim port; see `ThemePalette.nord`.
    static let nord = Theme(.nord)

    /// Dracula — `"preset": "dracula"`. The popular dark theme by Zeno Rocha.
    /// Verbatim port; see `ThemePalette.dracula`.
    static let dracula = Theme(.dracula)

    /// Resolve a `"preset"` name. `"classic"` is deliberately absent: it maps to
    /// `nil`, meaning "install nothing and let SwiftTerm's own defaults stand".
    ///
    /// Every name accepted here must correspond to a palette in `ThemePalette.all`, and
    /// vice versa — `check-theme-contrast.sh` asserts the two cannot drift, because a
    /// preset that exists but is unreachable from config is invisible, and a name that
    /// resolves to nothing falls back to a *different* theme with only a warning.
    ///
    /// `classic` is deliberately absent: it must resolve to nil, meaning "install nothing
    /// and let the engine's own defaults stand". A typo also returns nil, and the two are
    /// told apart one layer up in `AppConfig.load()` (`Config+Theme.swift`) — classic
    /// stays nil, a typo warns and falls back to umber. `check-light-theme.sh` asserts
    /// that distinction survives.
    static func preset(named name: String) -> Theme? {
        ThemePalette.named(name).map(Theme.init)
    }
}
