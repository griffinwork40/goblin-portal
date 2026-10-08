//
//  StarterConfig.swift
//  The commented config.json written on first ⌘,.
//

/// The starter `config.json` template, as text.
///
/// Its own file because it is documentation that happens to be a string literal:
/// ~25 lines of user-facing prose (every `"// key"` is a comment the user reads in
/// their editor) with no behaviour, versioned alongside the fields it describes in
/// `Config.swift`. Sitting inside `AppDelegate` it made the delegate look 27 lines
/// bigger than the code it actually owns, and an edit to the template read as an
/// edit to app lifecycle in the diff.
///
/// Written only when `~/.config/goblin-portal/config.json` does not exist
/// (`AppDelegate.openConfigFile`); the app never rewrites an existing file. Keep
/// the values here in step with `AppConfig.defaults()` — that is the source of
/// truth, this is its annotated copy.
///
/// ## Why `#"""..."""#` (a raw string literal)
///
/// The padding-uniform and padding-xy comment values show the user example JSON
/// containing `"padding"` with quotes around the key name. In a plain `"""` literal
/// `\"` evaluates to a bare `"` at runtime, which produces unescaped quotes inside
/// the JSON string values and makes JSONSerialization reject the whole file with:
///   "Badly formed object around line 25, column 28."
/// The bug is invisible when reading the source (the source escapes look correct);
/// only the *compiled string* is truth.
///
/// A raw string literal (`#"""..."""#`) passes every byte through verbatim — the
/// Swift compiler performs no escape processing. `\"` in source is `\"` at runtime,
/// which is exactly the JSON escape sequence for a literal quote inside a string
/// value. The template is therefore its own ground truth: it compiles to exactly the
/// bytes the user's editor will show, and those bytes must be valid JSON.
///
/// Gate: `app/Scripts/check-starter-config.sh` compiles this file standalone and
/// feeds `StarterConfig.text` to `JSONSerialization` — a parse of the source is
/// insufficient because Swift's escape rules make the source and runtime diverge for
/// `\"` sequences.
enum StarterConfig {
    static let text = #"""
    {
      "// font": "any installed monospaced family; omit family for SF Mono (the system monospaced face, and the default)",
      "// font.size": "points, 6-48. Default 14. Cmd+ / Cmd- zoom live on top of this and persist; Cmd0 clears the zoom and hands control back to this value.",
      "font": { "family": "SF Mono", "size": 14 },

      "// cursor": "block | steady-block | bar | steady-bar | underline | steady-underline",
      "cursor": "block",

      "// scrollback": "lines to retain; 0 disables scrollback entirely",
      "// scrollback-note": "past ~3500 the scrollbar thumb hits its 1% floor and stops tracking position, and every window resize walks the whole buffer",
      "scrollback": 1000,

      "// shell": "defaults to $SHELL; launched with -l so your PATH loads",
      "// optionAsMeta": "true lets Option act as Meta instead of typing accents",
      "optionAsMeta": true,

      "// mouseReporting": "true (default) lets programs like tmux and vim capture mouse clicks. When true, hold Shift to select text instead. Set false to always select text with the mouse (programs lose mouse support).",
      "mouseReporting": true,

      "// renderer": "metal (default) | coretext. metal is SwiftTerm's GPU path: a glyph atlas plus per-row vertex caching. coretext re-shapes every visible row through Core Text on every frame with no per-row cache. check-metal-throughput.sh validates Metal is faster.",
      "// renderer-note": "Falls back to coretext by itself if the GPU is unavailable, and says so on stderr. Run app/Scripts/check-metal-renderer.sh if you suspect it silently fell back.",
      "renderer": "metal",

      "// padding": "inner margin around terminal content in points. Default 4. The gap fills with the terminal background colour (seamless, not a border). Two forms accepted:",
      "// padding-uniform": "  \"padding\": 4               → same on all sides",
      "// padding-xy":     "  \"padding\": { \"x\": 8, \"y\": 4 }  → separate horizontal / vertical",
      "// padding-note": "Does NOT apply to the file editor (that uses textContainerInset). Values above 100 are rejected and fall back to the default.",
      "padding": 4,

      "// unfocusedPaneOpacity": "0.0-1.0. Palette-aware by default (PaneDimming.swift): dims to about 0.7 where body text stays at APCA Lc >= 45; does not dim under classic-repaired (body text is already below the floor). An explicit 0.0-1.0 value overrides the default and prints a warning if the result drops body text below Lc 45. Out-of-range values are ignored with a warning.",

      "// fontThicken": "No effect on macOS 15+ — CGContextSetFontSmoothingStyle is a no-op in both renderers. Setting true emits a config warning. Key accepted to keep existing configs valid.",
      "fontThicken": false,

      "// lineHeight": "Multiplier on the font's natural line height (default 1.0). 1.2 = 20% extra leading. Range 0.8–2.0. Uses SwiftTerm's public lineSpacing property, which correctly resizes the terminal grid after changing.",
      "lineHeight": 1.0,

      "// editor": "editing behaviour for the file viewer (the tab you get when you double-click a file in the sidebar)",
      "// editor.tabWidth": "spaces per indent level, 1-16. Default 4.",
      "// editor.softTabs": "true inserts spaces when you press Tab; false inserts a literal tab character",
      "// editor.wordWrap": "auto (default, wraps .md/.txt, not code) | on | off",

      "// theme": "OMITTED HERE, WHICH MEANS CLASSIC-REPAIRED — since 2026-08-20 the built-in default is classic-repaired, Terminal.app Basic with readable blue and quiet body text. Installing a palette does NOT harm the 256-colour cube: this app pins ansi256PaletteStrategy to .xterm before any colour, so indices 16-255 stay the standard xterm values whatever you set. Set preset to classic if you genuinely want no colours installed.",
      "// theme-example": {
        "preset": "classic-repaired",
        "// preset-values": "classic-repaired | umber | afk-dark | afk-light | tokyo-night | catppuccin-mocha | nord | dracula | classic | auto",
        "// preset-note": "classic-repaired is the DEFAULT — Terminal.app Basic with readable blue, quiet body text, and saturated ANSI colours. umber is the palette designed and measured for this app (warm umber-black base). catppuccin-mocha, nord, and dracula are community ports transcribed verbatim. classic installs nothing. Verified by Scripts/check-theme-contrast.sh.",
        "// auto-mode": "set preset to auto, then add dark and light sub-fields naming any two presets. Goblin Portal then watches macOS System Settings and switches palettes automatically when you toggle Light/Dark mode. The sidebar and titlebar chrome switch with the theme — no second setting needed.",
        "// auto-example": { "preset": "auto", "dark": "classic-repaired", "light": "afk-light" },
        "// auto-defaults": "dark defaults to classic-repaired, light defaults to afk-light if omitted",
        "// overrides": "background/foreground/cursor/ansi may be set on top of a pinned preset (not supported in auto mode); ansi must be exactly 16 colours, 8 normal then 8 bright",
        "cursor": "#FF9B5A"
      }
    }

    """#
}
