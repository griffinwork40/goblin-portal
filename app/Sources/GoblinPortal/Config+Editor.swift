//
//  Config+Editor.swift
//  Turning a config file's `editor` block into resolved settings, fail-soft.
//
//  Its own file for the same reason as `Config+Theme.swift`: `Config.swift` is at
//  the 350-line ceiling and this is a clean seam. Everything here is one question —
//  "given some optional values a user typed, which editing behaviours do we install?"
//  — and answering it needs none of the font/theme/engine machinery in `AppConfig`.
//
//  Takes primitives rather than `EditorSpec` because `ConfigFile` is `private` in
//  `Config.swift`. Passing three optionals keeps that boundary intact.
//
//  THE INVARIANT THIS FILE OWNS: it never throws. A bad value costs that one field
//  and appends one warning. Preserve that — `AppConfig.load()` has no error path.
//

import Foundation

/// How soft-wrap behaves. `auto` wraps markdown/prose and not code, which is the
/// right default because reflowing indented code is nonsense and reflowing prose
/// paragraphs is essential.
enum WordWrapMode: String {
    case auto
    case on
    case off

    /// Generous parsing: accepts any case, and common aliases.
    static func named(_ raw: String) -> WordWrapMode? {
        switch raw.lowercased() {
        case "auto":                    return .auto
        case "on", "yes", "true":       return .on
        case "off", "no", "false":      return .off
        default:                        return nil
        }
    }

    /// The canonical name shown in warnings and in the starter config.
    static let configNames = "auto | on | off"
}

extension AppConfig {
    /// Resolve the `editor` block from config primitives, fail-soft per field.
    /// Mutates `self` directly and appends to `warnings` for any degradations.
    mutating func applyEditor(tabWidth: Int?, softTabs: Bool?, wordWrap: String?,
                              indentRainbow: Bool? = nil,
                              columnGuide: Int? = nil,
                              showTrailingWhitespace: Bool? = nil,
                              stickyScroll: Bool? = nil) {
        if let raw = tabWidth {
            if raw >= 1 && raw <= 16 { self.tabWidth = raw }
            else { warnings.append("editor.tabWidth \(raw) out of range 1–16 — using 4") }
        }
        if let st = softTabs { self.softTabs = st }
        if let raw = wordWrap {
            if let m = WordWrapMode.named(raw) { self.wordWrap = m }
            else {
                warnings.append(
                    "editor.wordWrap '\(raw)' unrecognised"
                    + " (expected one of: \(WordWrapMode.configNames)) — using auto")
            }
        }
        if let ir = indentRainbow { self.indentRainbow = ir }
        if let cg = columnGuide {
            // 0 means "disable the guide" — a user's explicit opt-out.
            // Any other positive value is the column to mark.
            // Negative values are rejected with a warning.
            if cg < 0 {
                warnings.append("editor.columnGuide \(cg) must be >= 0 — keeping current value")
            } else if cg == 0 {
                self.columnGuideColumn = nil   // 0 → disabled
            } else {
                self.columnGuideColumn = cg
            }
        }
        if let tw = showTrailingWhitespace { self.showTrailingWhitespace = tw }
        if let ss = stickyScroll { self.stickyScroll = ss }
    }
}
