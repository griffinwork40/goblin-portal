// check-preferences-apply-harness.swift
// Swift assertions compiled by check-preferences-apply.sh.
//
// Exercises PreferencesDiff + PreferencesSeed against the shipped CursorStyle,
// Renderer, and ThemeValues files (all Foundation-only).  The shell script
// compiles all four shipped files together with this harness and links no AppKit.
//
// Split from the shell script because the combined shell + inline Swift exceeded
// the 350-LOC ceiling — same pattern as check-git-status-harness.swift.

import Foundation

var bad = 0

func fail(_ label: String, _ detail: String) {
    print("  FAIL \(label): \(detail)")
    bad += 1
}

// MARK: - Seed default assertions

// Case S1: renderer seed derives from Renderer.default.configName, not from "coretext".
// Renderer.default is .metal; its configName is "metal".
let rendererSeed = PreferencesSeed.defaultRendererName
if rendererSeed != Renderer.default.configName {
    fail("S1 renderer seed",
         "PreferencesSeed.defaultRendererName is '\(rendererSeed)', "
         + "but Renderer.default.configName is '\(Renderer.default.configName)'")
}
if rendererSeed == "coretext" {
    fail("S1 renderer seed literal",
         "renderer seed is the literal 'coretext' — must derive from Renderer.default.configName")
}

// Case S2: cursor seed derives from CursorStyle.default.configName, not from "block".
// CursorStyle.default is .steadyBlock; its configName is "steady-block".
let cursorSeed = PreferencesSeed.defaultCursorName
if cursorSeed != CursorStyle.default.configName {
    fail("S2 cursor seed",
         "PreferencesSeed.defaultCursorName is '\(cursorSeed)', "
         + "but CursorStyle.default.configName is '\(CursorStyle.default.configName)'")
}
if cursorSeed == "block" {
    fail("S2 cursor seed literal",
         "cursor seed is the literal 'block' (blinking) — "
         + "CursorStyle.default is .steadyBlock whose configName is 'steady-block'")
}

// Case S3: theme seed derives from ThemePalette.classicRepaired.name.
let themeSeed = PreferencesSeed.defaultThemePreset
if themeSeed != ThemePalette.classicRepaired.name {
    fail("S3 theme seed",
         "PreferencesSeed.defaultThemePreset is '\(themeSeed)', "
         + "but ThemePalette.classicRepaired.name is '\(ThemePalette.classicRepaired.name)'")
}

// Case S4: CursorStyle.configName round-trips via named(_:) for all 6 cases.
for style in CursorStyle.allCases {
    guard let round = CursorStyle.named(style.configName) else {
        fail("S4 configName roundtrip",
             "CursorStyle.named('\(style.configName)') returned nil"); continue
    }
    if round != style {
        fail("S4 configName roundtrip",
             "named('\(style.configName)') → .\(round), expected .\(style)")
    }
}

// MARK: - No-op cases

// Case C1: Apply on {} with no changes → empty changedKeys.
let emptyChanged = PreferencesDiff.changedKeys(from: [:], to: [:])
if !emptyChanged.isEmpty {
    fail("C1 no-op on empty dicts",
         "changedKeys returned \(emptyChanged) — expected empty set")
}

// Case C2: Proposed dict at default values vs {} → no changed keys.
// "Absent key" must equal "key set to its default" on both sides.
let defaultsProposed: [String: Any] = [
    "renderer":    PreferencesSeed.defaultRendererName,
    "cursor":      PreferencesSeed.defaultCursorName,
    "theme":       ["preset": PreferencesSeed.defaultThemePreset],
    "scrollback":  PreferencesSeed.defaultScrollback,
    "optionAsMeta": PreferencesSeed.defaultOptionAsMeta,
    "fontThicken": PreferencesSeed.defaultFontThicken,
]
let defaultsChanged = PreferencesDiff.changedKeys(from: [:], to: defaultsProposed)
if !defaultsChanged.isEmpty {
    fail("C2 default-value dict vs empty",
         "changedKeys returned \(defaultsChanged.sorted()) — expected empty set")
}

// Case C3: Identical existing and proposed dicts → no changed keys.
let same: [String: Any] = ["renderer": "coretext", "cursor": "bar", "scrollback": 5_000]
if !PreferencesDiff.changedKeys(from: same, to: same).isEmpty {
    fail("C3 identical dicts", "changedKeys non-empty for identical input dicts")
}

