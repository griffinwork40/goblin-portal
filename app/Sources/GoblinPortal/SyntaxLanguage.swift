//
//  SyntaxLanguage.swift
//  File-extension → language mapping for the syntax highlighter.
//
//  **Pure and view-free — Foundation only, on purpose**, like `SyntaxPalette.swift`
//  beside it. The keyword sets and family groupings are data, not rendering — they
//  belong in a file a gate could compile standalone (though no gate does today,
//  because the tokeniser exercising them is AppKit-side).
//
//  Pulled out of `FileViewerPane+Highlighting.swift` when that file hit the 350-line
//  ceiling. The seam is clean: this file answers "what language is this file?" and the
//  other answers "how do I paint it?". Neither needs the other's imports.
//
//  The families are deliberately broad: `cLike` covers Swift, Rust, Go, C, C++, Java,
//  JS/TS and CSS because their comment syntax and string/number literals are the same
//  to a regex. The keyword lists differ, so each extension maps to its own keyword set
//  within the family.
//
//  Wave 2 additions (2026-08-17): Lua, PHP, Dart, Elixir, Perl, Haskell, Scala, R.
//  Each slots into an existing family or gets a new one where the comment/string
//  grammar is materially different (Haskell: `--` and `{- -}` block comments).
//

import Foundation

/// A language family sharing one set of regex patterns.
enum LanguageFamily {
    case cLike
    case python
    case ruby
    case shell
    case html
    case markdown
    case haskell   // `--` line comment, `{- -}` block comment
    case lua       // `--` line comment, `--[[ ]]` block comment
}

