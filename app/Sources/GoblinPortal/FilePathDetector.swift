//
//  FilePathDetector.swift
//  Regex-based file-path detection for terminal output — pure Foundation, no AppKit, no SwiftTerm.
//
//  Its own file because the detection predicate is view-free: it takes a plain String and
//  returns a Match struct. That means it can be compiled standalone (Foundation-only) and
//  exercised by `check-file-path-detect.sh` without a window server, a running emulator,
//  or a full swift build — exactly the same split that makes `LinkScheme.swift` auditable.
//
//  WHY REGEX, NOT SwiftTerm's link path. SwiftTerm's `requestOpenLink` only fires for
//  strings that the implicit-link detector (`ghosttyImplicitLinkRegex`, Terminal.swift:6204)
//  identified as URLs. That regex requires a scheme (`https://`, `file://`, etc.) and never
//  matches bare compiler output like `/path/file.swift:42:10`. File-path detection is therefore
//  a separate concern: we intercept cmd+click ourselves, extract the row's text from the
//  terminal buffer, run our own regex, and route matches to the editor. See
//  `GoblinPortalTerminalView+FilePath.swift` for the intercept wiring.
//
//  PATTERNS COVERED (in priority order):
//    1. Absolute — Swift/Clang/GCC/Go/Node/grep:   /path/file.ext:LINE[:COL][:]
//    2. Rust arrow  —                               --> path/file.ext:LINE[:COL]
//    3. Python traceback —               File "path/file.ext", line LINE
//    4. Relative — same colon grammar, no leading slash
//
//  Falsified by `check-file-path-detect.sh` using sed mutants on a copy (never the shipped file).
//

import Foundation

/// Detects compiler-style `file:line` references in a string of terminal text.
///
/// Enum used as a namespace (like `LinkScheme`): no instances, only static members.
enum FilePathDetector {

    // MARK: - Match

    /// A resolved file-path reference found in a line of terminal output.
    struct Match {
        /// The raw path string extracted from the text (may be relative).
        let path: String
        /// 1-based line number.
        let line: Int
        /// 1-based column number, if present in the source text.
        let column: Int?
        /// Byte range of the match in the source string, for cursor-proximity scoring.
        let range: Range<String.Index>
    }

    // MARK: - Compiled patterns
    //
    // Each pattern is compiled once at first use via a static lazy stored property on
    // a private inner enum. `NSRegularExpression(pattern:)` throws only when the
    // pattern string is syntactically invalid; these are literal constants reviewed at
    // author time. We use `try?` and return nil on the impossible failure rather than
    // `try!`, which the project rules forbid outside compile-time-known constants.
    //
    // Group layout is documented per pattern so the extraction code below is auditable.

