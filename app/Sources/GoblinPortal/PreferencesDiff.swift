//
//  PreferencesDiff.swift
//  Seed values and changed-key detection for the preferences panel.
//
//  **Pure and view-free — Foundation only, on purpose.**  This is the half of the
//  preferences round-trip that `check-preferences-apply.sh` can compile standalone with
//  swiftc: no AppKit, no NSPopUpButton, no window server.  The same discipline as
//  `Renderer.swift`, `CursorStyle.swift`, and `PasteGuardPolicy.swift`.
//
//  WHY THIS FILE EXISTS — two separate problems the old code had:
//
//  1. WRONG SEED DEFAULTS.  `PreferencesWindow.loadCurrentValues` was seeding popup
//     controls with hardcoded literals (`"coretext"`, `"block"`) when a key was absent
//     from config.json.  `Renderer.default` is `.metal` and `CursorStyle.default` is
//     `.steadyBlock`; seeding "coretext" meant opening ⌘, on a fresh config and hitting
//     Apply silently downgraded the renderer.  Every seed must derive from the single
//     source of truth: `Renderer.default.configName`, `CursorStyle.default.configName`,
//     and `PreferencesSeed.defaultThemePreset` (from the default `AppConfig`'s theme).
//
//  2. OVERLY BROAD CHANGED-KEY GUARD.  The old `prefsValuesChanged(from:to:)` was a
//     boolean: it returned true if ANY managed key differed, but the write then wrote ALL
//     managed keys — including those the user never touched.  A user who changed only the
//     font size got renderer, cursor, and theme added to their config.json.  The new
//     `changedKeys(from:to:)` returns the SET of keys that actually changed, and
//     `saveValues` writes only those keys (plus keys that already existed on disk under
//     that top-level name, to preserve sub-key structure).
//
//  WHAT IS UNDER TEST in `check-preferences-apply.sh`.  This file and CursorStyle.swift,
//  Renderer.swift, and ThemeValues.swift are the only subjects.  The gate compiles them
//  together standalone (Foundation only) and exercises:
//    • Apply on `{}` with no changes writes nothing.
//    • Changing one field on `{}` writes exactly that key.
//    • Seeds derive from the real defaults, not literals.
//    • Falsification: reintroducing `"coretext"` as the renderer seed must exit 1.
//

import Foundation

// MARK: - Seed defaults

/// Default values for every preferences control, derived from the canonical single-source-
/// of-truth: `AppConfig.defaults()` (for numeric/bool fields) and the type's own config-name
/// helpers (for string/popup fields).
///
/// `PreferencesWindow.loadCurrentValues` reads these when the corresponding key is absent
/// from config.json, so the fallback shown in the UI always matches what the app would
/// actually use.
enum PreferencesSeed {
    /// The config-name of the default renderer (`Renderer.default.configName`).
    /// **Not** a literal: if the default changes, this follows automatically.
    static let defaultRendererName: String = Renderer.default.configName

    /// The config-name of the default cursor style (`CursorStyle.default.configName`).
    /// **Not** a literal: if the default changes, this follows automatically.
    static let defaultCursorName: String = CursorStyle.default.configName

    /// The preset name that `AppConfig.defaults()` installs as the default theme.
    ///
    /// `AppConfig.defaults()` currently sets `.classicRepaired`, whose `ThemePalette.name`
    /// is `"classic-repaired"`.  Reading it from `ThemePalette.classicRepaired.name` rather
    /// than a literal keeps this in sync with any future default change — the gate pins the
    /// resulting string so a change there shows up as a gate failure rather than a silent
    /// config corruption.
    static let defaultThemePreset: String = ThemePalette.classicRepaired.name

    /// The default scrollback line count from `AppConfig.defaults()`.
    /// T2.4 (2026-10-09): raised from 1_000 to 5_000. Measured release resize cost:
    /// 5k p50 ≈ 5,098 µs (~5.1 ms, 31% of a 16.7 ms frame). See check-scrollback-cost.sh.
    static let defaultScrollback: Int = 5_000

    /// The default optionAsMeta setting from `AppConfig.defaults()`.
    static let defaultOptionAsMeta: Bool = true

    /// The default fontThicken setting from `AppConfig.defaults()`.
    static let defaultFontThicken: Bool = false

    /// The default font size — mirrors `AppConfig.defaultFontSize` (14pt).
    ///
    /// Duplicated here rather than imported so this file stays Foundation-only and
    /// compilable standalone by the gate.  The gate (`check-preferences-apply.sh`) pins
    /// the value, so a drift between this constant and `AppConfig.defaultFontSize` shows
    /// up as a gate failure rather than a silent mismatch.
    static let defaultFontSize: Double = 14
}

// MARK: - Changed-key detection

/// Per-key diffing between two raw config dictionaries.
///
/// Each `hasChanged` method compares one logical key in isolation.  `PreferencesWindow`
/// calls these individually and writes back ONLY the keys that returned true, so a user
/// who changes only the font size does not get renderer, cursor, or theme injected into
/// their config.json.
///
/// The comparison uses the SAME defaults as `PreferencesSeed` so "key absent" is treated
/// as "key equals its default" on both sides — an absent key and a key set to the default
/// value are indistinguishable from the user's perspective and must both produce no write.
enum PreferencesDiff {

