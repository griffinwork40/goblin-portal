//
//  FileViewerPane+SmartEditing.swift
//  Auto-indent, tab→spaces, and bracket/quote auto-pairing.
//
//  Owns the `NSTextViewDelegate` conformance that `+Editing.swift` used to hold.
//  Moved here because `textDidChange` and `shouldChangeTextIn` must live in the
//  same Swift extension (same protocol conformance), and the smart-editing
//  logic is the concern that grew large enough to justify its own file. The write
//  path (`setDirty`, `write()`, alerts) stays in `+Editing.swift` — the *dangerous*
//  half of the viewer — which is the audit boundary that matters.
//

import AppKit

// MARK: - NSTextViewDelegate

extension FileViewerPane: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        setDirty(true)
        highlightEditedParagraph()
        // Invalidate cached line starts so the next status bar update recomputes.
        invalidateLineStartCache()
        scheduleStatusBarUpdate()
    }

    /// Cursor moved — update the status bar and repaint the current-line highlight.
    /// The status bar update is coalesced to the end of the current run-loop turn
    /// so rapid-fire selection events (auto-indent, auto-pair, programmatic
    /// `setSelectedRange` calls) do not each pay the line-counting cost.
    func textViewDidChangeSelection(_ notification: Notification) {
        scheduleStatusBarUpdate()
        textView.needsDisplay = true
    }

    func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange,
                  replacementString replacement: String?) -> Bool {
        guard let replacement, !isPlaceholder else { return true }

        // Re-entrancy guard: every `insertText(_:replacementRange:)` call below
        // re-enters this delegate method via AppKit's `shouldChangeTextInRanges:`.
        // Without this flag the auto-indent path loops infinitely (the re-entered
        // call sees "\n" again and re-fires `insertText` with the indented string,
        // which re-enters again, …), blowing the 8 MB main-thread stack in ~11 000
        // frames. When the flag is set we are already inside a smart-edit transform
        // and the replacement has been rewritten — let AppKit accept it as-is.
        guard !isHandlingSmartEdit else { return true }

        // Tab → spaces.
        if replacement == "\t" && config.softTabs {
            isHandlingSmartEdit = true
            defer { isHandlingSmartEdit = false }
            let spaces = String(repeating: " ", count: config.tabWidth)
            tv.insertText(spaces, replacementRange: range)
            return false
        }

        // Auto-indent on Enter.
        if replacement == "\n" {
            isHandlingSmartEdit = true
            defer { isHandlingSmartEdit = false }
            let inserted = autoIndentedNewline(in: tv, at: range)
            tv.insertText(inserted, replacementRange: range)
            return false
        }

        // Bracket / quote auto-pairing (single-character typed, no selection).
        if replacement.count == 1 && range.length == 0 {
            let ch = replacement.first!

            // Skip-close for closing brackets/quotes: typing a closer when cursor sits on it.
            // Guard-let ch.utf16.first rather than force-unwrapping: all skippable
            // closers are BMP today, but a non-BMP entry in isSkippableCloser would
            // produce an empty utf16 view and crash. The guard makes that safe.
            if Self.isSkippableCloser(ch),
               !isInsideStringOrComment(at: range.location),
               let str = tv.string as NSString?,
               range.location < str.length,
               let codeUnit = ch.utf16.first,
               str.character(at: range.location) == codeUnit {
                tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return false
            }

            // Auto-pair openers: insert opener + closer, place cursor between.
            if let close = Self.closerFor(ch) {
                // Don't pair inside strings or comments.
                if !isInsideStringOrComment(at: range.location) {
                    isHandlingSmartEdit = true
                    defer { isHandlingSmartEdit = false }
                    let pair = "\(ch)\(close)"
                    tv.insertText(pair, replacementRange: range)
                    // Place cursor between the pair.
                    tv.setSelectedRange(
                        NSRange(location: range.location + 1, length: 0))
                    return false
                }
            }
        }

        // Delete-pair: backspace between an empty pair → remove both.
        if replacement.isEmpty && range.length == 1 && range.location > 0 {
            let str = tv.string as NSString
            let before = range.location - 1
            let after = range.location
            if after < str.length {
                guard let openScalar = UnicodeScalar(str.character(at: before)),
                      let closeScalar = UnicodeScalar(str.character(at: after)) else { return true }
                let open = Character(openScalar)
                let close = Character(closeScalar)
                if Self.closerFor(open) == close {
                    // Delete both characters.
                    isHandlingSmartEdit = true
                    defer { isHandlingSmartEdit = false }
                    tv.insertText("",
                        replacementRange: NSRange(location: before, length: 2))
                    return false
                }
            }
        }

        return true
    }

    // MARK: - Auto-indent

    /// Build a newline string carrying the current line's leading whitespace,
    /// plus one extra indent level after `{`, `(`, `[`, or `:` (Python).
    private func autoIndentedNewline(in tv: NSTextView, at range: NSRange) -> String {
        let str = tv.string as NSString

        // Find current line's range and extract its leading whitespace.
        let lineRange = str.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = str.substring(with: lineRange)
        let leadingWS = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))

        // Smart indent: if the character before the cursor is an opener or colon,
        // add one indent level.
        var extra = ""
        if range.location > 0 {
            let beforeCursor = str.character(at: range.location - 1)
            if let ch = UnicodeScalar(beforeCursor),
               Self.smartIndentOpeners.contains(Character(ch)) {
                extra = config.softTabs
                    ? String(repeating: " ", count: config.tabWidth)
                    : "\t"
            }
        }

        return "\n" + leadingWS + extra
    }

    private static let smartIndentOpeners: Set<Character> = ["{", "(", "[", ":"]

    // MARK: - Auto-pairing

    /// Returns the closing character for an opener, or nil.
    /// Only openers are mapped here; closers are handled via `isSkippableCloser`.
    private static func closerFor(_ ch: Character) -> Character? {
        switch ch {
        case "{": return "}"
        case "(": return ")"
        case "[": return "]"
        case "\"": return "\""
        case "'": return "'"
        case "`": return "`"
        default: return nil
        }
    }

    /// Returns true for characters that should skip-close (advance past) when
    /// the cursor already sits on that character.
    private static func isSkippableCloser(_ ch: Character) -> Bool {
        switch ch {
        case "}", ")", "]", "\"", "'", "`": return true
        default: return false
        }
    }

    /// Heuristic: check whether the cursor is inside a string or comment span
    /// by looking at the foreground colour attribute. The syntax highlighter marks
    /// strings and comments with specific colours; if the cursor sits inside one
    /// of those spans, auto-pairing would double-quote inside an already-quoted
    /// string.
    private func isInsideStringOrComment(at location: Int) -> Bool {
        guard location > 0 else { return false }
        guard let colours = syntaxColours(),
              let stringColour = colours[.string],
              let commentColour = colours[.comment] else { return false }
        guard let ts = textView.textStorage else { return false }
        let checkLoc = min(location, ts.length - 1)
        guard checkLoc >= 0 else { return false }
        guard let fg = ts.attribute(.foregroundColor, at: checkLoc, effectiveRange: nil)
                as? NSColor else { return false }
        return fg == stringColour || fg == commentColour
    }
}
