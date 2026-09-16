//
//  SymbolOutline.swift
//  Regex-based symbol extraction for the ⌘⇧O jump-to-symbol feature.
//
//  Owns the pure-Foundation extraction logic:
//    · `Symbol` — a (name, line, kind) tuple.
//    · `SymbolKind` — the kind of symbol (function, type, property, heading).
//    · `extractSymbols(from:family:)` — regex engine, no AppKit.
//
//  The AppKit panel that displays and navigates these symbols lives in
//  `SymbolOutlinePanel.swift`, extracted when this file reached 438 LOC.
//  The seam is clean: this file answers "what symbols are in this text?"
//  and the panel file answers "how do I show and navigate them?".
//
//  **Why regex and not LSP.** Consistent with the tokeniser in `SyntaxTokeniser.swift`:
//  no external process, no protocol overhead, no IPC. A regex that matches `func`,
//  `class`, `def`, etc. gets the 90% correct in zero latency.
//
//  **Language coverage.** Patterns exist for every `LanguageFamily` the highlighter
//  knows. Unknown extensions produce an empty symbol list (the right answer).
//

import AppKit

// MARK: - File-level regex cache

/// Cached compiled regular expressions for `symbolsMatching` and the markdown heading
/// pattern. Avoiding per-call `NSRegularExpression` init eliminates recompilation on
/// every ⌘⇧O invocation. `nonisolated(unsafe)` is safe: `extractSymbols` only runs
/// on the main actor via `FileViewerPane.showSymbolOutline`.
private nonisolated(unsafe) var symbolRegexCache: [String: NSRegularExpression] = [:]

// MARK: - Symbol extraction (pure, Foundation-only)

/// A single extractable symbol from a source file.
struct Symbol {
    let name: String
    let line: Int           // 1-based
    let kind: SymbolKind
}

enum SymbolKind {
    case function
    case method
    case type        // class, struct, enum, protocol, trait, interface …
    case property    // var, let, const, val at file/module scope
    case heading     // markdown headings
}

