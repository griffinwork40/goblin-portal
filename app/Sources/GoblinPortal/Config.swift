//
//  Config.swift
//  The on-disk config shape (`ConfigFile`) and the resolved `AppConfig` type.
//
//  Config lives at ~/.config/goblin-portal/config.json. Every field is optional;
//  anything absent falls back to a default that is meant to already look good,
//  because the point of this app is that it is beautiful before you configure it.
//
//  Deliberately plain JSON rather than a bespoke format: it is diffable,
//  machine-editable, and needs no parser of its own.
//
//  This file owns: `ConfigFile` (the wire-format struct), `AppConfig` (the resolved
//  type with its stored properties, statics, `defaults()`, `resized(_:to:)`, and
//  `configURL`).
//
//  `load()`, `preferredMonoFont`, and `systemMonoAliases` live in `Config+Load.swift`
//  — extracted at the 350-LOC ceiling. `ConfigFile` is `internal` (not `private`) so
//  that extension file can decode the wire format; nothing else in the module reads it.
//

import AppKit
// No `import SwiftTerm`. It was here for exactly one symbol, `CursorStyle`, which is
// now this project's own type in CursorStyle.swift — see that file's header for why an
// app-wide config type must not name the emulator.

// MARK: - Config file shape

/// On-disk config. All fields optional — see `AppConfig.resolved`.
/// Internal (not `private`) so `Config+Load.swift` can decode it; nothing else in
/// the module should read `ConfigFile` directly — use the resolved `AppConfig`.
struct ConfigFile: Decodable {
    struct FontSpec: Decodable {
        var family: String?
        var size: Double?
    }
    struct ThemeSpec: Decodable {
        /// "umber" | "classic-repaired" | "afk-dark" | "afk-light" | "tokyo-night" |
        /// "classic" | "auto". Omitted with other
        /// fields present means "umber, with my overrides on top" — see
        /// `Config+Theme.swift` for why the fallback is the measured palette.
        ///
        /// When `preset` is `"auto"`, the `dark` and `light` keys name the palettes to
        /// install for each system appearance. The existing pinned-theme path is unchanged:
        /// any non-"auto" preset always installs exactly one palette and never observes
        /// the system appearance.
        var preset: String?
        var background: String?
        var foreground: String?
        var cursor: String?
        var ansi: [String]?
        // Auto-mode sub-fields — only read when preset == "auto".
        var dark: String?
        var light: String?
    }
    var font: FontSpec?
    var theme: ThemeSpec?
    var cursor: String?
    var scrollback: Int?
    var shell: String?
    var optionAsMeta: Bool?
    var mouseReporting: Bool?
    var renderer: String?
    /// Font dilation on dark backgrounds. Default false.
    var fontThicken: Bool?
    /// Line height multiplier. Default 1.0. Range 0.8–2.0.
    var lineHeight: Double?
    /// Ligature toggle. `true` = ligatures on (default); `false` = disabled via
    /// `TerminalView.disableLigatures` (vendor patch 0014). Wired in `Config+Load.swift`.
    var ligatures: Bool?
    /// Pixel-level smooth trackpad scrolling. Default true.
    var smoothScrolling: Bool?
    /// When to close a pane after its shell exits.
    /// Accepted values: `"clean"` (default), `"always"`, `"never"`.
    var closeOnShellExit: String?

    struct EditorSpec: Decodable {
        var tabWidth: Int?
        var softTabs: Bool?
        var wordWrap: String?
        var indentRainbow: Bool?
        var columnGuide: Int?
        var showTrailingWhitespace: Bool?
        var stickyScroll: Bool?
    }
    var editor: EditorSpec?

    /// `"sidebar": { "autoReveal": true }` — when the active document changes,
    /// scroll to and select its file in the tree without stealing focus.
    struct SidebarSpec: Decodable {
        var autoReveal: Bool?
    }
    var sidebar: SidebarSpec?

    // `padding` accepts two forms:
    //   "padding": 4               → uniform 4px on all sides
    //   "padding": { "x": 8, "y": 4 } → separate horizontal / vertical
    // Both decode via a custom Decodable that tries a plain Double first.
    struct PaddingSpec: Decodable {
        let x: CGFloat
        let y: CGFloat

