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
enum StarterConfig {
    static let text = """
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

      "// renderer": "coretext (default) | metal. metal is SwiftTerm's GPU path: a glyph atlas plus per-row vertex caching, which should scroll a big log noticeably faster than coretext, where every visible row is re-shaped through Core Text on every frame.",
      "// renderer-note": "OPT-IN because upstream calls the GPU path experimental and its speedup here has not been measured. Falls back to coretext by itself if it cannot start, and says so on stderr. Change it and hit Cmd-R; run app/Scripts/check-metal-renderer.sh if you suspect it silently fell back.",
      "renderer": "coretext",

      "// padding": "inner margin around terminal content in points. Default 4. The gap fills with the terminal background colour (seamless, not a border). Two forms accepted:",
      "// padding-uniform": "  \"padding\": 4               → same on all sides",
      "// padding-xy":     "  \"padding\": { \"x\": 8, \"y\": 4 }  → separate horizontal / vertical",
      "// padding-note": "Does NOT apply to the file editor (that uses textContainerInset). Values above 100 are rejected and fall back to the default.",
      "padding": 4,

      "// unfocusedPaneOpacity": "0.0-1.0. Alpha of the unfocused pane when a split is open. 1.0 (default) = no dimming. 0.85 is a good starting point: the inactive pane stays readable but the focused one clearly wins. Out-of-range values are ignored and a warning is printed to stderr.",
      "unfocusedPaneOpacity": 1.0,

      "// fontThicken": "Apply medium font dilation before glyph rendering (default false). White-on-black text appears thinner than light-on-dark due to sub-pixel AA bleed direction. Enabling this applies CGContextSetFontSmoothingStyle(48) — the same style Terminal.app uses — which widens strokes roughly half a sub-pixel. Try it if your font looks too light on dark backgrounds. Note: private CoreGraphics API, same as Terminal.app/iTerm2/Emacs use.",
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

    """
}
