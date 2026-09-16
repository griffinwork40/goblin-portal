//
//  FileViewerPane+BlockReHighlight.swift
//  Block-comment boundary detection for the Wave 2 multi-line re-highlight fix.
//
//  Owns three private helpers that `FileViewerPane+Highlighting.swift` calls from
//  `highlightEditedParagraph` to decide whether to expand the re-highlight window
//  beyond the edited paragraph:
//
//    · `hasBlockComments(_:)`          — does the language have multi-line delimiters?
//    · `containsBlockDelimiter(_:family:)` — is the edited line near a delimiter?
//    · `mightBeInsideBlockComment(_:family:)` — could this line be inside an open block?
//
//  Extracted from `+Highlighting.swift` when that file reached 480 LOC, over the
//  350-LOC ceiling. The seam is clean: this file owns the "where do I need to look?"
//  heuristics; `+Highlighting.swift` owns "how do I paint what I find?".
//

// NOTE: These are `internal` (no access modifier) free functions, intentionally —
// they are called from `FileViewerPane+Highlighting.swift` in the same module.
// `FileViewerPane` extensions cannot declare stored properties; the helpers here
// are stateless and operate on their arguments only.

import Foundation   // LanguageFamily is Foundation-only (no AppKit needed here)

// MARK: - Block-comment delimiter detection

/// Returns true when the language family uses block comment delimiters that can
/// span paragraph boundaries — i.e. families where an edit near `/*`, `*/`,
/// `{-`, `-}`, `--[[`, or `]]` requires expanding the re-highlight window
/// beyond the single edited paragraph.
///
/// Shell and Markdown have no multi-line comment syntax, so they always return false.
func hasBlockComments(_ family: LanguageFamily) -> Bool {
    switch family {
    case .cLike, .haskell, .lua, .html, .python, .ruby: return true
    case .shell, .markdown: return false
    }
}

/// Returns true when the given paragraph-range text contains a block-comment
/// delimiter (opener or closer) for the family. Used to decide whether to expand
/// the re-highlight window in `highlightEditedParagraph`.
///
/// The check is conservative: a false positive only widens the re-highlight window,
/// not produces wrong colours. A false negative would leave mis-coloured text after
/// an edit near a delimiter, which is the original bug this fixes.
func containsBlockDelimiter(_ text: String, family: LanguageFamily) -> Bool {
    switch family {
    case .cLike:
        return text.contains("/*") || text.contains("*/")
    case .python:
        return text.contains("\"\"\"") || text.contains("'''")
    case .ruby:
        return text.hasPrefix("=begin") || text.hasPrefix("=end")
    case .haskell:
        return text.contains("{-") || text.contains("-}")
    case .lua:
        return text.contains("--[[") || text.contains("]]")
    case .html:
        return text.contains("<!--") || text.contains("-->")
    case .shell, .markdown:
        return false
    }
}

/// Heuristic: could this line be the continuation of an open block comment?
/// Returns true when the line contains no closer AND either contains an opener
/// or looks like plain continuation text (no recognisable statement-start marker).
///
/// This is intentionally conservative — false positives only cause a slightly
/// wider re-highlight window, not wrong colours.
func mightBeInsideBlockComment(_ line: String, family: LanguageFamily) -> Bool {
    switch family {
    case .cLike:
        // Contains a closer → we are back outside.
        if line.contains("*/") { return false }
        // Contains an opener → we may be entering or spanning one.
        if line.contains("/*") { return true }
        // A line starting with `*` (continuation style) or with only whitespace
        // could be inside a block comment.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("*") || trimmed.isEmpty
    case .python:
        return line.contains("\"\"\"") || line.contains("'''")
    case .haskell:
        if line.contains("-}") { return false }
        if line.contains("{-") { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
    case .lua:
        if line.contains("]]") { return false }
        if line.contains("--[[") { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
    case .html:
        if line.contains("-->") { return false }
        if line.contains("<!--") { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
    case .ruby:
        return line.hasPrefix("=begin") || line.hasPrefix("=end")
    case .shell, .markdown:
        return false
    }
}