    private enum Patterns {
        /// Absolute path: `/path/to/file[:LINE[:COL]]` where the leading `/` must
        /// not be immediately preceded by a word character (so `/Sources/…` embedded
        /// inside `app/Sources/…` is not grabbed as a spurious absolute match).
        /// Allows extensionless paths like `/etc/hosts` as well as the common
        /// `/path/file.ext` form — the path component is `[^\s:'"]+` with no dot
        /// requirement on the final segment; the dot+ext is NOT required.
        /// Trailing colon optional (GCC style).
        /// Group 1 = path, Group 2 = line, Group 3 = column (optional).
        static let absolute: NSRegularExpression? = try? NSRegularExpression(
            pattern: #"(?<![^\s('"@])(\/[^\s:'"]+):(\d+)(?::(\d+))?:?"#)

        /// Rust-style: `--> path/file.ext:LINE:COL` (may be relative).
        /// Group 1 = path, Group 2 = line, Group 3 = column (optional).
        static let rust: NSRegularExpression? = try? NSRegularExpression(
            pattern: #"-->\s+([^\s:'"]+):(\d+)(?::(\d+))?"#)

        /// Python traceback: `File "path/file.py", line LINE`
        /// Group 1 = path, Group 2 = line.
        static let python: NSRegularExpression? = try? NSRegularExpression(
            pattern: #"File "([^"]+)", line (\d+)"#)

        /// Relative path (no leading slash): `word/path/to/file.ext:LINE[:COL]`
        /// Requires at least one slash component before a dot-extension so bare
        /// tokens like `file:42` or `word:99` are not matched.
        /// Group 1 = path, Group 2 = line, Group 3 = column (optional).
        static let relative: NSRegularExpression? = try? NSRegularExpression(
            pattern: #"([a-zA-Z0-9_.][a-zA-Z0-9_./\-]*\.[a-zA-Z0-9]{1,10}):(\d+)(?::(\d+))?:?"#)
    }

    // MARK: - detect(in:near:)

    /// Scan `text` for file-path references and return the match whose range is
    /// closest to `column` (measured in UTF-16 code units, matching NSRange semantics).
    ///
    /// Returns `nil` when no pattern matches. When multiple matches are equidistant
    /// from `column`, the one that appears earliest in `text` wins — a stable tiebreak.
    ///
    /// - Parameters:
    ///   - text:   The full text of one terminal row, as decoded from the cell buffer.
    ///   - column: The click column in the row, in UTF-16 code units.
    static func detect(in text: String, near column: Int) -> Match? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var candidates: [Match] = []

        // Helper: convert an NSRange to a Swift Range<String.Index>, safely.
        func swiftRange(_ r: NSRange) -> Range<String.Index>? {
            Range(r, in: text)
        }

        // Helper: extract group text or nil.
        func group(_ result: NSTextCheckingResult, _ i: Int) -> String? {
            let r = result.range(at: i)
            guard r.location != NSNotFound, let sr = swiftRange(r) else { return nil }
            return String(text[sr])
        }

        // 1. Absolute paths — highest priority; checked first so a relative-pattern
        //    match inside a longer absolute path doesn't shadow the full path.
        if let re = Patterns.absolute {
            for m in re.matches(in: text, range: full) {
                guard let p = group(m, 1),
                      let lStr = group(m, 2),
                      let lineNum = Int(lStr),
                      let sr = swiftRange(m.range) else { continue }
                let col = group(m, 3).flatMap(Int.init)
                candidates.append(Match(path: p, line: lineNum, column: col, range: sr))
            }
        }

        // 2. Rust `-->` paths.
        if let re = Patterns.rust {
            for m in re.matches(in: text, range: full) {
                guard let p = group(m, 1),
                      let lStr = group(m, 2),
                      let lineNum = Int(lStr),
                      let sr = swiftRange(m.range) else { continue }
                let col = group(m, 3).flatMap(Int.init)
                candidates.append(Match(path: p, line: lineNum, column: col, range: sr))
            }
        }

        // 3. Python `File "…", line N`.
        if let re = Patterns.python {
            for m in re.matches(in: text, range: full) {
                guard let p = group(m, 1),
                      let lStr = group(m, 2),
                      let lineNum = Int(lStr),
                      let sr = swiftRange(m.range) else { continue }
                candidates.append(Match(path: p, line: lineNum, column: nil, range: sr))
            }
        }

        // 4. Relative paths — lowest priority; only add if no higher-priority match
        //    already covers the same path string (avoids double-counting).
        if let re = Patterns.relative {
            let coveredPaths = Set(candidates.map(\.path))
            for m in re.matches(in: text, range: full) {
                guard let p = group(m, 1),
                      !coveredPaths.contains(p),
                      let lStr = group(m, 2),
                      let lineNum = Int(lStr),
                      let sr = swiftRange(m.range) else { continue }
                // Skip if it looks like a URL fragment (contains "://").
                guard !p.contains("://") else { continue }
                let col = group(m, 3).flatMap(Int.init)
                candidates.append(Match(path: p, line: lineNum, column: col, range: sr))
            }
        }

        guard !candidates.isEmpty else { return nil }

        // Pick the candidate whose range is closest to the click column.
        // Distance = min(|start - column|, |end - column|), so clicking anywhere
        // inside the match produces distance 0.
        return candidates.min { a, b in
            let distA = rangeDistance(a.range, to: column, in: text)
            let distB = rangeDistance(b.range, to: column, in: text)
            return distA < distB
        }
    }

    // MARK: - resolve(_:cwd:)

    /// Resolve `path` to an absolute URL and verify the file exists.
    ///
    /// - Absolute paths are used directly.
    /// - Relative paths are resolved against `cwd` when provided, then against the
    ///   process's own current directory as a last resort.
    /// - Returns `nil` if `FileManager.default.fileExists` returns false.
    static func resolve(_ path: String, cwd: URL?) -> URL? {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if let base = cwd {
            url = URL(fileURLWithPath: path, relativeTo: base).standardized
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path).standardized
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Private helpers

    /// Distance from `column` (UTF-16 offset) to the nearest edge of `range`.
    /// Zero when `column` falls inside the range.
    private static func rangeDistance(_ range: Range<String.Index>, to column: Int, in text: String) -> Int {
        let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let end   = text.utf16.distance(from: text.startIndex, to: range.upperBound)
        if column >= start && column <= end { return 0 }
        return min(abs(column - start), abs(column - end))
    }
}
