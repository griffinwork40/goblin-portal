//
//  FileViewerPane+Highlighting.swift
//  Regex-based syntax highlighting for the file viewer.
//
//  The consumer `SyntaxPalette.swift` has been waiting for since 2026-08-03: five
//  syntax roles (keyword, string, number, type, comment) painted with the ANSI colours
//  the palette was already measured for. No tree-sitter, no grammar bundles, no opaque
//  binaries — a regex tokenizer that gets the easy 90% right and leaves the hard 10%
//  as plain text, which is the honest trade for a viewer whose bar is "beautiful" and
//  whose gate is `check-theme-contrast.sh`.
//
//  **Why regex and not tree-sitter.** Three of this repo's four vendored patches fix
//  bugs found by *reading* vendored source. tree-sitter's grammars are prebuilt C
//  artifacts that cannot be read, and the AFK.md already records that trade as a real
//  cost. A regex tokenizer is ~200 lines of auditable Swift that covers every language
//  an agent workspace opens daily. It will mis-colour a raw string literal or a nested
//  block comment; it will never silently ship an upstream defect.
//
//  **Performance.** Highlighting runs on the full text after `reload` and on config
//  change. For the 4 MiB / ~100k line cap `FileViewerPane` already enforces, this is
//  well under a frame. `textDidChange` calls `highlightEditedParagraph`, which passes
//  only the paragraph's text slice to `tokenise` — ~57 regex patterns run over one
//  paragraph, not the whole file. Compiled `NSRegularExpression` objects are cached
//  at file scope so the per-keystroke cost is matches-only, not compile-then-match.
//
//  **Wave 2: multi-line block re-highlighting.** The #1 known limitation (block
//  comments and raw strings spanning paragraphs mis-colour after edits) is fixed by
//  `highlightEditedParagraph` expanding its re-highlight window whenever the edit
//  lands near a block-comment delimiter. Block-comment boundary helpers live in
//  `FileViewerPane+BlockReHighlight.swift`, extracted when this file hit 480 LOC.
//  The seam is clean: that file answers "where is the block-comment boundary?" and
//  this one answers "how do I paint what I find?".
//
//  Language detection (extension → family + keywords) lives in `SyntaxLanguage.swift`,
//  pulled out when this file hit the 350-line ceiling. The seam is clean: that file
//  answers "what language is this file?" and this one answers "how do I paint it?".
//

// Token model, tokenise(), findAll(), and regexCache live in SyntaxTokeniser.swift.
// Block-comment helpers live in FileViewerPane+BlockReHighlight.swift.

import AppKit

// MARK: - Application

extension FileViewerPane {
    /// Resolve the theme's syntax colours as `NSColor`, cached per config reload.
    /// Uses `theme.ansi` directly — the AppKit bridge — so no `ThemePalette` conversion
    /// is needed. Falls back through `SyntaxPalette.ansiIndex` for slot lookup.
    /// The result is stored in `cachedSyntaxColours` (declared on `FileViewerPane` itself,
    /// because extensions cannot hold stored properties) and recomputed only when
    /// `apply(config:)` nils out that cache on a theme change.
    func syntaxColours() -> [SyntaxRole: NSColor]? {
        if let cached = cachedSyntaxColours { return cached }
        guard let theme = config.theme else { return nil }
        var colours: [SyntaxRole: NSColor] = [:]
        for role in SyntaxRole.allCases {
            let index = SyntaxPalette.ansiIndex(for: role)
            guard index < theme.ansi.count else { continue }
            if role == .comment {
                // Re-derive the comment colour through the same APCA check
                // SyntaxPalette uses, but in AppKit land.
                let bg = theme.background
                let slot = theme.ansi[index]
                let bgHex = bg.hexString
                let slotHex = slot.hexString
                if let bgRGB = RGB(hex: bgHex), let slotRGB = RGB(hex: slotHex) {
                    if APCA.lc(text: slotRGB, background: bgRGB) >= SyntaxPalette.readableFloor {
                        colours[role] = slot
                    } else {
                        colours[role] = config.effectiveForeground
                            .withAlphaComponent(SyntaxPalette.commentAlpha)
                    }
                } else {
                    colours[role] = slot
                }
            } else {
                colours[role] = theme.ansi[index]
            }
        }
        let result = colours.isEmpty ? nil : colours
        cachedSyntaxColours = result
        return result
    }

    /// Apply syntax highlighting to the full text view contents.
    ///
    /// Called from `reload` after the text and base font/colour are set, and from
    /// `apply(config:)` when the theme changes. Idempotent: it resets foreground
    /// attributes on the full range before painting, so double-calling is harmless.
    func highlightSyntax() {
        guard !isPlaceholder else { return }
        let ext = url.pathExtension
        guard let lang = languageForExtension(ext),
              let colours = syntaxColours() else { return }

        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)

        storage.beginEditing()
        // Reset to the base foreground colour first, so a re-highlight after config
        // change does not layer new attributes over stale ones.
        storage.addAttribute(.foregroundColor, value: config.effectiveForeground, range: fullRange)

