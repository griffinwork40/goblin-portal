//
//  Config+Load.swift
//  The loader concern for `AppConfig`: `load()`, font resolution, and
//  the system-mono alias table.
//
//  Extracted from `Config.swift` at the 350-LOC ceiling. The seam is
//  "everything that reads the wire format (`ConfigFile`) and produces a
//  resolved `AppConfig`". `Config.swift` owns the types; this file owns
//  the decoding. `ConfigFile` is `internal` (not `private`) specifically
//  so this extension can decode it — nothing else in the module should
//  touch `ConfigFile` directly.
//

import AppKit

extension AppConfig {

    /// Resolve the user's config, falling back field-by-field.
    ///
    /// `@MainActor` because when auto mode is active (`"preset": "auto"`) this reads
    /// `NSApp.effectiveAppearance` via `AppearanceObserver.currentIsDark` to choose
    /// the initial palette. All callers are already `@MainActor` (`AppDelegate`).
    @MainActor static func load() -> AppConfig {
        var config = defaults()
        let url = configURL
        guard let data = try? Data(contentsOf: url) else {
            return config  // No config file is the normal case, not an error.
        }
        guard let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            config.warnings.append("\(url.path): not valid JSON — using defaults")
            return config
        }

        // Font. An out-of-range size is reported rather than silently clamped:
        // every other field in this file explains itself when it is ignored, and
        // a size that quietly did nothing is precisely the failure that makes a
        // configurable setting feel unconfigurable.
        var size = defaultFontSize
        if let requested = file.font?.size {
            if requested >= minFontSize && requested <= maxFontSize {
                size = requested
            } else {
                config.warnings.append(
                    "font.size \(requested) is outside \(Int(minFontSize))–\(Int(maxFontSize)) — using \(Int(size))")
            }
        }
        let resolvedFont = preferredMonoFont(family: file.font?.family, size: size)
        config.font = resolvedFont.font
        if let warning = resolvedFont.warning { config.warnings.append(warning) }

        // Theme. The whole per-field, fail-soft assembly lives in `Config+Theme.swift` —
        // pulled out when Config.swift hit the 350-line ceiling, because "which palette do
        // we install given some optional strings a user typed" is one whole concern and
        // needs nothing else in `AppConfig`. Primitives rather than the spec itself, so
        // `ConfigFile` stays internal to the loader rather than leaking into the rest of
        // the module.
        if let t = file.theme {
            if t.preset?.lowercased() == "auto" {
                // Auto mode: resolve both palettes now, store them for the observer, and
                // pick the initial theme from the current system appearance. The observer
                // in `AppearanceObserver` handles every subsequent switch.
                let auto = AppConfig.resolveAutoTheme(dark: t.dark,
                                                      light: t.light,
                                                      warnings: &config.warnings)
                config.autoTheme = auto
                config.theme = AppearanceObserver.currentIsDark ? auto.dark : auto.light
            } else {
                config.theme = AppConfig.resolveTheme(preset: t.preset,
                                                      background: t.background,
                                                      foreground: t.foreground,
                                                      cursor: t.cursor,
                                                      ansi: t.ansi,
                                                      warnings: &config.warnings)
            }
        }

        if let raw = file.cursor {
            // Same fail-soft shape as `renderer` below: an unrecognised value degrades to
            // the default and says so, rather than throwing. The spellings themselves moved
            // to `CursorStyle.named(_:)` so the mapping is compilable without AppKit.
            if let style = CursorStyle.named(raw) { config.cursorStyle = style }
            else { config.warnings.append("cursor '\(raw)' unrecognised — using block") }
        }