        private struct XY: Decodable {
            let x: CGFloat
            let y: CGFloat
        }

        init(from decoder: Decoder) throws {
            let single = try? decoder.singleValueContainer().decode(CGFloat.self)
            if let v = single {
                x = v; y = v
            } else {
                let xy = try XY(from: decoder)
                x = xy.x; y = xy.y
            }
        }
    }
    var padding: PaddingSpec?
    /// 0.0–1.0. The alpha applied to the unfocused pane when a split is active.
    /// 1.0 means no dimming (the default). Fail-soft: out-of-range values degrade
    /// to 1.0 with a warning rather than refusing to load the rest of the config.
    var unfocusedPaneOpacity: Double?
}

/// Resolved, ready-to-use configuration. Never fails: a missing, malformed, or
/// partially-invalid config file yields defaults for whatever could not be read,
/// and the reasons are surfaced in `warnings` rather than thrown.
struct AppConfig {
    var font: NSFont
    /// `nil` means "do not install any colours" — SwiftTerm's own defaults stand.
    /// That is still the default, but **the reason it used to give was stale and is
    /// corrected here** (2026-08-03).
    ///
    /// The old note said installing a background or foreground makes SwiftTerm
    /// regenerate ANSI 16–255 by interpolating them out of your bg/fg, replacing the
    /// standard 256-colour cube. That is true of SwiftTerm's *library default* and
    /// false of this app: `TerminalPane.apply(config:)` sets
    /// `ansi256PaletteStrategy = .xterm` unconditionally before any colour
    /// (`TerminalPane.swift:165`), `Terminal.swift:523,538` gate the rebuild on
    /// `!= .xterm`, and `installPalette` under `.xterm` routes to
    /// `generateXtermPalette` (`Colors.swift:169-190`), which appends the literal
    /// standard cube and never reads bg/fg. **A custom palette is free of that
    /// defect**; installing one is now only a question of taste.
    ///
    /// **The default is `.classicRepaired` as of 2026-08-20** (was `.umber` since 2026-08-03),
    /// and the reasoning that kept it `nil`
    /// was wrong in a specific way worth recording. It treated "install nothing" as the
    /// conservative choice pending real use. It is not conservative — it is unmeasured.
    /// `nil` renders SwiftTerm's `Color.terminalAppColors` (`Colors.swift:91-108`) on
    /// black, which fails **7 of the 8** slots `check-theme-contrast.sh` has floors for:
    /// ANSI 4 blue `#492EE1` at APCA Lc 16.9, ANSI 1 red at 25.8, ANSI 8 — the colour
    /// nearly every tool uses for de-emphasised output — at 36.0 against a floor of 48,
    /// and a normal→bright ring separation of 0.054 against 0.085. For scale, that gate's
    /// own falsification case asserts xterm's `#0000EE` at Lc 14.0 must be REJECTED as the
    /// canonical unreadable blue; the old default's blue sat 2.9 points from it.
    /// "Daily-drive it first" is the right bar for choosing between two *good* palettes,
    /// not for keeping a measurably bad incumbent.
    ///
    /// `"preset": "classic"` still selects `nil` — install nothing — for anyone who wants
    /// the engine's own colours. See `ThemeValues.swift` for what `umber` is and
    /// `.afk/research/theme-design-2026-08-03/` for how it was derived.
    var theme: Theme?
    var cursorStyle: CursorStyle
    var scrollback: Int
    var shell: String
    var optionAsMeta: Bool
    /// Whether programs may request mouse events (DECSET 1000/1002/1003). Default
    /// `true`. When `false`, SwiftTerm's `allowMouseReporting` is cleared and clicks
    /// always start text selection — programs like tmux and vim lose their mouse
    /// support but the user can select and copy freely. The Shift-click bypass
    /// (`shiftBypassesMouseReporting`) still works when this is `true`.
    var mouseReporting: Bool
    /// Which drawing back end terminals use. See `Renderer.swift` for the two paths and
    /// why the default is `.metal`.
    var renderer: Renderer
    /// Apply medium font dilation (CGContextSetFontSmoothingStyle style 48) before
    /// glyph rendering. Compensates for sub-pixel AA bleed that makes white-on-black
    /// text appear thinner than the same face on a light background. Mirrors
    /// Terminal.app's own smoothing style and Ghostty's `font-thicken`. Default false.
    var fontThicken: Bool
    /// Multiplier on the font's natural line height. 1.0 = default metrics;
    /// 1.2 = 20% extra leading. Clamped to 0.8–2.0. Default 1.0.
    var lineHeight: CGFloat
    /// Pixel-level smooth trackpad scrolling via CALayer transform. Default true.
    /// Set `"smoothScrolling": false` in config.json to opt out.
    var smoothScrolling: Bool
    /// Ligature toggle. When `true` (default), ligatures form when the font supports them
    /// (e.g. JetBrains Mono `->`, `=>`, `!=`). When `false`, OpenType ligature substitution
    /// is disabled in both renderers via `TerminalView.disableLigatures` (patch 0014).
    /// Set `"ligatures": false` in config.json to suppress them.
    var ligatures: Bool

