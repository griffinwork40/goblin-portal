//
//  PreferencesWindow.swift
//  A native settings panel for the most common config fields.
//
//  Companion to the JSON config file, not a replacement: reads from and
//  writes to ~/.config/goblin-portal/config.json. Power users continue editing the
//  file directly; this window covers the settings most users reach for.
//
//  The split into PreferencesWindow.swift (this file, controller + state)
//  and PreferencesWindow+Layout.swift (form construction, helpers) keeps
//  both files under the 350-LOC ceiling.
//
//  SEED DEFAULTS: every control is seeded from the canonical single source of truth —
//  `Renderer.default.configName`, `CursorStyle.default.configName`, and
//  `PreferencesSeed.defaultThemePreset` — rather than hardcoded literals.  The old code
//  used `?? "coretext"` and `?? "block"`, which silently downgraded a fresh config on
//  every Apply because `Renderer.default` is `.metal` and `CursorStyle.default` is
//  `.steadyBlock`.
//
//  WRITE ONLY CHANGED KEYS: `saveValues` now calls `PreferencesDiff.changedKeys(from:to:)`
//  and writes only the keys whose value actually changed.  The old code wrote ALL managed
//  keys whenever ANY key changed, so a user who changed only font size got renderer,
//  cursor, and theme injected into their config.json.
//

import AppKit

@MainActor
final class PreferencesWindow: NSWindowController {

    // MARK: - Controls (populated in setupUI; read in saveValues)

    let fontFamilyPopup  = NSPopUpButton()
    let fontSizeField    = NSTextField()
    let themePopup       = NSPopUpButton()
    let cursorPopup      = NSPopUpButton()
    let scrollbackField  = NSTextField()
    let optionAsMetaCheck = NSButton(checkboxWithTitle: "Option as Meta",
                                     target: nil, action: nil)
    // fontThickenCheck removed (#152): CGContextSetFontSmoothingStyle is a no-op on
    // macOS 15+. The key is still parsed from config.json (fail-soft) and warned on.
    let rendererPopup    = NSPopUpButton()

    // MARK: - Config string tables
    //
    // themePresets kept in sync with ThemePalette.configNames. "auto" is
    // listed first as a friendly option; "classic" (SwiftTerm's own defaults)
    // is always last.
    let themePresets: [String] = ["auto"] + ThemePalette.all.map(\.name) + ["classic"]

    // Derived from CursorStyle.allCases so adding a new case automatically extends
    // the popup — no manual sync required. The gate (check-preferences-apply.sh)
    // asserts the seeded default comes from CursorStyle.default.configName, which
    // is always one of these values.
    let cursorStyleKeys: [String] = CursorStyle.allCases.map(\.configName)

    // MARK: - Init

    convenience init() {
        // NSPanel so ⌘, can stay open while other windows are in front.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Goblin Portal Settings"
        // Singleton — retain the panel between shows.
        panel.isReleasedWhenClosed = false
        // Non-resizable: layout is designed for exactly this size.
        panel.styleMask.remove(.resizable)
        panel.center()
        self.init(window: panel)
        setupUI()          // build the form (in +Layout.swift)
        loadCurrentValues()
    }

    // MARK: - Load

