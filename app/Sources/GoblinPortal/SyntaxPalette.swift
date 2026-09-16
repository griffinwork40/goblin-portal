//
//  SyntaxPalette.swift
//  Which colour a syntax role gets, derived from the palette the terminal already has.
//
//  **Pure and view-free — Foundation only, on purpose**, like `ThemeValues.swift` and
//  `ThemeContrast.swift` beside it. This is the half of syntax highlighting that
//  `check-theme-contrast.sh` can compile standalone, and it is deliberately the half that
//  holds the *decisions*: which slot a role reads from, and what happens when that slot is
//  illegible. Painting the ranges needs AppKit and is therefore unreachable by any gate, so
//  everything a gate could hold to a number lives here instead of there.
//
//  The APP CONSUMER is `FileViewerPane+Highlighting.swift`, which reads the role→slot
//  mapping and the comment-colour fallback to paint five syntax roles over source files
//  in the editor. The colour decisions live here rather than there because this file is
//  Foundation-only and gateable; the painting is AppKit-only and not. The gate
//  (`check-theme-contrast-harness.swift` §5k) still exercises this file independently.
//
//  Side effect worth naming: this is the FIRST caller of `ThemeContrast` inside
//  `Sources/GoblinPortal`. Until now that file was 204 lines of measurement compiled into the
//  shipping binary with every call site in the harness — recorded in AFK.md as an accepted
//  gap whose honest fix was "a runtime minimum-contrast clamp… which would give the maths a
//  caller inside the app". `commentColour` below is a narrow instance of exactly that, and
//  `SelectionPairing` (added alongside it) is the second.
//
//  Derivation, the exhaustive search and the rejected alternatives:
//  `.afk/research/editor-syntax-2026-08-03/`.
//

import Foundation

/// The semantic categories a highlighter paints. Five, not fifty.
///
/// Plain identifiers are deliberately absent — they are the *foreground*, and a role that
/// colours everything colours nothing. Function names, operators, punctuation and attributes
/// are absent for the same reason a terminal has 16 colours and not 256: each extra role has
/// to earn a slot that is measurably distinct from the four already there, and past this
/// point they stop being (see `SyntaxPalette` on the size of the distinguishable set).
enum SyntaxRole: String, CaseIterable {
    case keyword    // `func`, `if`, `return`, `import`
    case string     // string and character literals, including their delimiters
    case number     // numeric literals, and the boolean/nil family that behaves like one
    case type       // type names — the capitalised half of an identifier's world
    case comment    // `//`, `/* */`, `#`
}

/// Syntax colours as a **role mapping onto the ANSI ring**, not as new hex per palette.
///
/// **Why a mapping.** Three of the five shipped palettes are declared verbatim upstream
/// ports, and `ThemeValues.swift` states the contract they are held to: *"a preset's job is
/// to be the thing it claims to be — silently 'fixing' a port makes it a different theme
/// wearing the same name."* Inventing ten syntax colours for those ports would break precisely
/// that. A mapping invents nothing and inherits whatever legibility the palette was already
/// measured for. Note the limit, because the obvious next sentence is false today: this does
/// NOT yet work for hex a user typed. Overrides are applied to `Theme` (NSColor) by
/// `Config+Theme.swift` after `Theme.init(_:)` has run, and there is no `Theme`→`ThemePalette`
/// conversion, so `colour(_:in:)` below is reachable only from the five shipped presets.
/// Whoever writes the highlighter (#28) needs that bridge first, or the config's colours and
/// the editor's will disagree. It is also what the surrounding
/// ecosystem does: base16, every 16-colour vim
/// scheme, `bat --theme=ansi` and `delta` all express syntax as ANSI roles, so the editor
/// ends up agreeing with the tools running in the terminal beside it.
///
/// **Why these four slots.** All 360 assignments of the four chromatic roles to the six
/// chromatic ANSI indices were measured (`rank_mappings.py`). The optimum is a 24-way tie,
/// and every member of it uses the same slot set: **green, yellow, blue, cyan**. Red and
/// magenta are excluded by the numbers rather than by taste — under `afk-dark` both measure
/// APCA Lc 41.4, below the Lc 45 floor at which text stops being readable at any size. Two
/// consequences fell out and both are wanted: the four chromatic roles clear the floor in
/// every palette (the separate comment role has one pinned Classic Repaired gap), and **red
/// stays free**, which is the colour an editor will want for diagnostics and a diff for
/// deletion. Spending it on `number` would have been the expensive mistake.
///
/// **Which member of the tie.** Numbers could not choose, so convention did: `string` =
/// green is close to universal (base16 `0B`, `grep`'s match, a diff's addition), and
/// `keyword` = blue with `type` = cyan follows VS Code Dark+'s blue keywords and teal types.
/// Measured for umber: every role ≥ Lc 49.5, worst pair separation dE-OK 0.118, worst
/// dichromatic separation 0.119.
enum SyntaxPalette {
    /// The mapping. Indices are into `ThemePalette.ansi` — 0…7 normal, 8…15 bright.
    ///
    /// Only the *normal* half is used. The bright half is what SwiftTerm renders bold text
    /// from (`useBrightColors`), so spending bright slots on roles would make a bold keyword
    /// and a plain one the same colour in the terminal beside the editor.
    static func ansiIndex(for role: SyntaxRole) -> Int {
        switch role {
        case .keyword: return 4   // blue
        case .string:  return 2   // green
        case .number:  return 3   // yellow
        case .type:    return 6   // cyan
        case .comment: return 8   // bright black — see `commentColour`
        }
    }

