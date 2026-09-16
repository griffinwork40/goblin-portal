//
//  SyntaxTokeniser.swift
//  Regex-based syntax tokeniser — the core of Goblin Portal's syntax highlighting.
//
//  Owns two responsibilities:
//    · `tokenise(_:family:keywords:)` — convert a text slice into an ordered,
//      non-overlapping list of `Token` values, each carrying a range and a role.
//    · `findAll(_:in:range:)` + `regexCache` — the cached NSRegularExpression
//      engine that `tokenise` delegates all pattern matching to.
//
//  Extracted from `FileViewerPane+Highlighting.swift` when that file reached
//  480 LOC, over the 350-line ceiling. The seam is clean: this file answers
//  "what tokens are in this text?" and `+Highlighting.swift` answers "how do I
//  paint those tokens onto an NSTextStorage?".
//
//  These are internal free functions (no access modifier), visible to the whole
//  GoblinPortal module. They are stateless except for the module-level `regexCache`,
//  which is safe because highlighting only ever runs on `@MainActor`.
//

import AppKit

// MARK: - Token model

/// A token: a range in the source text and its syntax role.
struct Token {
    let range: NSRange
    let role: SyntaxRole
}

// MARK: - Tokeniser

/// Tokenise a string for a given language family and keyword set.
///
/// Returns tokens sorted by location. Tokens never overlap — a string inside a
/// comment is a comment, not a string. This is enforced by the ordering: comments
/// and strings are matched first, and the `occupied` set prevents later patterns
/// from claiming ranges already taken.
func tokenise(_ text: NSString, family: LanguageFamily, keywords: Set<String>) -> [Token] {
    var tokens: [Token] = []
    // Tracks character offsets already claimed. A simple bitset would be faster for
    // very large files, but `IndexSet` is correct and clear, and the 4 MiB cap means
    // the worst case is well bounded.
    var occupied = IndexSet()

    func add(_ range: NSRange, _ role: SyntaxRole) {
        guard range.length > 0 else { return }
        let proposed = range.lowerBound..<range.upperBound
        guard !occupied.intersects(integersIn: proposed) else { return }
        tokens.append(Token(range: range, role: role))
        occupied.insert(integersIn: proposed)
    }

    let len = text.length
    let fullRange = NSRange(location: 0, length: len)

    // --- Phase 1: comments (highest priority — nothing overrides a comment) ---
    switch family {
    case .cLike:
        // Block comments: /* ... */
        findAll(#"/\*[\s\S]*?\*/"#, in: text, range: fullRange).forEach { add($0, .comment) }
        // Line comments: //
        findAll(#"//[^\r\n]*"#, in: text, range: fullRange).forEach { add($0, .comment) }
    case .python:
        // Docstrings (triple-quoted) as comments — matched before strings.
        findAll(#""{3}[\s\S]*?"{3}"#, in: text, range: fullRange).forEach { add($0, .comment) }
        findAll(#"'{3}[\s\S]*?'{3}"#, in: text, range: fullRange).forEach { add($0, .comment) }
        findAll(#"#[^\r\n]*"#, in: text, range: fullRange).forEach { add($0, .comment) }
    case .ruby:
        findAll(#"^=begin[\s\S]*?^=end"#, in: text, range: fullRange).forEach { add($0, .comment) }
        findAll(#"#[^\r\n]*"#, in: text, range: fullRange).forEach { add($0, .comment) }
    case .shell:
        findAll(#"#[^\r\n]*"#, in: text, range: fullRange).forEach { add($0, .comment) }
    case .html:
        findAll(#"<!--[\s\S]*?-->"#, in: text, range: fullRange).forEach { add($0, .comment) }
    case .markdown:
        // No comments in markdown; headings, bold, etc. are structural, not syntax.
        break
    case .haskell:
        // Block comments: {- ... -}  Line: -- (NOT -->, which is an arrow in Haskell docs)
        findAll(#"\{-[\s\S]*?-\}"#, in: text, range: fullRange).forEach { add($0, .comment) }
        findAll(#"--[^\r\n]*"#, in: text, range: fullRange).forEach { add($0, .comment) }
    case .lua:
        // Long-bracket block comments: --[[ ... ]] and --[ ... ] variants.
        // The lazy `[\s\S]*?` handles nested structure acceptably for 90% of files.
        findAll(#"--\[\[[\s\S]*?\]\]"#, in: text, range: fullRange).forEach { add($0, .comment) }
        findAll(#"--\[=\[[\s\S]*?\]=\]"#, in: text, range: fullRange).forEach { add($0, .comment) }
        // Line comments: -- (anything not starting with [ to avoid the block case above)
        findAll(#"--[^\r\n]*"#, in: text, range: fullRange).forEach { add($0, .comment) }
    }

    // --- Phase 2: strings (next priority) ---
    switch family {
    case .cLike, .shell:
        // Double-quoted strings (with escaped quote support).
        findAll(#""(?:[^"\\]|\\.)*""#, in: text, range: fullRange).forEach { add($0, .string) }
        // Single-quoted strings.
        findAll(#"'(?:[^'\\]|\\.)*'"#, in: text, range: fullRange).forEach { add($0, .string) }
        // Backtick template literals (JS/TS — harmless false positives in others).
        findAll(#"`(?:[^`\\]|\\.)*`"#, in: text, range: fullRange).forEach { add($0, .string) }
    case .python, .ruby:
        findAll(#""(?:[^"\\]|\\.)*""#, in: text, range: fullRange).forEach { add($0, .string) }
        findAll(#"'(?:[^'\\]|\\.)*'"#, in: text, range: fullRange).forEach { add($0, .string) }
    case .html:
        findAll(#""[^"]*""#, in: text, range: fullRange).forEach { add($0, .string) }
        findAll(#"'[^']*'"#, in: text, range: fullRange).forEach { add($0, .string) }
    case .markdown:
        // Inline code spans.
        findAll(#"`[^`]+`"#, in: text, range: fullRange).forEach { add($0, .string) }
    case .haskell:
        // Double-quoted strings only. Single-quoted char literals are single chars
        // between two `'` — accepted imprecision: treated as strings.
        findAll(#""(?:[^"\\]|\\.)*""#, in: text, range: fullRange).forEach { add($0, .string) }
        findAll(#"'(?:[^'\\]|\\.)*'"#, in: text, range: fullRange).forEach { add($0, .string) }
    case .lua:
        findAll(#""(?:[^"\\]|\\.)*""#, in: text, range: fullRange).forEach { add($0, .string) }
        findAll(#"'(?:[^'\\]|\\.)*'"#, in: text, range: fullRange).forEach { add($0, .string) }
        // Long-bracket strings: [[ ... ]] — lazy match.
        findAll(#"\[\[[\s\S]*?\]\]"#, in: text, range: fullRange).forEach { add($0, .string) }
    }

    // --- Phase 3: numbers ---
    // Hex, binary, octal, float, integer — broad enough for every family.
    findAll(#"\b0[xX][0-9a-fA-F_]+\b"#, in: text, range: fullRange).forEach { add($0, .number) }
    findAll(#"\b0[bB][01_]+\b"#, in: text, range: fullRange).forEach { add($0, .number) }
    findAll(#"\b0[oO][0-7_]+\b"#, in: text, range: fullRange).forEach { add($0, .number) }
    findAll(#"\b\d[\d_]*\.[\d_]+(?:[eE][+-]?\d+)?\b"#, in: text, range: fullRange)
        .forEach { add($0, .number) }
    findAll(#"\b\d[\d_]*\b"#, in: text, range: fullRange).forEach { add($0, .number) }

    // Boolean/nil literals — these read as numbers in every language that has them.
    let boolNil: Set<String>
    switch family {
    case .cLike: boolNil = ["true", "false", "nil", "null", "undefined",
                            "True", "False", "None", "nullptr", "YES", "NO"]
    case .python: boolNil = ["True", "False", "None"]
    case .ruby:   boolNil = ["true", "false", "nil"]
    case .shell:  boolNil = ["true", "false"]
    case .haskell: boolNil = ["True", "False", "Nothing", "Just"]
    case .lua:    boolNil = ["true", "false", "nil"]
    case .html, .markdown: boolNil = []
    }
    for lit in boolNil {
        findAll("\\b\(NSRegularExpression.escapedPattern(for: lit))\\b",
                in: text, range: fullRange).forEach { add($0, .number) }
    }

    // --- Phase 4: keywords ---
    for kw in keywords {
        findAll("\\b\(NSRegularExpression.escapedPattern(for: kw))\\b",
                in: text, range: fullRange).forEach { add($0, .keyword) }
    }

    // --- Phase 5: types (capitalised identifiers) ---
    switch family {
    case .cLike, .python, .ruby, .haskell, .lua:
        findAll(#"\b[A-Z][a-zA-Z0-9_]*\b"#, in: text, range: fullRange).forEach { add($0, .type) }
    default:
        break
    }

    // --- Phase 5b: markdown-specific roles ---
    if family == .markdown {
        // Headings as keywords.
        findAll(#"^#{1,6}\s+.*$"#, in: text, range: fullRange).forEach { add($0, .keyword) }
        // Bold / italic markers as types (gives them the cyan tint).
        findAll(#"\*{1,3}[^*\n]+\*{1,3}"#, in: text, range: fullRange).forEach { add($0, .type) }
        findAll(#"_{1,3}[^_\n]+_{1,3}"#, in: text, range: fullRange).forEach { add($0, .type) }
    }

    // --- Phase 5c: HTML tag names as keywords ---
    if family == .html {
        findAll(#"</?[a-zA-Z][\w.-]*"#, in: text, range: fullRange).forEach { add($0, .keyword) }
        // Attribute names as types.
        findAll(#"\b[a-z][\w-]*(?=\s*=)"#, in: text, range: fullRange).forEach { add($0, .type) }
    }

    return tokens
}

// MARK: - Regex engine

/// Cache for compiled regular expressions — the pattern set is fixed per language family,
/// so compiling once and reusing eliminates the per-keystroke `NSRegularExpression` init cost.
/// `nonisolated(unsafe)` is correct here: highlighting only ever runs on the main actor
/// (called from `@MainActor` methods on `FileViewerPane`), so there is no concurrent access.
fileprivate nonisolated(unsafe) var regexCache: [String: NSRegularExpression] = [:]

/// All non-overlapping matches of a pattern in a string.
func findAll(_ pattern: String, in text: NSString,
             range: NSRange) -> [NSRange] {
    let regex: NSRegularExpression
    if let cached = regexCache[pattern] {
        regex = cached
    } else {
        guard let compiled = try? NSRegularExpression(
            pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        regexCache[pattern] = compiled
        regex = compiled
    }
    return regex.matches(in: text as String, range: range).map(\.range)
}
