//
//  TerminalPane+Typography.swift
//  Font sizing, zoom, and typography controls (thicken, line height).
//
//  Extracted from `TerminalPane.swift` when it reached 346/350 LOC and three new
//  typography config fields needed a home. The font/zoom concern is one whole unit:
//  the clamping constants, `setFontSize`, `adjustFontSize`, `resetFontSize`, and the
//  `currentFontSize` reader all read from or write to `fontSize` and must agree on the
//  bounds — so they move together, not piecemeal.
//
//  NEW: `applyTypography(_:)` applies `fontThicken` and `lineHeight` from `AppConfig`.
//  It is called from `apply(config:)` after the font is set, because `lineSpacing`
//  internally calls `resetFont()`, which itself calls `computeFontDimensions()` and
//  `processSizeChange` — both of which need the font already installed on the view.
//
//  LIGATURES — NOT IMPLEMENTED. SwiftTerm builds its attributed strings in
//  `AppleTerminalView.getAttributes(_:withUrl:)` and caches them in a per-attribute
//  dictionary (`attributes`, `urlAttributes`). Adding `kCTLigatureAttributeName: 0`
//  to those dictionaries would disable OpenType ligature substitution. However, those
//  dictionaries are private `var`s on `TerminalView`, with no public setter and no
//  hook that lets a caller inject additional attributes into the cache. The only way to
//  control ligature formation from outside the class is to clear the cache
//  (`resetCaches()`) and hope the next fill picks up a changed setting — but there is
//  no public setter that clears the cache *and* re-fills with a different ligature
//  attribute. A vendored patch adding `var disableLigatures: Bool` to `TerminalView`
//  and threading it into `getAttributes(_:withUrl:)` would be the correct fix.
//  Patching the vendor carries merge cost, and this project already has seven patches.
//  Since the default terminal behaviour is ligature-off for most monospaced fonts
//  (SF Mono and Menlo ship no programming ligatures at all; only Fira Code and JetBrains
//  Mono do, and those are opt-in font choices), the feature is omitted rather than
//  half-implemented.
//

import AppKit
import SwiftTerm

// MARK: - Font sizing (extracted from TerminalPane.swift)

extension TerminalPane {
    static let minFontSize = CGFloat(AppConfig.minFontSize)
    static let maxFontSize = CGFloat(AppConfig.maxFontSize)

    /// Moved to `AppConfig.resized(_:to:)` when `FileViewerPane` needed the same
    /// descriptor-preserving resize — see there for why `NSFont(name:size:)` is
    /// wrong. Kept as a shim so the call sites below stay readable.
    func resized(_ base: NSFont, to size: CGFloat) -> NSFont {
        AppConfig.resized(base, to: size)
    }

    /// `persist: false` is for applying someone else's already-stored zoom (a
    /// reload, or a newly-opened tab) — only a real user gesture should write.
    func setFontSize(_ size: CGFloat, persist: Bool = true) {
        let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
        fontSize = clamped
        view.font = resized(config.font, to: clamped)
        if persist {
            // Store nothing when the zoom lands back on the configured size, so
            // editing `font.size` later still takes effect instead of being
            // permanently masked by a stale override.
            FontZoom.override = clamped == config.font.pointSize ? nil : clamped
        }
    }

    func adjustFontSize(by delta: CGFloat) { setFontSize(fontSize + delta) }

    /// ⌘0 — back to the configured size, dropping the stored zoom.
    func resetFontSize() {
        FontZoom.override = nil
        setFontSize(config.font.pointSize, persist: false)
    }

    /// The size this pane is currently rendering at, so a zoom applied in one tab
    /// can be mirrored into the others.
    var currentFontSize: CGFloat { fontSize }
}

// MARK: - Typography controls

extension TerminalPane {
    /// Apply `fontThicken` and `lineHeight` from `config` to the view.
    ///
    /// Called from `apply(config:)` AFTER the font is installed. `lineSpacing`
    /// internally calls `resetFont()` → `computeFontDimensions()` → `processSizeChange`,
    /// all of which need the font already live on the view, so call order is critical.
    ///
    /// `fontThicken` is applied by registering `view` as a thickening-draw delegate
    /// (see `GoblinPortalTerminalView.fontThicken`). The actual private-API call lives in
    /// `GoblinPortalTerminalView.draw(_:)` so the context is always the right one for the
    /// draw call in progress.
    func applyTypography(_ config: AppConfig) {
        // Line height: 1.0 = natural metrics; 1.2 = 20% extra leading.
        // `lineSpacing` is @objc open on TerminalView (AppleTerminalView.swift:127)
        // and multiplies (ascent + descent + leading) before `ceil()`. Setting it
        // to a value equal to the current one is a no-op in the setter body — the
        // guard at AppleTerminalView.swift:131 skips `resetFont()` when unchanged —
        // so this is safe to call on every ⌘R without thrashing the terminal layout.
        if view.lineSpacing != config.lineHeight {
            view.lineSpacing = config.lineHeight
        }

        // Font thickening: hand the flag to the view, which applies the private API
        // in its own draw(_:) override where the CGContext is live.
        view.fontThicken = config.fontThicken
    }
}
