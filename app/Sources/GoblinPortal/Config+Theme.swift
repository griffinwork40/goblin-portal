//
//  Config+Theme.swift
//  Turning a config file's `theme` block into a `Theme`, field by field, fail-soft.
//
//  Its own file because `Config.swift` hit the 350-line ceiling on 2026-08-03 and this is
//  its cleanest seam: everything here is one question — "given some optional strings a user
//  typed, which palette do we install?" — and answering it needs none of the rest of
//  `AppConfig` (no font resolution, no UserDefaults, no derived chrome). The rule for the
//  ceiling is to find the seam rather than shave comments, and the comments are the point:
//  every branch below encodes a decision about what a *wrong* config should do, which is
//  the part a reader cannot reconstruct from the code.
//
//  Takes primitives rather than the `ThemeSpec` it is called with, because `ConfigFile` is
//  `private` in `Config.swift` on purpose — the on-disk shape should not leak into the rest
//  of the module — and Swift's `private` stops at the file edge. Passing five optionals
//  keeps that boundary intact and has the side benefit of making this callable from
//  anywhere, including a future gate, without constructing a Decodable.
//
//  THE INVARIANT THIS FILE OWNS: it never throws and never returns a half-built palette.
//  One bad hex costs that one field and appends one warning; a wrong preset name costs the
//  preset and appends one warning. Six bad fields yield six warnings and a working
//  terminal. Preserve that — `AppConfig.load()` has no error path to fall back on.
//

import AppKit

extension AppConfig {
    /// Resolve an auto-mode theme block. Always returns two real `Theme` values; never
    /// returns nil (falls back to defaults rather than leaving either slot empty).
    ///
    /// Defaults: dark = `classic-repaired`, light = `afk-light`.
    /// These are the same presets the task brief names and are chosen because:
    ///  - `classic-repaired` is the app's pinned default for dark environments.
    ///  - `afk-light` is the only measured light preset.
    ///
    /// A bad dark/light name degrades to the same default and appends one warning each.
    /// That is the same contract as `resolveTheme` for a bad preset: degradation, not
    /// failure, so a config with one bad auto sub-field still gives two working themes.
    static func resolveAutoTheme(dark: String?,
                                 light: String?,
                                 warnings: inout [String]) -> (dark: Theme, light: Theme) {
        let darkTheme: Theme
        if let name = dark {
            if let t = Theme.preset(named: name) {
                darkTheme = t
            } else {
                warnings.append("theme.dark '\(name)' unrecognised — using classic-repaired")
                darkTheme = .classicRepaired
            }
        } else {
            // Omitting `dark` in auto mode is fine — the default is well-defined.
            darkTheme = .classicRepaired
        }

        let lightTheme: Theme
        if let name = light {
            if let t = Theme.preset(named: name) {
                lightTheme = t
            } else {
                warnings.append("theme.light '\(name)' unrecognised — using afk-light")
                lightTheme = .afkLight
            }
        } else {
            lightTheme = .afkLight
        }

        return (dark: darkTheme, light: lightTheme)
    }

    /// Resolve a `theme` block. `nil` means "install no colours at all", which is what
    /// `"classic"` (and only `"classic"`) selects.
    ///
    /// - Parameter warnings: appended to, never read. Every degradation is reported.
    static func resolveTheme(preset: String?,
                             background: String?,
                             foreground: String?,
                             cursor: String?,
                             ansi: [String]?,
                             warnings: inout [String]) -> Theme? {
        // Pick the base. "classic" (and only "classic") stays nil, which is the one
        // setting that leaves the engine's own defaults genuinely untouched.
        let wantsClassic = preset?.lowercased() == "classic"

        // The base for a typo, and for an override with no preset, is `classic-repaired`
        // (changed 2026-08-20, was `umber` since 2026-08-03, was `afk-dark` before that).
        // Both are error-ish paths, and the fallback should be the default palette.
        var theme: Theme? = wantsClassic ? nil : (preset.flatMap(Theme.preset(named:)) ?? .classicRepaired)
        if let raw = preset, !wantsClassic, Theme.preset(named: raw) == nil {
            warnings.append("theme.preset '\(raw)' unrecognised — using classic-repaired")
        }

        // Any explicit colour needs a full palette to sit on; classic + an override cannot
        // stay nil, so promote it to a real base first.
        let hasOverride = background != nil || foreground != nil || cursor != nil || ansi != nil
        if theme == nil && hasOverride {
            warnings.append("theme.preset 'classic' cannot take colour overrides — using classic-repaired as the base")
            theme = .classicRepaired
        }

        // Optional-chained from here: if `theme` is still nil there are no overrides to
        // apply (the only case where both could be true was just promoted).
        if let raw = background {
            if let c = NSColor.fromHex(raw) { theme?.background = c }
            else { warnings.append("theme.background '\(raw)' is not a hex colour") }
        }
        if let raw = foreground {
            if let c = NSColor.fromHex(raw) {
                // A preset may separate quiet terminal text from readable document chrome,
                // but an explicit user override owns both surfaces unless a second config
                // field is ever added. Leaving chrome on the preset would make this field lie.
                theme?.foreground = c
                theme?.chromeForeground = c
            } else { warnings.append("theme.foreground '\(raw)' is not a hex colour") }
        }
        if let raw = cursor {
            if let c = NSColor.fromHex(raw) { theme?.cursor = c }
            else { warnings.append("theme.cursor '\(raw)' is not a hex colour") }
        }
        if let raw = ansi {
            // Exactly 16 or nothing: SwiftTerm's `installColors` silently no-ops on any
            // other length, so a wrong count must be rejected loudly here rather than
            // accepted and then ignored two layers down.
            if raw.count != 16 {
                warnings.append("theme.ansi needs exactly 16 colours, got \(raw.count) — keeping default palette")
            } else {
                let parsed = raw.compactMap { NSColor.fromHex($0) }
                // Atomic, unlike the three scalars above: a 15-good-one-bad array would
                // install a palette with one wrong slot and no way to see which, so the
                // whole array is discarded and the count of failures reported.
                if parsed.count == 16 {
                    theme?.ansi = parsed
                } else {
                    warnings.append("theme.ansi contains \(16 - parsed.count) unparseable colour(s) — keeping default palette")
                }
            }
        }
        return theme
    }
}
