//
//  ConfigWarningPolicy.swift
//  What the config-warnings banner says, and whether it shows at all (#166, T1.5).
//
//  `AppConfig.load()` fails soft per field and explains every degradation in
//  `config.warnings` (Config+Load.swift; AFK.md "Config parsing fails soft"). Until
//  T1.5 those explanations went to stderr only (`AppDelegate.swift:44-46` and
//  `:262-264` before this change), so anyone who launched from Finder or the Dock had
//  no stderr to read: a typo in `config.json` simply did nothing, which is the exact
//  "a setting that quietly did nothing" failure Config+Load.swift's font comment calls
//  out as the one that makes configuration feel broken.
//
//  Its own file and Foundation-only for the reason `PasteGuardPolicy.swift` and
//  `CommandOutcome.swift` are: the interesting part is a *policy* — a pure function
//  of the warning list — and a pure function compiles headless (`check-config-warnings.sh`)
//  while the AppKit banner (`ConfigWarningBanner.swift`) cannot. The gate compiles THIS
//  file, not a restatement of it.
//
//  WHAT LIVES HERE: the show/hide decision, de-duplication, the title (counted after
//  de-duplication, with a separate title for the whole-file rejection), how many lines
//  are visible before "and N more", and `~` abbreviation of the home directory so the
//  banner does not print the user's absolute path. WHAT DOES NOT: drawing, buttons,
//  which windows get it — all in `ConfigWarningBanner.swift`.
//

import Foundation

enum ConfigWarningPolicy {
    /// Lines shown in the banner before the rest collapse into "and N more". Three
    /// keeps the bar to roughly the height of two terminal rows' worth of chrome
    /// above the terminal — tall enough to say what was ignored, short enough that a
    /// config with a dozen bad fields does not push the terminal off the window. The
    /// full list is always available in the banner's tooltip (`Banner.fullText`).
    static let maxVisibleLines = 3

    /// The text `AppConfig.load()` emits when the whole file fails to decode.
    /// Built here, not in Config+Load.swift, so the banner can recognise it without
    /// matching a string literal that lives in another file: `check-config-warnings.sh`
    /// greps Config+Load.swift to confirm the loader still calls this builder, so the
    /// whole-file title cannot silently stop firing if the wording is edited.
    static func invalidJSONWarning(path: String) -> String {
        "\(path): \(invalidJSONMarker) — using defaults"
    }

    /// The fragment `isWholeFileRejection` looks for. One constant shared by the
    /// builder above and the recogniser below, so the two cannot drift apart.
    static let invalidJSONMarker = "not valid JSON"

    /// True for the one warning that means EVERY setting was ignored, not one field.
    /// That case deserves a different title: "1 warning" would understate it badly.
    static func isWholeFileRejection(_ warning: String) -> Bool {
        warning.contains(invalidJSONMarker)
    }

    /// Everything the banner needs to render, already worded.
    struct Banner: Equatable {
        /// One line, bold in the banner.
        let title: String
        /// At most `maxVisibleLines` warnings, de-duplicated and home-abbreviated.
        let lines: [String]
        /// How many further warnings were not shown in `lines` (0 when none).
        let overflow: Int
        /// Every de-duplicated warning, newline-joined — the tooltip.
        let fullText: String
    }

    /// What the presenter should do after a load (launch, ⌘R, Settings Apply).
    enum Action: Equatable {
        /// Show (or replace) the banner with this content.
        case show(Banner)
        /// Remove any banner: this load was clean, so a banner left over from an
        /// earlier bad load would now be describing a problem the user already fixed.
        case hide
    }

    /// Decide what the banner should do for one load's warnings.
    ///
    /// Called on every load event, never cached: the banner describes the CURRENT
    /// file. A dismissed banner therefore comes back on the next ⌘R / Apply if the
    /// problem is still there — dismissal means "not now", and the next reload is the
    /// user asking again. A clean load always hides it.
    ///
    /// - Parameter home: the user's home directory path, replaced by `~` wherever a
    ///   warning embeds it (today: the invalid-JSON warning names the full config path).
    static func action(for warnings: [String], home: String) -> Action {
        let unique = deduplicated(warnings).map { abbreviatingHome($0, home: home) }
        guard !unique.isEmpty else { return .hide }  // HIDE-WHEN-CLEAN
        let title: String
        if unique.contains(where: isWholeFileRejection) {
            title = "config.json is not valid JSON — every setting was ignored, using defaults"
        } else {
            title = unique.count == 1
                ? "config.json: 1 setting was not applied as written"
                : "config.json: \(unique.count) settings were not applied as written"
        }
        let visible = Array(unique.prefix(maxVisibleLines))
        return .show(Banner(title: title,
                            lines: visible,
                            overflow: unique.count - visible.count,
                            fullText: unique.joined(separator: "\n")))
    }

    /// Order-preserving de-duplication, dropping blank entries.
    ///
    /// Why duplicates are possible at all: auto mode resolves its dark and light
    /// palettes through the same per-field resolvers (`Config+Theme.swift`), and a
    /// future caller that merges two warning lists would double-count. The title's
    /// count must be the number of distinct problems, not the number of appends.
    static func deduplicated(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in warnings {
            let w = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, seen.insert(w).inserted else { continue }  // DEDUP-RULE
            out.append(w)
        }
        return out
    }

    /// Replace `home` with `~` where it starts a path component, and only there.
    ///
    /// The boundary check matters: a naive `replacingOccurrences(of: home, ...)` turns
    /// `/Users/ann2/x` into `~2/x` when home is `/Users/ann`. Only `home` followed by
    /// `/` (or at the end of the string) is the home directory.
    static func abbreviatingHome(_ text: String, home: String) -> String {
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty, text.contains(trimmedHome) else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: trimmedHome) {
            let after = rest[range.upperBound...]
            result += rest[..<range.lowerBound]
            if after.isEmpty || after.hasPrefix("/") {  // HOME-BOUNDARY-RULE
                result += "~"
            } else {
                result += rest[range]
            }
            rest = after
        }
        result += rest
        return result
    }
}
