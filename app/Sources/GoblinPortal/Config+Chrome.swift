//
//  Config+Chrome.swift
//  Chrome derived from the resolved theme: the colour the terminal actually
//  paints, its AppKit-text counterpart, and the system appearance the window
//  adopts so the sidebar matches the terminal.
//
//  Split out of Config.swift when that file crossed the 350-line ceiling
//  (2026-08-17, after the editor-config and mouseReporting fields landed). These
//  three are one concern — "given a resolved theme, or none, what does the
//  surrounding chrome paint" — and the loader (`defaults()` / `load()`) never
//  touches them, so they move cleanly. Kept as an extension on `AppConfig` so
//  every call site is unchanged: consumers still read `config.effectiveBackground`,
//  `.effectiveForeground` and `.appearance`. Each property keeps the doc comment
//  that carries its rationale — the stale-ANSI correction, the sidebar-appearance
//  derivation, and the one call site that reads `WCAG.lightChromeCutoff`.
//
//  `effectiveSelectionColors(for:)` was promoted here from `FileViewerPane+Document.swift`
//  when the terminal engine was told about `ThemePalette.selection` (#31) — that
//  second consumer (TerminalPane) was exactly the threshold the original comment
//  predicted: "promote it when the terminals are told too (#31)". Both `FileViewerPane`
//  and `TerminalPane` call this method; neither owns the rule.
//

import AppKit

extension AppConfig {
    /// The background the terminal will *actually* paint, theme or no theme.
    ///
    /// `theme == nil` means "install nothing and let SwiftTerm's own defaults
    /// stand", and those default to black (`Colors.swift:37` defaultBackground).
    /// Every piece of chrome that has to agree with the terminal was open-coding
    /// `theme?.background ?? .black`; four copies of that fallback is four places
    /// for the chrome and the content to drift apart.
    var effectiveBackground: NSColor { theme?.background ?? .black }

    /// As `effectiveBackground`, for AppKit text. SwiftTerm's actual default is `#8A8A8A`,
    /// not white (`SwiftTerm/Colors.swift:36`); a real theme normally follows its terminal
    /// foreground, with Classic Repaired's explicit readable-chrome exception.
    var effectiveForeground: NSColor { theme?.chromeForeground ?? NSColor.fromHex("#8A8A8A")! }

    /// The system appearance the window should adopt, derived from the theme.
    ///
    /// This is the setting that makes the *sidebar* match the terminal. The file
    /// tree is deliberately built out of system parts — `NSSplitViewItem(sidebar
    /// WithViewController:)` and `outlineView.style = .sourceList` (plan §12.4
    /// item 5) — so its material, its selection pill, its label colours and its
    /// scroller knob are all chosen by AppKit from the effective `NSAppearance`.
    /// Nothing used to set one, so they followed *System Settings*: on a Mac in
    /// Light Mode that put a light-grey tree with black text and full-colour
    /// Finder icons directly against a black terminal.
    ///
    /// Derived rather than hardcoded to `.darkAqua`: the theme is user hex, so a
    /// light background is expressible today even though no preset ships one, and
    /// pinning dark would simply invert the same bug. Deriving it also means the
    /// vibrant sidebar material samples `window.backgroundColor` — already the
    /// theme background — so the tree picks up the theme's tint for free, without
    /// hand-painting a single row.
    ///
    /// The comparison is spelled out as `Double` rather than leaning on
    /// CGFloat/Double bridging: `relativeLuminance` is `CGFloat` (it feeds AppKit
    /// APIs) and `WCAG.lightChromeCutoff` is `Double` (that file is
    /// Foundation-only and cannot spell `CGFloat`), and an implicit conversion at
    /// the comparison site would leave the two types silently doing the coercion
    /// instead of the reader seeing it happen. `ThemeContrast.swift`'s doc comment
    /// carries the WCAG rationale for the constant itself — this is the one
    /// call site that reads it, not a second definition of it (PR #24 review, item 1).
    var appearance: NSAppearance? {
        NSAppearance(named: Double(effectiveBackground.relativeLuminance) > WCAG.lightChromeCutoff ? .aqua : .darkAqua)
    }

    /// The selection background to install, paired with the theme foreground — or nil
    /// when the system pair should stand.
    ///
    /// Promoted from `FileViewerPane+Document.swift` when `TerminalPane` became the
    /// second consumer (#31). The original comment there said "promote it when the
    /// terminals are told too" — this is that promotion.
    ///
    /// Returns `nil` in two cases: no theme (`"preset": "classic"`) and a theme whose
    /// selection this foreground cannot be read on. Both callers treat nil identically:
    /// fall back to the complete system pair (`NSColor.selectedTextBackgroundColor` /
    /// `NSColor.selectedTextColor`). That pair is appearance-aware and honours
    /// "Increase Contrast", so it is a better fallback than any fixed colour.
    ///
    /// The AppKit half of `SelectionPairing`: cross the two colours into hex
    /// (`NSColor.hexString` converts to sRGB first, so catalog colours like the
    /// no-theme `.white` cannot trap here) and ask the pure rule in `ThemeContrast.swift`.
    /// Everything decidable is decided there, where `check-theme-contrast.sh` can
    /// compile it standalone.
    /// The accent colour painted as a 2px line at the bottom of the active tab.
    ///
    /// Sourced from `theme?.cursor` when a theme is installed: the cursor is already
    /// the brightest, most salient per-theme colour, and using it keeps the tab accent
    /// visually coherent with the caret the eye is already tracking. That is what
    /// Ghostty and VS Code do — a thin cursor-coloured line reads as "you are here"
    /// without competing with the terminal content.
    ///
    /// Falls back to `NSColor.controlAccentColor` when no theme is set (`"preset":
    /// "classic"`) or when the theme's cursor parses to nil. `controlAccentColor` is
    /// the system's own "action" signal — blue by default, respecting the user's accent
    /// preference in System Settings — which is the most sensible default available
    /// with no measured palette to draw from.
    var effectiveAccent: NSColor { theme?.cursor ?? .controlAccentColor }

    func effectiveSelectionColors() -> (background: NSColor, foreground: NSColor)? {
        guard let selection = theme?.selection,
              let sel = RGB(hex: selection.hexString),
              let fg = RGB(hex: effectiveForeground.hexString) else { return nil }
        guard SelectionPairing.isReadable(foreground: fg, on: sel) else { return nil }
        return (background: selection, foreground: effectiveForeground)
    }
}