/// Maps a file extension to (family, keywords). Returns nil for unknown extensions,
/// which disables highlighting — plain text stays plain, never mis-coloured.
func languageForExtension(_ ext: String) -> (family: LanguageFamily, keywords: Set<String>)? {
    switch ext.lowercased() {
    case "swift":
        return (.cLike, ["import", "func", "var", "let", "if", "else", "guard", "return",
            "switch", "case", "default", "for", "while", "repeat", "in", "where",
            "struct", "class", "enum", "protocol", "extension", "self", "super",
            "init", "deinit", "throw", "throws", "try", "catch", "do", "async",
            "await", "public", "private", "internal", "fileprivate", "open",
            "static", "final", "override", "mutating", "weak", "unowned",
            "typealias", "associatedtype", "some", "any", "as", "is", "break",
            "continue", "fallthrough", "defer", "precondition", "fatalError"])
    case "js", "jsx", "ts", "tsx", "mjs", "cjs":
        return (.cLike, ["import", "export", "from", "function", "const", "let", "var",
            "if", "else", "return", "switch", "case", "default", "for", "while",
            "do", "break", "continue", "class", "extends", "new", "this", "super",
            "try", "catch", "finally", "throw", "async", "await", "yield",
            "typeof", "instanceof", "in", "of", "delete", "void", "interface",
            "type", "enum", "as", "readonly", "declare", "abstract", "implements"])
    case "py":
        return (.python, ["import", "from", "def", "class", "if", "elif", "else",
            "return", "for", "while", "break", "continue", "pass", "raise", "try",
            "except", "finally", "with", "as", "yield", "lambda", "global",
            "nonlocal", "assert", "del", "in", "not", "and", "or", "is", "async",
            "await", "match", "case"])
    case "rb":
        return (.ruby, ["def", "class", "module", "if", "elsif", "else", "unless",
            "return", "do", "end", "begin", "rescue", "ensure", "raise", "yield",
            "block_given?", "require", "include", "extend", "attr_reader",
            "attr_writer", "attr_accessor", "self", "super", "while", "until",
            "for", "in", "break", "next", "case", "when", "then", "puts", "print"])
    case "c", "h":
        return (.cLike, ["if", "else", "return", "switch", "case", "default", "for",
            "while", "do", "break", "continue", "struct", "enum", "union", "typedef",
            "const", "static", "extern", "void", "int", "char", "float", "double",
            "long", "short", "unsigned", "signed", "sizeof", "goto", "volatile",
            "register", "inline", "restrict", "include", "define", "ifdef", "ifndef",
            "endif", "pragma"])
    case "cpp", "cc", "cxx", "hpp", "hxx":
        return (.cLike, ["if", "else", "return", "switch", "case", "default", "for",
            "while", "do", "break", "continue", "struct", "class", "enum", "union",
            "typedef", "const", "static", "extern", "virtual", "override", "final",
            "public", "private", "protected", "namespace", "using", "template",
            "typename", "auto", "new", "delete", "this", "throw", "try", "catch",
            "void", "int", "char", "float", "double", "bool", "nullptr", "constexpr",
            "noexcept", "inline", "include", "define", "ifdef", "ifndef", "endif"])
    case "rs":
        return (.cLike, ["fn", "let", "mut", "const", "if", "else", "match", "return",
            "for", "while", "loop", "break", "continue", "struct", "enum", "impl",
            "trait", "pub", "use", "mod", "crate", "self", "super", "as", "in",
            "where", "async", "await", "move", "ref", "type", "unsafe", "extern",
            "static", "dyn", "macro_rules"])
    case "go":
        return (.cLike, ["package", "import", "func", "var", "const", "if", "else",
            "return", "switch", "case", "default", "for", "range", "break",
            "continue", "struct", "interface", "type", "map", "chan", "go", "defer",
            "select", "fallthrough", "goto"])
    case "java", "kt", "kts":
        return (.cLike, ["import", "package", "class", "interface", "enum", "extends",
            "implements", "public", "private", "protected", "static", "final",
            "abstract", "void", "return", "if", "else", "switch", "case", "default",
            "for", "while", "do", "break", "continue", "new", "this", "super",
            "try", "catch", "finally", "throw", "throws", "synchronized", "val",
            "var", "fun", "when", "object", "companion", "override", "open"])
    case "css", "scss", "less":
        return (.cLike, ["import", "media", "keyframes", "font-face", "charset",
            "supports", "page", "namespace"])
    case "json", "jsonc":
        return (.cLike, [])
    case "sh", "bash", "zsh", "fish":
        return (.shell, ["if", "then", "else", "elif", "fi", "for", "while", "do",
            "done", "case", "esac", "in", "function", "return", "exit", "local",
            "export", "source", "alias", "unalias", "set", "unset", "shift",
            "break", "continue", "eval", "exec", "trap", "readonly", "declare"])
    case "yml", "yaml", "toml":
        // Accepted imprecision: `.shell` gives `#` comments, but the backtick
        // template-literal pattern fires on these languages where backtick is not
        // a string delimiter.
        return (.shell, [])
    case "html", "htm", "xml", "svg":
        return (.html, [])
    case "md", "markdown", "mdx":
        return (.markdown, [])

    // ── Wave 2 additions ────────────────────────────────────────────────────────

    case "lua":
        // Lua: `--` line comments, `--[[ ]]` block comments. Family `.lua` handles
        // both in the tokeniser's Phase 1 switch. String delimiters are `"` and `'`
        // (and long-bracket `[[ ]]`, accepted imprecision — treated as cLike).
        return (.lua, ["and", "break", "do", "else", "elseif", "end", "false", "for",
            "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat",
            "return", "then", "true", "until", "while", "require", "pcall", "xpcall",
            "error", "assert", "type", "tostring", "tonumber", "pairs", "ipairs",
            "next", "select", "unpack", "load", "dofile", "loadfile", "rawget",
            "rawset", "rawequal", "rawlen", "setmetatable", "getmetatable"])

    case "php":
        // PHP uses `//` and `#` for line comments, `/* */` for blocks — same as
        // cLike. The `$` sigil on variables is a false-positive risk for strings
        // (none of our patterns match `$ident`), so cLike is a safe family here.
        return (.cLike, ["echo", "print", "var", "function", "class", "interface",
            "trait", "abstract", "final", "extends", "implements", "namespace",
            "use", "return", "if", "elseif", "else", "switch", "case", "default",
            "for", "foreach", "while", "do", "break", "continue", "try", "catch",
            "finally", "throw", "new", "null", "true", "false", "public", "private",
            "protected", "static", "readonly", "match", "fn", "yield", "require",
            "require_once", "include", "include_once"])

    case "dart":
        // Dart: `//` line, `/* */` block — cLike is exact.
        return (.cLike, ["var", "final", "const", "late", "dynamic", "void", "null",
            "true", "false", "if", "else", "switch", "case", "default", "for",
            "while", "do", "break", "continue", "return", "try", "catch", "on",
            "finally", "throw", "rethrow", "class", "abstract", "interface",
            "extends", "implements", "with", "mixin", "enum", "typedef", "import",
            "export", "library", "part", "as", "show", "hide", "async", "await",
            "sync", "yield", "new", "super", "this", "is", "in", "assert",
            "get", "set", "operator", "factory", "external", "static"])

    case "ex", "exs":
        // Elixir: `#` line comments only (no block comments). Python family gives us
        // `#` comment handling, and the keyword set is Elixir-specific. The `"""` and
        // `'''` heredoc patterns in the python tokeniser path fire here as strings
        // (they are heredocs in Elixir, but treating them as strings is fine).
        return (.python, ["def", "defp", "defmodule", "defstruct", "defprotocol",
            "defimpl", "defmacro", "defmacrop", "defdelegate", "defexception",
            "defoverridable", "defcallback", "defguard", "alias", "import",
            "require", "use", "if", "unless", "case", "cond", "with", "for",
            "receive", "try", "catch", "rescue", "after", "raise", "reraise",
            "throw", "exit", "do", "end", "fn", "true", "false", "nil", "and",
            "or", "not", "in", "when", "is_nil", "is_integer", "is_float",
            "is_binary", "is_list", "is_map", "is_atom", "is_boolean"])

    case "pl", "pm":
        // Perl: `#` line comments, `"` and `'` strings. Python family covers `#`
        // comments and double/single-quoted strings correctly.
        return (.python, ["use", "no", "package", "require", "sub", "my", "our",
            "local", "if", "elsif", "else", "unless", "while", "until", "for",
            "foreach", "do", "last", "next", "redo", "return", "die", "warn",
            "print", "say", "chomp", "chop", "push", "pop", "shift", "unshift",
            "splice", "join", "split", "sort", "reverse", "map", "grep", "wantarray",
            "ref", "defined", "undef", "eval", "BEGIN", "END", "and", "or", "not"])

    case "hs", "lhs":
        // Haskell: `--` line comments, `{- -}` block comments — handled by the
        // `.haskell` case in the Phase 1 switch. Strings: `"`. No single-quote
        // strings (single quotes are char literals, handled by the number tokeniser
        // as an accepted imprecision). Types are capitalised — the existing type
        // phase fires here.
        return (.haskell, ["module", "import", "where", "data", "type", "newtype",
            "class", "instance", "deriving", "do", "let", "in", "of", "if",
            "then", "else", "case", "default", "forall", "qualified", "as",
            "hiding", "infixl", "infixr", "infix", "pattern", "family",
            "undefined", "error", "pure", "return", "fmap", "mconcat",
            "mempty", "mappend", "seq", "otherwise"])

    case "scala", "sc":
        // Scala: `//` line, `/* */` block — cLike is correct. Significant keywords.
        return (.cLike, ["val", "var", "def", "class", "object", "trait", "case",
            "sealed", "abstract", "override", "extends", "with", "new", "import",
            "package", "return", "if", "else", "match", "for", "yield", "while",
            "do", "try", "catch", "finally", "throw", "type", "implicit", "explicit",
            "lazy", "final", "private", "protected", "public", "super", "this",
            "null", "true", "false", "None", "Some", "Option", "List", "Map",
            "Set", "Seq", "Vector", "given", "using", "inline", "opaque", "enum",
            "export", "extension", "derives", "transparent", "open", "infix"])

    case "r", "rmd", "rmarkdown":
        // R: `#` line comments, `"` and `'` strings. No block comments. Python
        // family handles `#` and both string flavours correctly. The `<-` assignment
        // operator is not a keyword; FALSE/TRUE are handled by the bool-literal set
        // in the tokeniser (added here as capitalised forms).
        return (.python, ["if", "else", "for", "while", "repeat", "break", "next",
            "return", "function", "library", "require", "source", "in", "TRUE",
            "FALSE", "NULL", "NA", "Inf", "NaN", "NA_integer_", "NA_real_",
            "NA_complex_", "NA_character_", "T", "F", "tryCatch", "withCallingHandlers",
            "stop", "warning", "message", "cat", "print", "sprintf", "paste",
            "paste0", "list", "c", "data.frame", "vector", "matrix", "array",
            "class", "inherits", "is", "as", "length", "nrow", "ncol",
            "lapply", "sapply", "vapply", "tapply", "apply"])

    default:
        return nil
    }
}