/// Extract symbols from `text` for the given language family.
/// Returns symbols in source order (by line number).
/// Returns an empty array for unknown or plain-text files — never throws.
func extractSymbols(from text: String, family: LanguageFamily) -> [Symbol] {
    let lines = text.components(separatedBy: "\n")
    var result: [Symbol] = []

    switch family {
    case .cLike:
        // cLike covers Swift, JS/TS, Go, Rust, Java, Kotlin, C, C++, CSS.
        // We catch the highest-value patterns: type declarations, function/method
        // definitions, and top-level property declarations.
        //
        // Swift: `func name(`, `var name`, `let name`, `class/struct/enum/protocol Name`
        // JS/TS: `function name(`, `class Name`, `const/let name =`, `async function`
        // Rust: `fn name(`, `struct/enum/impl/trait Name`
        // Go: `func name(`, `type Name`
        // Java/Kotlin: `fun name(`, `class Name`, `interface Name`, `object Name`
        let patterns: [(pattern: String, kind: SymbolKind)] = [
            // Type declarations (class, struct, enum, protocol, interface, trait, impl, object)
            (#"^\s*(?:pub(?:\(crate\))?\s+)?(?:abstract\s+|final\s+|sealed\s+|open\s+)?(?:class|struct|enum|protocol|interface|trait|impl|object)\s+([A-Za-z_][A-Za-z0-9_]*)"#, .type),
            // Functions / methods
            (#"^\s*(?:(?:pub(?:\(crate\))?\s+|public\s+|private\s+|protected\s+|internal\s+|fileprivate\s+|open\s+|static\s+|final\s+|override\s+|async\s+|unsafe\s+)*)?(?:func|fn|function|fun|def)\s+([A-Za-z_][A-Za-z0-9_]*)\s*[<(]"#, .function),
            // Swift/Kotlin top-level var/let/val/const
            (#"^\s*(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+)?(?:static\s+)?(?:let|var|val|const)\s+([A-Za-z_][A-Za-z0-9_]*)\s*[=:]"#, .property),
            // Go: func name(
            (#"^\s*func\s+(?:\([^)]+\)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\("#, .function),
            // Go: type Name
            (#"^\s*type\s+([A-Za-z_][A-Za-z0-9_]*)\s+(?:struct|interface)"#, .type),
            // JS/TS: arrow functions and class methods
            (#"^\s*(?:export\s+)?(?:default\s+)?(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:async\s+)?\(?.*?\)?\s*=>"#, .function),
        ]
        result = symbolsMatching(lines: lines, patterns: patterns)

    case .python:
        let patterns: [(pattern: String, kind: SymbolKind)] = [
            (#"^\s*(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#, .function),
            (#"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*[:(]"#, .type),
        ]
        result = symbolsMatching(lines: lines, patterns: patterns)

    case .ruby:
        let patterns: [(pattern: String, kind: SymbolKind)] = [
            (#"^\s*def\s+(?:self\.)?([A-Za-z_][A-Za-z0-9_!?]*)"#, .function),
            (#"^\s*(?:class|module)\s+([A-Za-z_][A-Za-z0-9_]*)"#, .type),
        ]
        result = symbolsMatching(lines: lines, patterns: patterns)

    case .shell:
        let patterns: [(pattern: String, kind: SymbolKind)] = [
            // Bash function definitions: `name()`, `function name`, `function name()`
            (#"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*\(\s*\)\s*\{"#, .function),
            (#"^\s*function\s+([A-Za-z_][A-Za-z0-9_.-]*)"#, .function),
        ]
        result = symbolsMatching(lines: lines, patterns: patterns)

    case .markdown:
        // Markdown headings: the natural "outline" of a markdown file.
        let headingPattern = #"^(#{1,6})\s+(.+)$"#
        let regex: NSRegularExpression
        if let cached = symbolRegexCache[headingPattern] {
            regex = cached
        } else {
            guard let compiled = try? NSRegularExpression(pattern: headingPattern) else { break }
            symbolRegexCache[headingPattern] = compiled
            regex = compiled
        }
        for (idx, line) in lines.enumerated() {
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard m.numberOfRanges >= 3 else { continue }
                let nameRange = m.range(at: 2)
                guard nameRange.location != NSNotFound else { continue }
                let name = ns.substring(with: nameRange).trimmingCharacters(in: .whitespaces)
                result.append(Symbol(name: name, line: idx + 1, kind: .heading))
            }
        }

    case .haskell:
        let patterns: [(pattern: String, kind: SymbolKind)] = [
            // Top-level function: name :: type  or  name arg1 arg2 =
            (#"^([a-z_][A-Za-z0-9_']*)\s+(?:(?:[A-Za-z_()[\]{}*]+\s+)*)?="#, .function),
            // Data / newtype / class / instance
            (#"^\s*(?:data|newtype|class|instance)\s+(?:[^=]+\s+)?([A-Z][A-Za-z0-9_']*)"#, .type),
            // Type signatures as property-level entries (name :: ...)
            (#"^([a-z_][A-Za-z0-9_']*)\s*::"#, .property),
        ]
        result = symbolsMatching(lines: lines, patterns: patterns)

    case .lua:
        let patterns: [(pattern: String, kind: SymbolKind)] = [
            // function name(, function M.name(, local function name(
            (#"^\s*(?:local\s+)?function\s+([A-Za-z_][A-Za-z0-9_.]*)\s*\("#, .function),
            // name = function(  (assignment form)
            (#"^\s*([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*function\s*\("#, .function),
        ]
        result = symbolsMatching(lines: lines, patterns: patterns)

    case .html:
        // HTML/XML: extract id= attributes as named locations — the only
        // reliably navigable "symbol" in markup.
        let patterns: [(pattern: String, kind: SymbolKind)] = [
            (#"\bid\s*=\s*"([^"]+)""#, .property),
            (#"\bid\s*=\s*'([^']+)'"#, .property),
        ]
        result = symbolsMatching(lines: lines, patterns: patterns)
    }

    return result.sorted { $0.line < $1.line }
}

/// Apply a list of (regex-pattern, SymbolKind) pairs to each line, collecting results.
/// The first capture group is always the symbol name.
private func symbolsMatching(
    lines: [String],
    patterns: [(pattern: String, kind: SymbolKind)]
) -> [Symbol] {
    var seen = IndexSet()               // line indices already claimed
    var result: [Symbol] = []
    let compiled: [(NSRegularExpression, SymbolKind)] = patterns.compactMap { p in
        if let cached = symbolRegexCache[p.pattern] { return (cached, p.kind) }
        guard let regex = try? NSRegularExpression(pattern: p.pattern) else { return nil }
        symbolRegexCache[p.pattern] = regex
        return (regex, p.kind)
    }
    for (idx, line) in lines.enumerated() {
        guard !seen.contains(idx) else { continue }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        for (regex, kind) in compiled {
            guard let match = regex.firstMatch(in: line, range: range) else { continue }
            guard match.numberOfRanges >= 2 else { continue }
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let name = ns.substring(with: nameRange)
            result.append(Symbol(name: name, line: idx + 1, kind: kind))
            seen.insert(idx)
            break   // one symbol per line
        }
    }
    return result
}

// SymbolOutlinePanel (the AppKit floating panel) lives in SymbolOutlinePanel.swift.
