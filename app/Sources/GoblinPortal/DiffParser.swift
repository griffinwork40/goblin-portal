//
//  DiffParser.swift
//  Parse unified diff output into structured types for rendering.
//
//  Foundation-only: the renderer (`DiffViewerPane+Highlighting.swift`) consumes these
//  types, but this file knows nothing about AppKit. A future `check-diff-parser.sh`
//  can compile it standalone.
//
//  The parser handles the standard unified diff format git produces:
//  ```
//  diff --git a/file.swift b/file.swift
//  index abc1234..def5678 100644
//  --- a/file.swift
//  +++ b/file.swift
//  @@ -10,7 +10,8 @@ func example() {
//       context line
//  -    removed line
//  +    added line
//       context line
//  ```
//

import Foundation

/// One line inside a diff hunk.
struct DiffLine: Equatable {
    enum Kind {
        case context    // unchanged — shown for surrounding context
        case added      // new in the working copy / index
        case removed    // deleted from HEAD
        case noNewline  // the "\ No newline at end of file" marker
    }

    let kind: Kind
    /// The line content WITHOUT the leading +/-/space character.
    let text: String
    /// Line number in the old file (nil for added lines).
    let oldLineNumber: Int?
    /// Line number in the new file (nil for removed lines).
    let newLineNumber: Int?
}

/// A contiguous block of changes with its `@@ ... @@` header.
struct DiffHunk: Equatable {
    /// The raw `@@ -10,7 +10,8 @@` header line.
    let header: String
    /// Optional function context from after the closing `@@`, e.g. "func example()".
    let functionContext: String?
    /// Starting line in the old file.
    let oldStart: Int
    /// Number of lines from the old file in this hunk.
    let oldCount: Int
    /// Starting line in the new file.
    let newStart: Int
    /// Number of lines from the new file in this hunk.
    let newCount: Int
    /// The lines in this hunk, in order.
    let lines: [DiffLine]
}

/// A parsed diff for one file.
struct FileDiff: Equatable {
    /// The old path (from `--- a/...`), or nil for a new file.
    let oldPath: String?
    /// The new path (from `+++ b/...`), or nil for a deleted file.
    let newPath: String?
    /// Whether this is a binary file (git says "Binary files ... differ").
    let isBinary: Bool
    /// The hunks, in file order.
    let hunks: [DiffHunk]
}

/// Parsing unified diff text into structured types.
enum DiffParser {
    /// Parse a complete `git diff` output (possibly containing multiple files).
    static func parse(_ text: String) -> [FileDiff] {
        let allLines = text.components(separatedBy: "\n")
        var diffs: [FileDiff] = []
        var i = 0

        while i < allLines.count {
            let line = allLines[i]

            // Each file starts with "diff --git a/... b/..."
            guard line.hasPrefix("diff --git ") else {
                i += 1
                continue
            }

            // Skip the "diff --git" line
            i += 1

            // Read optional headers: index, old mode, new mode, similarity, etc.
            while i < allLines.count,
                  !allLines[i].hasPrefix("---"),
                  !allLines[i].hasPrefix("+++"),
                  !allLines[i].hasPrefix("@@"),
                  !allLines[i].hasPrefix("diff --git "),
                  !allLines[i].hasPrefix("Binary files ")
            {
                i += 1
            }

            // Check for binary files
            if i < allLines.count, allLines[i].hasPrefix("Binary files ") {
                let paths = extractPaths(from: line)
                diffs.append(FileDiff(
                    oldPath: paths.old, newPath: paths.new,
                    isBinary: true, hunks: []))
                i += 1
                continue
            }

            // Read --- and +++ lines
            var oldPath: String?
            var newPath: String?
            if i < allLines.count, allLines[i].hasPrefix("--- ") {
                let path = String(allLines[i].dropFirst(4))
                oldPath = path == "/dev/null" ? nil : path.hasPrefix("a/") ? String(path.dropFirst(2)) : path
                i += 1
            }
            if i < allLines.count, allLines[i].hasPrefix("+++ ") {
                let path = String(allLines[i].dropFirst(4))
                newPath = path == "/dev/null" ? nil : path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
                i += 1
            }

            // Read hunks
            var hunks: [DiffHunk] = []
            while i < allLines.count, allLines[i].hasPrefix("@@") {
                if let (hunk, nextIndex) = parseHunk(allLines, startingAt: i) {
                    hunks.append(hunk)
                    i = nextIndex
                } else {
                    i += 1
                }
            }

            diffs.append(FileDiff(
                oldPath: oldPath, newPath: newPath,
                isBinary: false, hunks: hunks))
        }

        return diffs
    }