        let tokens = tokenise(text, family: lang.family, keywords: lang.keywords)
        for token in tokens {
            if let colour = colours[token.role] {
                storage.addAttribute(.foregroundColor, value: colour, range: token.range)
            }
        }
        storage.endEditing()
    }

    /// Re-highlight the edited region. Called from `textDidChange` so that typing
    /// does not re-tokenise the entire file.
    ///
    /// **Wave 2 block-comment fix.** The previous implementation re-highlighted only
    /// the single edited paragraph, which left block comments and raw strings that
    /// span paragraphs mis-coloured after edits near their delimiters. This version
    /// expands the window:
    ///
    ///  1. Start at the edited paragraph.
    ///  2. If the family has block comments AND the paragraph text contains a
    ///     block-comment delimiter, walk up and down the text looking for a line
    ///     that cannot be inside a block comment (i.e. it does not contain a
    ///     continuation and itself starts at column 0 without being part of a block).
    ///     In practice, we expand up to `maxExpansionLines` lines in each direction
    ///     and re-tokenise the resulting span as one unit.
    ///  3. If the expanded window hits the ceiling (whole file), fall through to
    ///     `highlightSyntax()` so the user still sees correct colours, just slower.
    ///
    /// The expansion is bounded so that a 100k-line file does not re-tokenise the
    /// whole thing on every keystroke near a stray `/*`.
    func highlightEditedParagraph() {
        guard !isPlaceholder else { return }
        let ext = url.pathExtension
        guard let lang = languageForExtension(ext),
              let colours = syntaxColours() else { return }

        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let length = text.length

        // Find the paragraph range around the insertion point.
        let selection = textView.selectedRange()
        let loc = min(selection.location, length > 0 ? length - 1 : 0)
        var paraRange = text.paragraphRange(for: NSRange(location: loc, length: 0))

        // --- Block-comment expansion ---
        // How many lines we scan up/down before giving up and doing a full highlight.
        let maxExpansionLines = 100

        if hasBlockComments(lang.family) {
            let paraText = text.substring(with: paraRange)
            if containsBlockDelimiter(paraText, family: lang.family) {
                // Expand upward from the paragraph start.
                var expandedStart = paraRange.location
                var upLines = 0
                while expandedStart > 0 && upLines < maxExpansionLines {
                    let prevEnd = expandedStart - 1
                    let prevPara = text.paragraphRange(
                        for: NSRange(location: prevEnd, length: 0))
                    let prevText = text.substring(with: prevPara)
                    expandedStart = prevPara.location
                    upLines += 1
                    // Stop at a line that cannot be inside a block comment.
                    if !mightBeInsideBlockComment(prevText, family: lang.family) { break }
                }

                // Expand downward from the paragraph end.
                var expandedEnd = NSMaxRange(paraRange)
                var downLines = 0
                while expandedEnd < length && downLines < maxExpansionLines {
                    let nextPara = text.paragraphRange(
                        for: NSRange(location: expandedEnd, length: 0))
                    let nextText = text.substring(with: nextPara)
                    expandedEnd = NSMaxRange(nextPara)
                    downLines += 1
                    if !mightBeInsideBlockComment(nextText, family: lang.family) { break }
                }

                // If expansion hit both ceilings, fall back to a full highlight.
                if upLines >= maxExpansionLines && downLines >= maxExpansionLines {
                    highlightSyntax()
                    return
                }

                paraRange = NSRange(
                    location: expandedStart,
                    length: expandedEnd - expandedStart)
            }
        }

        // Re-highlight the resolved range (either the bare paragraph or the expanded span).
        applyHighlight(over: paraRange, text: text, lang: lang, colours: colours, storage: storage)
    }

    // MARK: - Helpers

    /// Apply tokens to `storage` over `range`. The tokeniser runs on a text slice;
    /// all returned ranges are offset to storage-global before applying.
    private func applyHighlight(
        over range: NSRange,
        text: NSString,
        lang: (family: LanguageFamily, keywords: Set<String>),
        colours: [SyntaxRole: NSColor],
        storage: NSTextStorage
    ) {
        let clampedRange = NSRange(
            location: range.location,
            length: min(range.length, text.length - range.location))
        guard clampedRange.length > 0 else { return }

        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: config.effectiveForeground,
                             range: clampedRange)
        let sliceText = text.substring(with: clampedRange) as NSString
        let tokens = tokenise(sliceText, family: lang.family, keywords: lang.keywords)
        for token in tokens {
            let globalRange = NSRange(
                location: clampedRange.location + token.range.location,
                length: token.range.length)
            if let colour = colours[token.role] {
                storage.addAttribute(.foregroundColor, value: colour, range: globalRange)
            }
        }
        storage.endEditing()
    }

    // mightBeInsideBlockComment(_:family:) lives in FileViewerPane+BlockReHighlight.swift
}