        if let sb = file.scrollback {
            if sb >= 0 { config.scrollback = sb }
            else { config.warnings.append("scrollback must be >= 0 — using \(config.scrollback)") }
        }
        if let sh = file.shell {
            // A newline in a shell path is rejected alongside non-executable: a legal macOS
            // filename containing one could cause subtle breakage if any downstream consumer
            // joins paths with newlines (config renderers, diagnostic output). Caught here so
            // the result is one fail-soft warning rather than silent corruption.
            if sh.contains(where: \.isNewline) {
                config.warnings.append("shell path contains a newline — using \(config.shell)")
            } else if FileManager.default.isExecutableFile(atPath: sh) { config.shell = sh }
            else { config.warnings.append("shell '\(sh)' is not executable — using \(config.shell)") }
        }
        if let meta = file.optionAsMeta { config.optionAsMeta = meta }
        if let mr = file.mouseReporting { config.mouseReporting = mr }
        if let raw = file.renderer {
            if let r = Renderer.named(raw) { config.renderer = r }
            else {
                config.warnings.append(
                    "renderer '\(raw)' unrecognised (expected one of: \(Renderer.configNames))"
                        + " — using \(config.renderer.configName)")
            }
        }
        if let v = file.fontThicken { config.fontThicken = v }
        if let v = file.lineHeight {
            let lo = 0.8, hi = 2.0
            if v >= lo && v <= hi { config.lineHeight = CGFloat(v) }
            else { config.warnings.append("lineHeight \(v) is outside \(lo)–\(hi) — using \(config.lineHeight)") }
        }
        // `ligatures` is accepted in the config file but not yet acted on — the field
        // is parsed here so the file stays valid when the feature ships. See the header
        // of TerminalPane+Typography.swift for why it is deferred.
        if file.ligatures != nil {
            config.warnings.append("ligatures: not yet implemented — ignored")
        }
        if let e = file.editor {
            config.applyEditor(tabWidth: e.tabWidth, softTabs: e.softTabs,
                               wordWrap: e.wordWrap,
                               indentRainbow: e.indentRainbow,
                               columnGuide: e.columnGuide,
                               showTrailingWhitespace: e.showTrailingWhitespace,
                               stickyScroll: e.stickyScroll)
        }
        if let p = file.padding {
            config.applyPadding(x: p.x, y: p.y)
        }
        if let op = file.unfocusedPaneOpacity {
            // Fail-soft: a value outside [0, 1] is nonsensical (a transparency cannot
            // be negative or exceed fully-opaque). Report it and keep the default (1.0)
            // rather than clamping silently — clamping would make a typo ("10" instead
            // of "1.0") look like success.
            if op >= 0.0 && op <= 1.0 {
                config.unfocusedPaneOpacity = op
            } else {
                config.warnings.append(
                    "unfocusedPaneOpacity \(op) is outside 0.0–1.0 — using 1.0 (no dimming)")
            }
        }
        return config
    }

    // MARK: - Font resolution

    /// Names people write in a config when they mean the system monospaced face.
    /// None of these resolve through `NSFont(name:)`, so they must be mapped.
    /// Internal (not `private`) so `defaults()` in `Config.swift` can call
    /// `preferredMonoFont` — both live in the same module but different files.
    static let systemMonoAliases: Set<String> = [
        "sf mono", "sfmono", "sfmono-regular", "sf mono regular", "system", "system mono",
    ]

    /// Resolve a monospaced font, reporting a human-readable problem when a
    /// requested family cannot be honoured. Never returns nil — a terminal with
    /// no font is not a useful failure mode.
    ///
    /// With nothing requested this returns the **system monospaced face**, which
    /// is SF Mono and is also exactly what SwiftTerm's own `FontSet.defaultFont`
    /// uses. It is deliberately NOT reached via `NSFont(name: "SF Mono")`: that
    /// call returns nil, because SF Mono is not registered under that name (nor
    /// under "SFMono-Regular"). v0.1 asked for it by name, silently got Menlo as
    /// the next candidate, and therefore rendered visibly worse than the Step 0
    /// spike — which set no font at all and so kept SwiftTerm's default. The
    /// system-mono call used to sit at the BOTTOM of this function, unreachable,
    /// because Menlo always resolves first.
    ///
    /// Internal (not `private`) so `defaults()` in `Config.swift` can call it —
    /// both live in the same module but different files.
    static func preferredMonoFont(family: String?, size: Double) -> (font: NSFont, warning: String?) {
        let systemMono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard let family, !systemMonoAliases.contains(family.lowercased()) else {
            return (systemMono, nil)
        }
        if let f = NSFont(name: family, size: size) { return (f, nil) }
        return (systemMono, "font.family '\(family)' unavailable — using the system monospaced face")
    }
}
