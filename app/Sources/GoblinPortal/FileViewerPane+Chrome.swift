//
//  FileViewerPane+Chrome.swift
//  Editor chrome: status bar and the config-wiring that applies theme colours to
//  EditorTextView, EditorStatusBar, and the FileViewerPane.
//
//  `EditorTextView` (current-line highlight, column guide, indent rainbow,
//  trailing-whitespace dots) lives in `EditorTextView.swift`, extracted when
//  this file reached 392 LOC. The seam is clean: EditorTextView.swift owns
//  "how the text area draws itself"; this file owns "how the pane wires it up".
//

import AppKit

// MARK: - Status bar

/// A thin bar below the editor showing cursor position, language, encoding, and
/// indent mode. Follows the CotEditor / BBEdit pattern of a single informational
/// line at the bottom.
@MainActor
final class EditorStatusBar: NSView {
    private let label = NSTextField(labelWithString: "")

    /// The pane updates these properties; the bar redraws.
    var line: Int = 1
    var column: Int = 1
    var language: String = "Plain Text"
    var encoding: String = "UTF-8"
    var indentMode: String = "Spaces: 4"

    static let barHeight: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        label.stringValue = "Ln \(line), Col \(column)  ·  \(language)  ·  \(encoding)  ·  \(indentMode)"
    }

    func applyTheme(background: NSColor, foreground: NSColor, isLight: Bool) {
        // A slightly lifted background separates the bar from the editor body.
        // On dark themes blend toward white (lift); on light themes blend toward
        // black (darken) — blending toward white on a light background produces
        // a bar indistinguishable from the editor itself.
        wantsLayer = true
        layer?.backgroundColor = background.blended(
            withFraction: 0.07, of: isLight ? .black : .white)?.cgColor ?? background.cgColor
        // 0.72 — the same alpha proven safe for all three gated themes by
        // `check-theme-contrast-harness.swift` (§5j, ALPHA_INACTIVE). At the
        // original 0.55, umber measured APCA Lc ~44 on the status bar background,
        // below the Lc 45 floor the repo enforces for readable text.
        label.textColor = foreground.withAlphaComponent(0.72)
    }
}

// MARK: - FileViewerPane chrome wiring

extension FileViewerPane {
    /// Push theme colours into the editor text view's chrome layers.
    /// Called from `apply(config:)` in `+Document.swift`.
    func applyChrome(config: AppConfig) {
        let bg = config.effectiveBackground
        let fg = config.effectiveForeground
        // Current-line highlight: 4% white lift on dark backgrounds, 4% black lift on light.
        let isLight = config.appearance?.name == .aqua
        textView.currentLineColor = bg.blended(
            withFraction: 0.04, of: isLight ? .black : .white) ?? bg
        textView.columnGuideColor = fg.withAlphaComponent(0.08)
        textView.trailingWhitespaceColor = fg.withAlphaComponent(0.15)
        textView.insertionPointColor = config.theme?.cursor ?? fg
        // Indent rainbow + column guide + trailing whitespace from config.
        textView.indentRainbow = config.indentRainbow
        textView.tabWidthForRainbow = config.tabWidth
        textView.columnGuide = config.columnGuideColumn
        textView.showTrailingWhitespace = config.showTrailingWhitespace
        statusBar?.applyTheme(background: bg, foreground: fg, isLight: isLight)
        updateStatusBar()
    }