    /// Parse a single `@@ ... @@` hunk starting at index `start`.
    /// Returns the parsed hunk and the index of the next line after it.
    private static func parseHunk(
        _ lines: [String], startingAt start: Int
    ) -> (DiffHunk, Int)? {
        let header = lines[start]
        guard let range = parseHunkHeader(header) else { return nil }

        // Function context is everything after the closing @@
        let functionContext: String?
        if let closingAt = header.range(of: "@@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex) {
            let after = header[closingAt.upperBound...].trimmingCharacters(in: .whitespaces)
            functionContext = after.isEmpty ? nil : after
        } else {
            functionContext = nil
        }

        var diffLines: [DiffLine] = []
        var oldLine = range.oldStart
        var newLine = range.newStart
        var i = start + 1

        while i < lines.count {
            let line = lines[i]
            // Stop at the next hunk, next file, or end of diff
            if line.hasPrefix("@@") || line.hasPrefix("diff --git ") { break }
            // Handle empty lines at end of input
            if line.isEmpty && i == lines.count - 1 { break }

            if line.hasPrefix("+") {
                diffLines.append(DiffLine(
                    kind: .added, text: String(line.dropFirst()),
                    oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                diffLines.append(DiffLine(
                    kind: .removed, text: String(line.dropFirst()),
                    oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                diffLines.append(DiffLine(
                    kind: .noNewline, text: String(line.dropFirst(2)),
                    oldLineNumber: nil, newLineNumber: nil))
            } else {
                // Context line — starts with space (or is empty for blank context lines)
                let text = line.isEmpty ? "" : String(line.dropFirst())
                diffLines.append(DiffLine(
                    kind: .context, text: text,
                    oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            }
            i += 1
        }

        return (DiffHunk(
            header: header, functionContext: functionContext,
            oldStart: range.oldStart, oldCount: range.oldCount,
            newStart: range.newStart, newCount: range.newCount,
            lines: diffLines), i)
    }

    /// Parse `@@ -10,7 +10,8 @@` into (oldStart, oldCount, newStart, newCount).
    private static func parseHunkHeader(
        _ header: String
    ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        // Pattern: @@ -OLD_START[,OLD_COUNT] +NEW_START[,NEW_COUNT] @@
        let scanner = Scanner(string: header)
        guard scanner.scanString("@@") != nil else { return nil }
        scanner.charactersToBeSkipped = .whitespaces
        guard scanner.scanString("-") != nil else { return nil }
        guard let oldStart = scanner.scanInt() else { return nil }
        let oldCount: Int
        if scanner.scanString(",") != nil {
            guard let c = scanner.scanInt() else { return nil }
            oldCount = c
        } else {
            oldCount = 1
        }
        guard scanner.scanString("+") != nil else { return nil }
        guard let newStart = scanner.scanInt() else { return nil }
        let newCount: Int
        if scanner.scanString(",") != nil {
            guard let c = scanner.scanInt() else { return nil }
            newCount = c
        } else {
            newCount = 1
        }
        return (oldStart, oldCount, newStart, newCount)
    }

    /// Extract old and new paths from "diff --git a/path b/path".
    private static func extractPaths(from diffLine: String) -> (old: String?, new: String?) {
        let stripped = diffLine.replacingOccurrences(of: "diff --git ", with: "")
        // Heuristic: paths are "a/..." and "b/..." separated by space. This breaks
        // on paths containing spaces, but git's own output uses this format and the
        // fallback (the --- / +++ lines) handles the real case.
        let parts = stripped.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (nil, nil) }
        let old = String(parts[0].hasPrefix("a/") ? parts[0].dropFirst(2) : parts[0])
        let new = String(parts[1].hasPrefix("b/") ? parts[1].dropFirst(2) : parts[1])
        return (old, new)
    }
}
