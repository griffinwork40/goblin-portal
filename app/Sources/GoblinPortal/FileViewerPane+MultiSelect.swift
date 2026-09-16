//
//  FileViewerPane+MultiSelect.swift
//  ⌘D "Select Next Occurrence" — the entry point to multi-cursor editing.
//
//  NSTextView supports multiple discontiguous selections via
//  `setSelectedRanges(_:affinity:stillSelecting:)`. Each ⌘D press:
//    1. On first press with no selection: selects the whole word under the cursor.
//    2. On subsequent presses: finds the NEXT occurrence of the already-selected
//       text (forward-wrapping) and adds it to the existing selection set.
//
//  Why not full multi-cursor? TextKit 1 (`NSLayoutManager`) renders glyphs in a
//  single pass; inserting text into multiple ranges atomically needs careful
//  `NSTextStorage` surgery that is out of scope for Wave 3. The selection half —
//  highlighting multiple occurrences — is the power feature users actually invoke
//  constantly (VS Code's most-cited edit shortcut), and it composes with Copy (get
//  all matched strings), and with the find bar for the replace half.
//
//  The action is `selectNextOccurrence:` — wired from `AppMenu.swift` (⌘D) and
//  answered through the responder chain, so it greys out when a terminal is
//  focused (terminals don't implement the selector).
//

import AppKit

// MARK: - ⌘D action

extension FileViewerPane {
    /// Select the next occurrence of the current selection, or the word under
    /// the cursor on the first press.
    ///
    /// Wraps around the document end (matching VS Code's behaviour).
    @objc func selectNextOccurrence(_ sender: Any?) {
        guard !isPlaceholder else { return }

        let str = textView.string as NSString
        let existing = textView.selectedRanges.compactMap { $0.rangeValue }
            .filter { $0.length > 0 }

        // ── First press with no selection: select the word under the cursor ──
        if existing.isEmpty {
            let loc = textView.selectedRange().location
            let word = wordRange(in: str, at: loc)
            if word.length > 0 {
                textView.setSelectedRanges(
                    [NSValue(range: word)],
                    affinity: .downstream,
                    stillSelecting: false)
            }
            return
        }

        // ── Subsequent presses: find the next match after the last selection ──
        // All selections share the same search string — the text of the FIRST
        // selection (so the set stays coherent: they're all matching the same word).
        guard let firstRange = existing.first else { return }
        let searchString = str.substring(with: firstRange)
        guard !searchString.isEmpty else { return }

        // Search starts AFTER the last (rightmost) selection to find the next one.
        let lastEnd = existing.map { NSMaxRange($0) }.max() ?? 0

        // Forward search from lastEnd to the document end.
        var nextRange = str.range(
            of: searchString,
            options: [.literal],
            range: NSRange(location: lastEnd, length: str.length - lastEnd))

        // Wrap around: if not found past the end, search from the document start.
        if nextRange.location == NSNotFound {
            nextRange = str.range(
                of: searchString,
                options: [.literal],
                range: NSRange(location: 0, length: str.length))
        }

        guard nextRange.location != NSNotFound else { return }

        // Don't add a range that is already selected (happens when there is only
        // one occurrence in the document — we've wrapped and landed on the first).
        if existing.contains(where: { NSEqualRanges($0, nextRange) }) { return }

        // Add to existing selections.
        let allRanges = existing.map { NSValue(range: $0) }
            + [NSValue(range: nextRange)]
        textView.setSelectedRanges(
            allRanges,
            affinity: .downstream,
            stillSelecting: false)

        // Scroll the newly added range into view.
        textView.scrollRangeToVisible(nextRange)
    }

    // MARK: - Helpers

    /// Returns the word-boundary range around `location` in `str`.
    ///
    /// Uses `NSString.rangeOfComposedCharacterSequences(for:)` + simple
    /// alphanumeric/underscore expansion — the same heuristic as VS Code's "word
    /// under cursor" and Sublime's ⌘D. A word is `[A-Za-z0-9_]`; triggers on the
    /// character AT location and expands both directions.
    private func wordRange(in str: NSString, at location: Int) -> NSRange {
        guard str.length > 0 else { return NSRange(location: 0, length: 0) }
        let loc = min(location, str.length - 1)

        // Expand left
        var start = loc
        while start > 0 && isWordChar(str.character(at: start - 1)) {
            start -= 1
        }
        // Expand right
        var end = loc
        while end < str.length && isWordChar(str.character(at: end)) {
            end += 1
        }

        let len = end - start
        return len > 0 ? NSRange(location: start, length: len)
                       : NSRange(location: loc, length: 0)
    }

    /// Returns true for characters that belong to an identifier word.
    /// `unichar` is always a BMP code unit — extended identifiers are multi-unit
    /// and both halves fail this test, which is fine for "select word at cursor".
    private func isWordChar(_ c: unichar) -> Bool {
        // a-z, A-Z, 0-9, underscore, dollar sign (JS/TS/shell vars).
        (c >= 0x61 && c <= 0x7A) || // a–z
        (c >= 0x41 && c <= 0x5A) || // A–Z
        (c >= 0x30 && c <= 0x39) || // 0–9
        c == 0x5F ||                // _
        c == 0x24                   // $
    }
}