    // Editor behaviour — see `Config+Editor.swift` for the resolver.
    var tabWidth: Int
    var softTabs: Bool
    var wordWrap: WordWrapMode
    /// Indent rainbow: subtle colour bands per indent level. Default: false.
    /// Configured via `editor.indentRainbow` in config.json.
    var indentRainbow: Bool
    /// Column guide position in characters. nil = no guide. Default: 80.
    /// Configured via `editor.columnGuide` in config.json; 0 means disabled.
    var columnGuideColumn: Int?
    /// Visualize trailing whitespace with dim dots. Default: true.
    /// Configured via `editor.showTrailingWhitespace` in config.json.
    var showTrailingWhitespace: Bool
    /// Pin the enclosing scope header at the top of the editor while scrolling.
    /// Default: true. Configured via `editor.stickyScroll` in config.json.
    var stickyScroll: Bool
    /// Inner margin around terminal content. See `Config+Padding.swift` for the full
    /// rationale and the parsing details (accepted forms, validation, fail-soft contract).
    /// Default (4, 4) — see `defaults()`.
    var terminalPadding: (x: CGFloat, y: CGFloat)
    /// Alpha applied to the unfocused pane in a split. When the user sets none, this is
    /// the palette-safe value `PaneDimming.effectiveOpacity` derives (0.7 unless that
    /// would push body text under Lc 45; 1.0 for `classic-repaired`). 1.0 = no dimming.
    /// Out-of-range values degrade to that default with a warning.
    /// Affects the ENTIRE pane view (terminal chrome included), not just the text surface.
    var unfocusedPaneOpacity: Double
    /// The in-range `unfocusedPaneOpacity` the user wrote, or nil. Kept apart from the
    /// effective value so a runtime palette switch (`AppearanceObserver`) can recompute
    /// the default for the NEW palette without overriding an explicit choice.
    var userPaneOpacity: Double? = nil
    /// When true, switching to a `FileViewerPane` document scrolls to and selects
    /// its file in the sidebar tree — without stealing keyboard focus from the editor.
    /// Default: true. Configured via `"sidebar": { "autoReveal": true }`.
    var sidebarAutoReveal: Bool
    /// When to close a pane after its shell exits.
    /// `"clean"` (default, Terminal.app's behaviour): close on exit 0, keep on nonzero
    /// or signal. `"always"`: always close (pre-T2.2 behaviour). `"never"`: always keep.
    /// Unknown values warn and fall back to `"clean"`. Wired in `Config+Load.swift`.
    /// Gated by `app/Scripts/check-shell-exit.sh`.
    var closeOnShellExit: CloseOnShellExit

    /// Non-nil when the user has configured `"preset": "auto"`. Holds the two resolved
    /// palettes so the appearance observer can switch between them without re-parsing the
    /// config file. Always nil when a pinned preset is in use, which keeps the existing
    /// appearance-pin path in `SpaceWindowController` completely unchanged — see that
    /// file's comment at line 166 for why the pin matters.
    var autoTheme: (dark: Theme, light: Theme)?

    /// Human-readable notes about anything in the config that was ignored.
    var warnings: [String] = []

    /// 14pt, not 13. The default has to be comfortable on a Retina display
    /// without touching a config file, and 13 read as cramped in use. Both
    /// `font.size` and ⌘+ / ⌘− override this.
    static let defaultFontSize: Double = 14