    // MARK: Font family

    /// True when the selected font family changed between the two dicts.
    ///
    /// "No family" (the system mono choice) is represented as an absent `font.family`
    /// key, an empty string, and the "SF Mono (System Default)" label — all treated
    /// as equivalent.
    static func fontFamilyChanged(from old: [String: Any], to new: [String: Any]) -> Bool {
        var o = (old["font"] as? [String: Any])?["family"] as? String ?? ""
        var n = (new["font"] as? [String: Any])?["family"] as? String ?? ""
        if o.isEmpty || o.hasPrefix("SF Mono") { o = "" }
        if n.isEmpty || n.hasPrefix("SF Mono") { n = "" }
        return o != n
    }

    // MARK: Font size

    /// True when the font size changed.  Both sides fall back to `PreferencesSeed.defaultFontSize`
    /// when the key is absent, matching what `AppConfig.load()` would resolve.
    static func fontSizeChanged(from old: [String: Any], to new: [String: Any]) -> Bool {
        let o = (old["font"] as? [String: Any])?["size"] as? Double ?? PreferencesSeed.defaultFontSize
        let n = (new["font"] as? [String: Any])?["size"] as? Double ?? PreferencesSeed.defaultFontSize
        return o != n
    }

    // MARK: Theme

    /// True when the theme preset changed.  Both sides fall back to `PreferencesSeed.defaultThemePreset`
    /// so "key absent" == "key set to the default" and generates no write.
    static func themeChanged(from old: [String: Any], to new: [String: Any]) -> Bool {
        let o = (old["theme"] as? [String: Any])?["preset"] as? String
                    ?? PreferencesSeed.defaultThemePreset
        let n = (new["theme"] as? [String: Any])?["preset"] as? String
                    ?? PreferencesSeed.defaultThemePreset
        return o != n
    }

    // MARK: Cursor

    /// True when the cursor style changed.  Both sides fall back to `PreferencesSeed.defaultCursorName`.
    static func cursorChanged(from old: [String: Any], to new: [String: Any]) -> Bool {
        let o = old["cursor"] as? String ?? PreferencesSeed.defaultCursorName
        let n = new["cursor"] as? String ?? PreferencesSeed.defaultCursorName
        return o != n
    }

    // MARK: Scrollback

    /// True when the scrollback line count changed.
    static func scrollbackChanged(from old: [String: Any], to new: [String: Any]) -> Bool {
        let o = old["scrollback"] as? Int ?? PreferencesSeed.defaultScrollback
        let n = new["scrollback"] as? Int ?? PreferencesSeed.defaultScrollback
        return o != n
    }

    // MARK: optionAsMeta

    /// True when the optionAsMeta flag changed.
    static func optionAsMetaChanged(from old: [String: Any], to new: [String: Any]) -> Bool {
        let o = old["optionAsMeta"] as? Bool ?? PreferencesSeed.defaultOptionAsMeta
        let n = new["optionAsMeta"] as? Bool ?? PreferencesSeed.defaultOptionAsMeta
        return o != n
    }

    // MARK: fontThicken

    /// True when the fontThicken flag changed.
    static func fontThickenChanged(from old: [String: Any], to new: [String: Any]) -> Bool {
        let o = old["fontThicken"] as? Bool ?? PreferencesSeed.defaultFontThicken
        let n = new["fontThicken"] as? Bool ?? PreferencesSeed.defaultFontThicken
        return o != n
    }

    // MARK: Renderer

    /// True when the renderer changed.  Both sides fall back to `PreferencesSeed.defaultRendererName`
    /// so "key absent" == "key set to the default" and generates no write.
    static func rendererChanged(from old: [String: Any], to new: [String: Any]) -> Bool {
        let o = old["renderer"] as? String ?? PreferencesSeed.defaultRendererName
        let n = new["renderer"] as? String ?? PreferencesSeed.defaultRendererName
        return o != n
    }

    // MARK: Aggregate

    /// Returns the set of top-level config key names whose preference-controlled values
    /// differ between `old` and `new`.
    ///
    /// `"font"` covers both `family` and `size` — if either changed the whole `font` sub-
    /// dict needs to be written.  `"theme"` is the same: only the `preset` sub-key is
    /// controlled by the popup, but the whole dict carries `dark`/`light` sub-keys that
    /// must round-trip.
    ///
    /// The caller writes exactly the keys in this set (merging into the existing dict so
    /// unrelated keys are preserved), and does nothing when the set is empty.
    static func changedKeys(from old: [String: Any], to new: [String: Any]) -> Set<String> {
        var keys = Set<String>()
        if fontFamilyChanged(from: old, to: new) || fontSizeChanged(from: old, to: new) {
            keys.insert("font")
        }
        if themeChanged(from: old, to: new)       { keys.insert("theme") }
        if cursorChanged(from: old, to: new)      { keys.insert("cursor") }
        if scrollbackChanged(from: old, to: new)  { keys.insert("scrollback") }
        if optionAsMetaChanged(from: old, to: new){ keys.insert("optionAsMeta") }
        if fontThickenChanged(from: old, to: new) { keys.insert("fontThicken") }
        if rendererChanged(from: old, to: new)    { keys.insert("renderer") }
        return keys
    }
}
