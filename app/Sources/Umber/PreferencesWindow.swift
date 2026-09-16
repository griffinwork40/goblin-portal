//
//  PreferencesWindow.swift
//  A native settings panel for the most common config fields.
//
//  Companion to the JSON config file, not a replacement: reads from and
//  writes to ~/.config/umber/config.json. Power users continue editing the
//  file directly; this window covers the settings most users reach for.
//
//  The split into PreferencesWindow.swift (this file, controller + state)
//  and PreferencesWindow+Layout.swift (form construction, helpers) keeps
//  both files under the 350-LOC ceiling.
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
    let fontThickenCheck  = NSButton(checkboxWithTitle: "Font dilation (thicken)",
                                     target: nil, action: nil)
    let rendererPopup    = NSPopUpButton()

    // MARK: - Config string tables
    //
    // themePresets kept in sync with ThemePalette.configNames. "auto" is
    // listed first as a friendly option; "classic" (SwiftTerm's own defaults)
    // is always last.
    let themePresets: [String] = ["auto"] + ThemePalette.all.map(\.name) + ["classic"]

    // Config-file spellings that CursorStyle.named(_:) accepts as canonical.
    let cursorStyleKeys: [String] = [
        "block", "steady-block",
        "bar", "steady-bar",
        "underline", "steady-underline",
    ]

    // MARK: - Init

    convenience init() {
        // NSPanel so ⌘, can stay open while other windows are in front.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Umber Settings"
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

        // Theme
        let preset = (dict["theme"] as? [String: Any])?["preset"] as? String ?? "classic-repaired"
        let themeTitle = themePresets.contains(preset) ? preset : "classic-repaired"
        themePopup.selectItem(withTitle: themeTitle)

        // Cursor
        let cursorRaw = dict["cursor"] as? String ?? "block"
        // Normalise to a canonical key; fall back to "block" if unrecognised.
        let cursorTitle = cursorStyleKeys.contains(cursorRaw) ? cursorRaw : "block"
        cursorPopup.selectItem(withTitle: cursorTitle)

        // Scrollback
        let scrollback = dict["scrollback"] as? Int ?? 1_000
        scrollbackField.integerValue = scrollback

        // Checkboxes
        let optMeta = dict["optionAsMeta"] as? Bool ?? true
        optionAsMetaCheck.state = optMeta ? .on : .off

        let thicken = dict["fontThicken"] as? Bool ?? false
        fontThickenCheck.state = thicken ? .on : .off

        // Renderer
        let rendRaw = dict["renderer"] as? String ?? "coretext"
        let rendTitle: String
        switch rendRaw.lowercased() {
        case "metal", "gpu": rendTitle = "metal"
        default:             rendTitle = "coretext"
        }
        rendererPopup.selectItem(withTitle: rendTitle)
    }

    // MARK: - Save

    /// Write changed fields back into config.json, then trigger a live reload.
    ///
    /// Option 1 + Option 2 from issue #71:
    ///   • Skip the write entirely when nothing the user controls has changed.
    ///     This prevents both an unnecessary reloadConfig call AND any risk of
    ///     disturbing the comment-key ordering in the starter template.
    ///   • When a real change IS made, strip comment-keys before writing so the
    ///     round-trip through JSONSerialization (which uses .sortedKeys) never
    ///     scrambles the "// key" grouping again.  The starter template's comments
    ///     have served their purpose once the user has opened this window and saved.
    @objc func saveValues() {
        let existing = rawConfigDict() ?? [:]

        // Build the new dict from control state.
        var newDict = existing

        // Font
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
        if fontDict.isEmpty { newDict.removeValue(forKey: "font") }
        else { newDict["font"] = fontDict }

        // Theme
        var themeDict = existing["theme"] as? [String: Any] ?? [:]
        let themeSelected = themePopup.titleOfSelectedItem ?? "classic-repaired"
        themeDict["preset"] = themeSelected
        // When the preset is "auto", the theme block also holds "dark" and "light"
        // sub-keys that name which palette to install per system appearance. These are
        // not surfaced as controls in this window (the popup only sets the preset), so
        // they must be carried forward from whatever is already on disk — otherwise a
        // round-trip through Apply silently discards the user's per-appearance choices.
        if themeSelected == "auto", let existing = existing["theme"] as? [String: Any] {
            if let dark  = existing["dark"]  { themeDict["dark"]  = dark  }
            if let light = existing["light"] { themeDict["light"] = light }
        }
        newDict["theme"] = themeDict

        // Cursor
        newDict["cursor"] = cursorPopup.titleOfSelectedItem ?? "block"

        // Scrollback
        let sb = scrollbackField.integerValue
        if sb >= 0 { newDict["scrollback"] = sb }

        // Booleans
        newDict["optionAsMeta"] = optionAsMetaCheck.state == .on
        newDict["fontThicken"]  = fontThickenCheck.state  == .on

        // Renderer
        newDict["renderer"] = rendererPopup.titleOfSelectedItem ?? "coretext"

        // Skip the write if nothing the Preferences window controls has changed.
        // This leaves the on-disk file (including comment-key ordering) untouched
        // when the user opens the panel and closes it without changing anything.
        guard prefsValuesChanged(from: existing, to: newDict) else { return }

        // Strip comment-keys before serialising: they only make sense in the
        // hand-formatted starter template; once we re-write the file as
        // pretty-printed JSON the sorted ordering would scramble them anyway.
        let clean = newDict.filter { !$0.key.hasPrefix("//") }
        writeConfigDict(clean)

        // Apply immediately — same path as ⌘R.
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.reloadConfig(nil)
        }
    }

    /// Returns true when any Preferences-controlled value differs between the two dicts.
    ///
    /// Compares only the keys this window manages.  Unknown user-added keys are
    /// intentionally ignored so they do not accidentally block a real save.
    private func prefsValuesChanged(
        from old: [String: Any],
        to new: [String: Any]
    ) -> Bool {
        // Font family
        var oldFamily = (old["font"] as? [String: Any])?["family"] as? String ?? ""
        if oldFamily.isEmpty || oldFamily.hasPrefix("SF Mono") { oldFamily = "" }
        var newFamily = (new["font"] as? [String: Any])?["family"] as? String ?? ""
        if newFamily.isEmpty || newFamily.hasPrefix("SF Mono") { newFamily = "" }
        if oldFamily != newFamily { return true }

        // Font size
        let oldSize = (old["font"] as? [String: Any])?["size"] as? Double ?? AppConfig.defaultFontSize
        let newSize = (new["font"] as? [String: Any])?["size"] as? Double ?? AppConfig.defaultFontSize
        if oldSize != newSize { return true }

        // Theme preset
        let oldPreset = (old["theme"] as? [String: Any])?["preset"] as? String ?? "classic-repaired"
        let newPreset = (new["theme"] as? [String: Any])?["preset"] as? String ?? ""
        if oldPreset != newPreset { return true }

        // Cursor
        let oldCursor = old["cursor"] as? String ?? ""
        let newCursor = new["cursor"] as? String ?? ""
        if oldCursor != newCursor { return true }

        // Scrollback
        let oldScroll = old["scrollback"] as? Int ?? AppConfig.defaults().scrollback
        let newScroll = new["scrollback"] as? Int ?? AppConfig.defaults().scrollback
        if oldScroll != newScroll { return true }

        // optionAsMeta
        let oldMeta = old["optionAsMeta"] as? Bool ?? true
        let newMeta = new["optionAsMeta"] as? Bool ?? true
        if oldMeta != newMeta { return true }

        // fontThicken
        let oldThicken = old["fontThicken"] as? Bool ?? false
        let newThicken = new["fontThicken"] as? Bool ?? false
        if oldThicken != newThicken { return true }

        // Renderer
        let oldRenderer = old["renderer"] as? String ?? ""
        let newRenderer = new["renderer"] as? String ?? ""
        if oldRenderer != newRenderer { return true }

        return false
    }

    /// Open config.json in the system editor — the power-user escape hatch.
    @objc func openConfigFile(_ sender: Any?) {
        NSWorkspace.shared.open(AppConfig.configURL)
    }

    // MARK: - JSON helpers

    /// Read ~/.config/umber/config.json as a plain dictionary.
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