    /// Bounds for both `font.size` and the live zoom. Below ~6pt the glyphs stop
    /// being legible; above ~48 a standard window holds too few columns for a TUI
    /// to lay out. Shared so the config path and the zoom path cannot disagree.
    static let minFontSize: Double = 6
    static let maxFontSize: Double = 48

    /// Resize the configured face. Derived from the resolved font's **descriptor**,
    /// not re-resolved from its family name: the system monospaced face is
    /// `.AppleSystemUIFontMonospaced`, a dot-prefixed internal family that is not
    /// guaranteed to survive `NSFont(name:)`, and the old code's fallback for that
    /// miss was hardcoded Menlo — the exact silent substitution that made v0.1
    /// render worse than the spike (see `preferredMonoFont`). The descriptor
    /// carries the resolved face, so zooming cannot change it.
    ///
    /// Lives here rather than on one pane because every document kind zooms
    /// (`SpaceDocument.setFontSize`), and a second private copy in `FileViewerPane`
    /// is a second place for this fallback to rot.
    static func resized(_ base: NSFont, to size: CGFloat) -> NSFont {
        NSFont(descriptor: base.fontDescriptor, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var configURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/goblin-portal/config.json")
    }

    /// A default that is intended to look good with zero configuration.
    static func defaults() -> AppConfig {
        AppConfig(
            font: preferredMonoFont(family: nil, size: defaultFontSize).font,
            theme: .classicRepaired,
            cursorStyle: .default,
            // 5,000 (T2.4, 2026-10-09). Measured on M4 Pro with RELEASE SwiftTerm
            // (check-scrollback-cost.sh): resize p50 at 5k = 5,098 µs (~5.1 ms) — 31% of a
            // 16.7 ms frame, leaving adequate margin for rendering during live drag.
            // Memory: 80 cols → 8.5 MB phys_footprint per pane; 200 cols → 21 MB.
            // Prior default was 1,000; prior measurements used DEBUG SwiftTerm (~25×
            // slower, off by 25×). The scrollbar-thumb hairline past ~4,554 lines is
            // fixed by vendor patch 0015 (`1/rows` floor, AppleTerminalView.swift).
            // Buffer.resize walks every line TWICE per resize — reflow + narrowing
            // trim (patch 0003). It was THREE walks until patch 0004 (2026-07-31).
            scrollback: 5_000,
            shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            optionAsMeta: true,
            mouseReporting: true,
            renderer: .default,
            fontThicken: false,
            lineHeight: 1.0,
            smoothScrolling: true,
            // Ligatures default to on: a terminal that ships JetBrains Mono forms ligatures
            // by default; the user opts out with `"ligatures": false`. Fonts without ligature
            // tables (SF Mono, Menlo) are unaffected by either setting.
            ligatures: true,
            tabWidth: 4,
            softTabs: true,
            wordWrap: .auto,
            indentRainbow: false,
            columnGuideColumn: 80,
            showTrailingWhitespace: true,
            stickyScroll: true,
            terminalPadding: (x: 4, y: 4),
            // Derived from the default palette rather than hardcoded. `PaneDimming.swift`
            // explains the full argument: `NSView.alphaValue` composites the pane layer
            // over the terminal background, so a flat 0.7 drops classic-repaired's
            // fg #8A8A8A from Lc 39.6 to Lc 20.8 — far below the app's own Lc 45 floor.
            // `effectiveOpacity` returns 1.0 (no dimming) for classic-repaired's pinned
            // case, and the largest opacity ≤ 0.7 that still clears Lc 45 for all other
            // palettes. Users who want a different value can set `unfocusedPaneOpacity`
            // in config.json; their choice is honoured with a warning if it breaks the floor.
            unfocusedPaneOpacity: {
                var w: [String] = []
                return PaneDimming.effectiveOpacity(
                    background: ThemePalette.classicRepaired.background,
                    foreground: ThemePalette.classicRepaired.foreground,
                    userOpacity: nil,
                    warnings: &w)
            }(),
            sidebarAutoReveal: true,
            // Terminal.app's default: close on a clean exit (code 0), keep on anything
            // else so the user can read what went wrong. `"always"` restores pre-T2.2
            // behaviour; `"never"` keeps every pane regardless.
            closeOnShellExit: .clean
        )
    }

}
