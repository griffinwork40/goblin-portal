//
//  DiffViewerPane+Highlighting.swift
//  Side-by-side diff rendering: attributed strings for both panes.
//
//  Owns the single public entry point `renderDiff(_:)`, which converts a
//  `FileDiff` (from `DiffParser`) into two `NSAttributedString` values and
//  installs them into `leftTextView` and `rightTextView`.
//
//  Line-number alignment contract
//  ───────────────────────────────
//  Added lines appear ONLY in the right view; the left view receives a blank
//  grey placeholder line to preserve vertical alignment between the two sides.
//  Removed lines appear ONLY in the left view; the right view gets a placeholder.
//  Context lines appear in both views (with matching old/new numbers).
//  Hunk-header lines appear in both views (no line number, full-width blue band).
//
//  Colour choices (all alpha-blended, no opaque backgrounds)
//  ──────────────────────────────────────────────────────────
//  Added   → systemGreen  ×0.15 (right only)
//  Removed → systemRed    ×0.15 (left only)
//  Hunk    → systemBlue   ×0.10 (both sides)
//  Placeholder → clear with 0.04 grey overlay (opposite side of a change)
//

import AppKit

// MARK: - Colour constants (file-private)

private let addedBG      = NSColor.systemGreen.withAlphaComponent(0.15)
private let removedBG    = NSColor.systemRed.withAlphaComponent(0.15)
private let hunkBG       = NSColor.systemBlue.withAlphaComponent(0.10)
private let placeholderBG = NSColor.black.withAlphaComponent(0.04)

// MARK: - Rendering

extension DiffViewerPane {
    /// Build attributed strings from a parsed `FileDiff` and install them.
    ///
    /// Called from the main queue after a background diff parse completes.
    /// Handles binary files, empty diffs, and renames correctly.
    func renderDiff(_ fileDiff: FileDiff) {
        if fileDiff.isBinary {
            let msg = "Binary file — no textual diff available."
            let attrs: [NSAttributedString.Key: Any] = [
                .font: monoFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let str = NSAttributedString(string: msg, attributes: attrs)
            leftTextView.textStorage?.setAttributedString(str)
            rightTextView.textStorage?.setAttributedString(NSAttributedString())
            return
        }

        if fileDiff.hunks.isEmpty {
            let msg = "No textual differences."
            let attrs: [NSAttributedString.Key: Any] = [
                .font: monoFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let str = NSAttributedString(string: msg, attributes: attrs)
            leftTextView.textStorage?.setAttributedString(str)
            rightTextView.textStorage?.setAttributedString(str)
            return
        }

        // Update the header bar paths from the parsed diff (handles renames).
        if let old = fileDiff.oldPath {
            oldPathLabel.stringValue = (old as NSString).lastPathComponent
        }
        if let new = fileDiff.newPath {
            newPathLabel.stringValue = (new as NSString).lastPathComponent
        }

        let (leftStr, rightStr) = buildAttributedStrings(for: fileDiff)
        leftTextView.textStorage?.setAttributedString(leftStr)
        rightTextView.textStorage?.setAttributedString(rightStr)
    }

    // MARK: - String construction

    private func buildAttributedStrings(
        for fileDiff: FileDiff
    ) -> (NSMutableAttributedString, NSMutableAttributedString) {
        let left  = NSMutableAttributedString()
        let right = NSMutableAttributedString()

        for hunk in fileDiff.hunks {
            appendHunkHeader(hunk, to: left)
            appendHunkHeader(hunk, to: right)
            for line in hunk.lines {
                appendLine(line, side: .left,  to: left)
                appendLine(line, side: .right, to: right)
            }
        }

        return (left, right)
    }

    // MARK: - Hunk header

    private func appendHunkHeader(_ hunk: DiffHunk, to str: NSMutableAttributedString) {
        let header = hunk.functionContext.map { "\(hunk.header)  \($0)" } ?? hunk.header
        let lineStr = header + "\n"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: NSColor.systemBlue.withAlphaComponent(0.85),
            .backgroundColor: hunkBG,
        ]
        str.append(NSAttributedString(string: lineStr, attributes: attrs))
    }

    // MARK: - Per-line appending

    private enum Side { case left, right }

    private func appendLine(
        _ line: DiffLine, side: Side, to str: NSMutableAttributedString
    ) {
        switch line.kind {
        case .context:
            // Both sides show the context line with the appropriate number.
            let num = side == .left ? line.oldLineNumber : line.newLineNumber
            str.append(lineString(line.text, lineNum: num, bg: nil))

        case .added:
            if side == .right {
                str.append(lineString(line.text, lineNum: line.newLineNumber, bg: addedBG))
            } else {
                // Left side gets a grey placeholder to keep vertical alignment.
                str.append(placeholderLine())
            }

        case .removed:
            if side == .left {
                str.append(lineString(line.text, lineNum: line.oldLineNumber, bg: removedBG))
            } else {
                // Right side gets a grey placeholder.
                str.append(placeholderLine())
            }

        case .noNewline:
            // Shown on both sides as an informational footnote.
            let text = "⏎ No newline at end of file"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: monoFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            str.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
    }

    // MARK: - Line string helpers

    /// A single rendered diff line: gutter number + content + trailing newline.
    ///
    /// The gutter is rendered in `.tertiaryLabelColor` at the same monospaced
    /// font as the content so columns align exactly. `lineNum == nil` produces
    /// a blank gutter (used for added lines shown in the left pane — no old
    /// line number exists).
    private func lineString(
        _ content: String,
        lineNum: Int?,
        bg: NSColor?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let gutterStr = lineNum.map { String(format: "%4d  ", $0) } ?? "      "

        var gutterAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        if let bg { gutterAttrs[.backgroundColor] = bg }

        var contentAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: config.effectiveForeground,
        ]
        if let bg { contentAttrs[.backgroundColor] = bg }

        result.append(NSAttributedString(string: gutterStr,     attributes: gutterAttrs))
        result.append(NSAttributedString(string: content + "\n", attributes: contentAttrs))
        return result
    }

    /// A blank, subtly-tinted placeholder line that occupies vertical space on
    /// the opposite side of a change, preserving alignment between the two panes.
    private func placeholderLine() -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: NSColor.clear,
            .backgroundColor: placeholderBG,
        ]
        // One space + newline so the line has non-zero height and the background
        // colour paints the full row rather than collapsing to a zero-height rect.
        return NSAttributedString(string: " \n", attributes: attrs)
    }

    // MARK: - Font accessor

    /// The monospaced font at the current zoom level.
    ///
    /// Derived from `config.font` so that the configured face (SF Mono, Menlo,
    /// JetBrains Mono, …) carries through to the diff view exactly as it does to
    /// the file viewer and the terminal. `AppConfig.resized` preserves the resolved
    /// descriptor rather than re-resolving by name, which is the correct path for
    /// the dot-prefixed system font (see `Config.swift:240`).
    private var monoFont: NSFont {
        AppConfig.resized(config.font, to: fontSize)
    }

}