    /// APCA's floor for text readable at *any* size. Not a preference: below this a glyph is
    /// not resolvable, which is why the tab strip's inactive label was moved to clear it.
    static let readableFloor: Double = 45

    /// The alpha a comment is drawn at when its palette's ANSI 8 is illegible.
    ///
    /// The same value as `DocumentTabStrip+Drawing.swift`'s inactive-label alpha, and the
    /// same arithmetic, so the app has ONE idea of what de-emphasised text looks like. It is
    /// duplicated rather than shared on purpose: these are two independent decisions that
    /// happen to land on the same number, and coupling them would let a tweak to the tab
    /// strip silently restyle every comment in the editor.
    static let commentAlpha: Double = 0.72

    /// The colour a role should be painted in, for a given palette.
    ///
    /// Returns nil only if the palette's hex does not parse, which `check-theme-contrast.sh`
    /// already makes impossible for anything shipped — the optionality is here so a user's
    /// own typo degrades to "no colour for this role" rather than trapping.
    static func colour(_ role: SyntaxRole, in palette: ThemePalette) -> RGB? {
        guard let bg = RGB(hex: palette.background) else { return nil }
        let index = ansiIndex(for: role)
        guard index < palette.ansi.count, let slot = RGB(hex: palette.ansi[index]) else {
            return nil
        }
        guard role == .comment else { return slot }
        return commentColour(ansi8: slot, background: bg, foreground: palette.foreground)
    }

    /// Comments, and the one place this file overrides the palette rather than reading it.
    ///
    /// ANSI 8 is the comment colour by near-universal convention — it is what every tool
    /// already uses for de-emphasised output, and umber's was *designed* for the job
    /// (`ThemeValues.swift`, "the comment colour", measured Lc 51.5). But it is also the
    /// field's universal failure: `tokyo-night` ships Lc 10.3 and `afk-dark` Lc 13.1 against
    /// this floor of 45, and both are verbatim ports that must not be edited. A comment in a
    /// *terminal* at Lc 10 is dim `ls` output; a comment in an *editor* is content, and prose
    /// nobody can read is the worst outcome available here.
    ///
    /// So: use ANSI 8 when it is legible, and otherwise fall back to the foreground drawn at
    /// `commentAlpha`, which de-emphasises without going invisible. Across the five shipped
    /// palettes the clamp fires for three: Tokyo Night lands at Lc 46.3, AFK Dark at 47.4, and
    /// Classic Repaired at its pinned Lc 21.9 gap; Umber (51.5) and AFK Light (81.8) take the raw
    /// path. Comments stay 17.7…35.5 Lc below body text, so they still read as secondary.
    ///
    /// This is a *clamp*, and clamps hide things, so note exactly what it does not do: it
    /// never touches hue and never nudges gamut, which is the harder unbuilt version AFK.md
    /// defers. It swaps one measured colour for another measured colour on a threshold the
    /// gate asserts, and the gate also asserts that BOTH branches are still reachable — umber
    /// must take the ANSI 8 path and tokyo-night must take the fallback, or a dead branch
    /// could rot untested.
    static func commentColour(ansi8: RGB, background: RGB, foreground: String) -> RGB {
        if APCA.lc(text: ansi8, background: background) >= readableFloor { return ansi8 }
        guard let fg = RGB(hex: foreground) else { return ansi8 }
        return fg.composited(over: background, alpha: commentAlpha)
    }

    /// Every role resolved for one palette. The shape a highlighter wants: look up once at
    /// `apply(config:)` time, never per token.
    static func resolved(for palette: ThemePalette) -> [SyntaxRole: RGB] {
        SyntaxRole.allCases.reduce(into: [:]) { out, role in
            if let c = colour(role, in: palette) { out[role] = c }
        }
    }
}