    /// Coalesce rapid-fire selection changes into one status bar refresh at the
    /// end of the run-loop turn, so auto-indent/auto-pair pay the cost once.
    func scheduleStatusBarUpdate() {
        pendingStatusBarUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateStatusBar() }
        pendingStatusBarUpdate = work
        DispatchQueue.main.async(execute: work)
    }

    /// Invalidate the cached line-start offsets so the next `updateStatusBar`
    /// rebuilds them. Called from `textDidChange` in `+SmartEditing.swift`.
    func invalidateLineStartCache() {
        lineStartCache = nil
    }

    /// O(n) once per edit — cursor movements reuse until `invalidateLineStartCache`.
    private func buildLineStartCache(for str: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        while i < str.length {
            let range = str.lineRange(for: NSRange(location: i, length: 0))
            let next = NSMaxRange(range)
            // Record the start of the following line; skip if we're at the end
            // of an unterminated final line (next == str.length, no more lines).
            if next > i, next < str.length { starts.append(next) }
            i = next > i ? next : i + 1  // guard against zero-width ranges
        }
        return starts
    }

    /// Refresh the status bar with current cursor position and file metadata.
    /// Called via `scheduleStatusBarUpdate()` on every selection change and on
    /// config reload.
    ///
    /// Uses a cached line-start index (built once per edit, O(n)) and binary
    /// search (O(log n) per cursor move) instead of walking from offset 0 on
    /// every call. At the 4 MiB file cap (~83k lines), this avoids 83k
    /// `lineRange` calls per keystroke — the cost flagged in the PR #45 review.
    func updateStatusBar() {
        guard let bar = statusBar else { return }
        let str = textView.string as NSString
        let loc = textView.selectedRange().location
        let clampedLoc = min(loc, str.length)

        // Build the line-start cache on first call after an edit (or load).
        let starts = lineStartCache ?? buildLineStartCache(for: str)
        lineStartCache = starts

        // Binary search: find the last line whose start offset <= clampedLoc.
        // `starts` is sorted ascending. `upperBound - 1` gives the line index.
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= clampedLoc { lo = mid + 1 } else { hi = mid }
        }
        let lineIdx = lo - 1  // 0-based index into `starts`
        let line = lineIdx + 1  // 1-based for display
        let col = clampedLoc - starts[lineIdx] + 1

        bar.line = line
        bar.column = col

        // Language from file extension.
        if languageForExtension(url.pathExtension) != nil {
            bar.language = Self.displayName(for: url.pathExtension)
        } else {
            bar.language = "Plain Text"
        }

        // Encoding.
        switch savedEncoding {
        case .utf8: bar.encoding = "UTF-8"
        case .utf16: bar.encoding = "UTF-16"
        case .isoLatin1: bar.encoding = "Latin-1"
        default: bar.encoding = "UTF-8"
        }

        // Indent mode.
        bar.indentMode = config.softTabs ? "Spaces: \(config.tabWidth)" : "Tabs: \(config.tabWidth)"

        bar.refresh()
    }

    /// Human-readable language name for the status bar.
    private static func displayName(for ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "Swift"
        case "js", "jsx", "mjs", "cjs": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "py": return "Python"
        case "rb": return "Ruby"
        case "c", "h": return "C"
        case "cpp", "cc", "cxx", "hpp", "hxx": return "C++"
        case "rs": return "Rust"
        case "go": return "Go"
        case "java": return "Java"
        case "kt", "kts": return "Kotlin"
        case "css": return "CSS"
        case "scss": return "SCSS"
        case "less": return "Less"
        case "json", "jsonc": return "JSON"
        case "sh", "bash": return "Shell"
        case "zsh": return "Zsh"
        case "fish": return "Fish"
        case "yml", "yaml": return "YAML"
        case "toml": return "TOML"
        case "html", "htm": return "HTML"
        case "xml": return "XML"
        case "svg": return "SVG"
        case "md", "markdown", "mdx": return "Markdown"
        // Wave 2 additions
        case "lua": return "Lua"
        case "php": return "PHP"
        case "dart": return "Dart"
        case "ex": return "Elixir"
        case "exs": return "Elixir Script"
        case "pl", "pm": return "Perl"
        case "hs", "lhs": return "Haskell"
        case "scala", "sc": return "Scala"
        case "r": return "R"
        case "rmd", "rmarkdown": return "R Markdown"
        default: return ext.uppercased()
        }
    }
}