    /// Read config.json and populate every control.
    ///
    /// Uses JSONSerialization (not ConfigFile.decode) so unknown keys that the
    /// user added by hand are preserved when we write back — see `saveValues`.
    ///
    /// KEY SEEDING: every absent key falls back to the real app default via
    /// `PreferencesSeed.*` rather than a literal.  This matters because the
    /// preferences popup must show the value the app would actually use, not a
    /// stale guess — and hitting Apply after seeing "coretext" must not write
    /// "coretext" if the real default is "metal".
    func loadCurrentValues() {
        let dict = rawConfigDict() ?? [:]

        // Font family
        let family = (dict["font"] as? [String: Any])?["family"] as? String ?? ""
        let systemLabel = "SF Mono (System Default)"
        if family.isEmpty || AppConfig.systemMonoAliases.contains(family.lowercased()) {
            fontFamilyPopup.selectItem(withTitle: systemLabel)
        } else {
            // Add the family if it isn't already in the list (user may have typed
            // an exotic name directly in the file).
            if fontFamilyPopup.item(withTitle: family) == nil {
                fontFamilyPopup.addItem(withTitle: family)
            }
            fontFamilyPopup.selectItem(withTitle: family)
        }

        // Font size
        let size = (dict["font"] as? [String: Any])?["size"] as? Double
                   ?? AppConfig.defaultFontSize
        fontSizeField.stringValue = "\(Int(size))"

        // Theme — absent key seeds from PreferencesSeed.defaultThemePreset
        // (ThemePalette.classicRepaired.name), NOT from a literal "classic-repaired".
        let preset = (dict["theme"] as? [String: Any])?["preset"] as? String
                     ?? PreferencesSeed.defaultThemePreset
        let themeTitle = themePresets.contains(preset) ? preset : PreferencesSeed.defaultThemePreset
        themePopup.selectItem(withTitle: themeTitle)

        // Cursor — absent key seeds from CursorStyle.default.configName ("steady-block"),
        // NOT from the literal "block" which maps to the BLINKING block cursor.
        let cursorRaw = dict["cursor"] as? String ?? PreferencesSeed.defaultCursorName
        let cursorTitle = cursorStyleKeys.contains(cursorRaw) ? cursorRaw
                          : PreferencesSeed.defaultCursorName
        cursorPopup.selectItem(withTitle: cursorTitle)

        // Scrollback
        let scrollback = dict["scrollback"] as? Int ?? PreferencesSeed.defaultScrollback
        scrollbackField.integerValue = scrollback

        // Checkboxes
        let optMeta = dict["optionAsMeta"] as? Bool ?? PreferencesSeed.defaultOptionAsMeta
        optionAsMetaCheck.state = optMeta ? .on : .off

        // fontThicken checkbox removed (#152): no-op on macOS 15+.

        // Renderer — absent key seeds from Renderer.default.configName ("metal"),
        // NOT from the literal "coretext".  The old literal silently downgraded every
        // fresh config because Renderer.default is .metal (check-metal-throughput.sh
        // measures Metal no worse than CoreText by more than 35%).
        let rendRaw = dict["renderer"] as? String ?? PreferencesSeed.defaultRendererName
        let rendTitle = Renderer.named(rendRaw)?.configName ?? PreferencesSeed.defaultRendererName
        rendererPopup.selectItem(withTitle: rendTitle)
    }

    // MARK: - Save