// MARK: - Single-key change cases

// D1: changing only renderer → {"renderer"}
let d1 = PreferencesDiff.changedKeys(from: [:], to: ["renderer": "coretext"])
if d1 != ["renderer"] {
    fail("D1 renderer-only change", "changedKeys = \(d1.sorted()), expected [\"renderer\"]")
}

// D2: changing only cursor → {"cursor"}
let d2 = PreferencesDiff.changedKeys(from: [:], to: ["cursor": "bar"])
if d2 != ["cursor"] {
    fail("D2 cursor-only change", "changedKeys = \(d2.sorted()), expected [\"cursor\"]")
}

// D3: changing only scrollback to a non-default value → {"scrollback"}.
// Uses 10_000 (not the 5_000 default) so that changedKeys reports a real change.
// When the default was 1_000, this test used 5_000; updated when T2.4 raised
// the default to 5_000 (Config.swift:284, PreferencesSeed.defaultScrollback).
let d3 = PreferencesDiff.changedKeys(from: [:], to: ["scrollback": 10_000])
if d3 != ["scrollback"] {
    fail("D3 scrollback-only change", "changedKeys = \(d3.sorted()), expected [\"scrollback\"]")
}

// D4: changing only theme → {"theme"}
let d4 = PreferencesDiff.changedKeys(from: [:], to: ["theme": ["preset": "umber"]])
if d4 != ["theme"] {
    fail("D4 theme-only change", "changedKeys = \(d4.sorted()), expected [\"theme\"]")
}

// D5: changing only fontThicken → {"fontThicken"}
let d5 = PreferencesDiff.changedKeys(from: [:], to: ["fontThicken": true])
if d5 != ["fontThicken"] {
    fail("D5 fontThicken-only change", "changedKeys = \(d5.sorted()), expected [\"fontThicken\"]")
}

// D6: changing only optionAsMeta → {"optionAsMeta"} (default is true; false is a change)
let d6 = PreferencesDiff.changedKeys(from: [:], to: ["optionAsMeta": false])
if d6 != ["optionAsMeta"] {
    fail("D6 optionAsMeta-only change", "changedKeys = \(d6.sorted()), expected [\"optionAsMeta\"]")
}

// MARK: - Unrelated key preservation

// Case P1: changedKeys must not surface user-added keys it does not manage.
let withCustom: [String: Any] = [
    "myCustomKey": "someValue",
    "renderer": PreferencesSeed.defaultRendererName,   // same → no change
]
let customChanged = PreferencesDiff.changedKeys(from: withCustom, to: withCustom)
if customChanged.contains("myCustomKey") {
    fail("P1 unrelated key", "'myCustomKey' must never appear in changedKeys")
}
if !customChanged.isEmpty {
    fail("P1 no change when values equal", "changedKeys = \(customChanged.sorted())")
}

// MARK: - Summary

if bad == 0 {
    print("  ok  seed: renderer from Renderer.default.configName (not 'coretext')")
    print("  ok  seed: cursor from CursorStyle.default.configName (not 'block')")
    print("  ok  seed: theme from ThemePalette.classicRepaired.name")
    print("  ok  seed: CursorStyle.configName round-trips via named(_:) for all 6 cases")
    print("  ok  no-op: empty {} vs {} → no changed keys")
    print("  ok  no-op: default-value dict vs {} → no changed keys")
    print("  ok  no-op: identical dicts → no changed keys")
    print("  ok  diff: renderer-only change → {renderer}")
    print("  ok  diff: cursor-only change → {cursor}")
    print("  ok  diff: scrollback-only change → {scrollback}")
    print("  ok  diff: theme-only change → {theme}")
    print("  ok  diff: fontThicken-only change → {fontThicken}")
    print("  ok  diff: optionAsMeta-only change → {optionAsMeta}")
    print("  ok  preserve: unrelated keys not surfaced in changedKeys")
    print("\nall preferences-apply cases passed (4 seed + 3 no-op + 6 diff + 1 preserve)")
} else {
    print("\n\(bad) preferences-apply case(s) FAILED")
}
exit(bad == 0 ? 0 : 1)