    /// Write ONLY the changed fields back into config.json, then trigger a live reload.
    ///
    /// The old code wrote all managed keys whenever any key changed, so a user who only
    /// changed font size got renderer, cursor, and theme added to config.json.  This
    /// version uses `PreferencesDiff.changedKeys(from:to:)` to find exactly which keys
    /// differ, builds partial sub-dicts for those keys, and merges them into the existing
    /// dict — leaving every other key (including user-added unknown keys and comment-keys)
    /// untouched.
    ///
    /// Early-return cases:
    ///   • If the changed-key set is empty, nothing is written (file and mtime are intact).
    ///   • Comment-keys (`"// ..."`) are stripped before writing, same as before, because
    ///     JSONSerialization's .sortedKeys ordering would scramble them anyway.
    @objc func saveValues() {
        let existing = rawConfigDict() ?? [:]

        // Build the full proposed dict (used for diffing, not for writing directly).
        let proposed = buildProposedDict(from: existing)

        // Find exactly which top-level keys changed.
        let changed = PreferencesDiff.changedKeys(from: existing, to: proposed)
        guard !changed.isEmpty else { return }

        // Merge only the changed keys into the existing dict, so unrelated keys survive.
        var merged = existing
        for key in changed {
            if let value = proposed[key] {
                merged[key] = value
            } else {
                merged.removeValue(forKey: key)
            }
        }

        // Strip comment-keys before serialising: they only make sense in the
        // hand-formatted starter template; once we re-write the file as
        // pretty-printed JSON the sorted ordering would scramble them anyway.
        let clean = merged.filter { !$0.key.hasPrefix("//") }
        writeConfigDict(clean)

        // Apply immediately — same path as ⌘R.
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.reloadConfig(nil)
        }
    }

    /// Construct the proposed full dict from the current control state.
    ///
    /// This always builds the complete picture so `PreferencesDiff.changedKeys` can
    /// compare it against the existing file.  Only keys in the changed set are ever
    /// written to disk; everything else is discarded after the diff.
    private func buildProposedDict(from existing: [String: Any]) -> [String: Any] {
        var d = existing

        // Font — merge into existing font sub-dict to preserve any user-added font keys.
        var fontDict = existing["font"] as? [String: Any] ?? [:]
        let selectedFamily = fontFamilyPopup.titleOfSelectedItem ?? ""
        if selectedFamily.isEmpty || selectedFamily.hasPrefix("SF Mono") {
            fontDict.removeValue(forKey: "family")   // omit = system mono
        } else {
            fontDict["family"] = selectedFamily
        }
        let sizeText = fontSizeField.stringValue.trimmingCharacters(in: .whitespaces)
        if let sizeVal = Double(sizeText),
           sizeVal >= AppConfig.minFontSize && sizeVal <= AppConfig.maxFontSize {
            fontDict["size"] = sizeVal
        }
        if fontDict.isEmpty { d.removeValue(forKey: "font") }
        else { d["font"] = fontDict }

        // Theme
        var themeDict = existing["theme"] as? [String: Any] ?? [:]
        let themeSelected = themePopup.titleOfSelectedItem ?? PreferencesSeed.defaultThemePreset
        themeDict["preset"] = themeSelected
        // When the preset is "auto", carry forward the dark/light sub-keys that name
        // which palette to install per system appearance — they are not surfaced as
        // controls in this window, so a round-trip through Apply must not discard them.
        if themeSelected == "auto", let ex = existing["theme"] as? [String: Any] {
            if let dark  = ex["dark"]  { themeDict["dark"]  = dark  }
            if let light = ex["light"] { themeDict["light"] = light }
        } else {
            themeDict.removeValue(forKey: "dark")
            themeDict.removeValue(forKey: "light")
        }
        d["theme"] = themeDict

        // Cursor — use the canonical config name from the popup selection.
        // No literal fallback: the popup is seeded from cursorStyleKeys which are all
        // valid CursorStyle.configName values, so titleOfSelectedItem is always one of them.
        d["cursor"] = cursorPopup.titleOfSelectedItem ?? PreferencesSeed.defaultCursorName

        // Scrollback
        let sb = scrollbackField.integerValue
        if sb >= 0 { d["scrollback"] = sb }

        // Booleans
        d["optionAsMeta"] = optionAsMetaCheck.state == .on
        // fontThicken omitted: no UI control (#152). Existing configs retain their value
        // unmodified (PreferencesDiff only writes keys that appear in `d`).

        // Renderer — use the canonical config name; no literal fallback.
        d["renderer"] = rendererPopup.titleOfSelectedItem ?? PreferencesSeed.defaultRendererName

        return d
    }

    /// Open config.json in the system editor — the power-user escape hatch.
    @objc func openConfigFile(_ sender: Any?) {
        NSWorkspace.shared.open(AppConfig.configURL)
    }

    // MARK: - JSON helpers

    /// Read ~/.config/goblin-portal/config.json as a plain dictionary.
    /// Returns nil when the file does not exist or is not valid JSON.
    func rawConfigDict() -> [String: Any]? {
        guard let data = try? Data(contentsOf: AppConfig.configURL),
              let obj  = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict
    }

    /// Atomically write a dictionary back to config.json as pretty-printed JSON.
    private func writeConfigDict(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        let url = AppConfig.configURL
        // Create the parent directory if this is a first run.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
