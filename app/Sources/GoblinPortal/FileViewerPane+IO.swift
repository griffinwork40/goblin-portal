//
//  FileViewerPane+IO.swift
//  The disk-reading concern: load a file, or explain why not.
//
//  Extracted from `FileViewerPane.swift` when that file approached the 350-line
//  ceiling. Everything here is "how bytes reach the screen" — `read()` decides
//  what to show, `reload(preservingScroll:)` puts it there. The write path is
//  `+Editing.swift`; neither needs the other's methods.
//

import AppKit

extension FileViewerPane {
    // MARK: - Contents

    /// Read the file, or explain why not.
    ///
    /// Mirrors `AppConfig.load()`'s fail-soft contract (AFK.md, Conventions): this
    /// never throws and never shows an alert. A missing, huge, or binary file is an
    /// ordinary thing to click in a file tree, so each one degrades to a legible
    /// line of text in the document body — the tab still opens, the app still works.
    struct Contents {
        let text: String
        let isPlaceholder: Bool
        let encoding: String.Encoding
    }

    func read() -> Contents {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0

        if size > Self.maxBytes {
            return tooLargePlaceholder(bytes: size)
        }

        guard let data = try? Data(contentsOf: url) else {
            return Contents(
                text: "Could not read \(url.lastPathComponent).", isPlaceholder: true,
                encoding: .utf8)
        }

        // Re-check against what actually loaded, not just the pre-read stat above:
        // the file can grow between that stat and this read completing — this
        // app's own concurrent-agent-write premise — and trusting a stale "it was
        // small a moment ago" would defeat the whole point of the guard
        // (PR #2 review, finding 3).
        if data.count > Self.maxBytes {
            return tooLargePlaceholder(bytes: data.count)
        }

        if data.prefix(Self.sniffBytes).contains(0) {
            return Contents(
                text: "\(url.lastPathComponent) is a binary file.", isPlaceholder: true,
                encoding: .utf8)
        }

        // UTF-8 first because it is essentially always the answer; the second
        // attempt catches the Latin-1 and UTF-16 stragglers without which a
        // legitimately-readable file would be mislabelled binary.
        if let text = String(data: data, encoding: .utf8) {
            return Contents(text: text, isPlaceholder: false, encoding: .utf8)
        }
        var encoding: String.Encoding = .utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) {
            return Contents(text: text, isPlaceholder: false, encoding: encoding)
        }
        return Contents(
            text: "\(url.lastPathComponent) is not text in any encoding Goblin Portal recognises.",
            isPlaceholder: true, encoding: .utf8)
    }

    /// Shared by both the pre-read stat check and the post-read TOCTOU re-check in
    /// `read()`, so the message can't drift between the two call sites.
    private func tooLargePlaceholder(bytes: Int) -> Contents {
        let mb = Double(bytes) / Double(1 << 20)
        return Contents(
            text: "\(url.lastPathComponent) is \(String(format: "%.1f", mb)) MB — too large to view.\n"
                + "Goblin Portal's viewer lays out the whole file at once, so it caps at "
                + "\(Self.maxBytes >> 20) MB. Open it in the terminal instead.",
            isPlaceholder: true, encoding: .utf8)
    }

    /// Pull the current bytes onto the screen.
    ///
    /// `preservingScroll` is what makes the refresh-on-focus behaviour tolerable:
    /// an agent appending to a log you are reading should not fling you back to
    /// line 1 every time you ⌘-tab into the window.
    ///
    /// Internal rather than private because both extensions reload: `+Document`'s
    /// `refresh(diskChanged:)` on a clean buffer, and `+Editing`'s "Discard Mine and
    /// Reload" branch. It stays the single way bytes reach the screen.
    func reload(preservingScroll: Bool) {
        // Invalidate before assigning the new string: `textView.string =` does not
        // fire `textDidChange`, so the cache built for the old content would survive
        // and make `updateStatusBar` report line 1 for every cursor position until
        // the first edit.
        invalidateLineStartCache()
        let origin = scrollView.contentView.bounds.origin
        let contents = read()
        let text = contents.text
        isPlaceholder = contents.isPlaceholder
        savedEncoding = contents.encoding

        textView.string = text
        // Assigning `string` does not notify the delegate, so `isDirty` has to be
        // cleared by hand — and the undo stack with it, or ⌘Z would "restore" text
        // from a previous revision of a file that has since changed on disk.
        textView.undoManager?.removeAllActions()
        setDirty(false)
        hasExternalChange = false
        // Fold state is ephemeral — fold regions reference storage offsets from the
        // previous load, which are meaningless after a fresh read from disk.
        foldedRegions = []
        symbolOutlinePanel?.dismiss()
        symbolOutlinePanel = nil
        // Rule 3: an explanation is not the file, so it must not be savable.
        textView.isEditable = !isPlaceholder
        // Set the font after the string: assigning `string` on a plain-text view
        // re-applies `font` to the whole run, but only if `font` is already set —
        // ordering it the other way leaves placeholder text at the system default.
        textView.font = Self.resized(config.font, to: fontSize)
        textView.textColor = isPlaceholder
            ? config.effectiveForeground.withAlphaComponent(0.6)
            : config.effectiveForeground
        textView.insertionPointColor = config.theme?.cursor ?? config.effectiveForeground
        highlightSyntax()

        let stamp = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let date = stamp?.contentModificationDate, let size = stamp?.fileSize {
            loadedStamp = (date, size)
        } else {
            loadedStamp = nil
        }

        if preservingScroll {
            // Force layout before scrolling: `NSTextView` lays out lazily, so the
            // document is still zero-height at this point and the scroll would be
            // clamped to the top. Optional-chained rather than force-unwrapped —
            // no `try!`/`!` outside compile-time constants in this repo (AFK.md).
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            // AppKit clamps if the file shrank past the old offset, which is the
            // right answer — land at the new bottom rather than in blank space.
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Helpers

    /// Same trick as `TerminalPane.resized` — see `AppConfig.resized(_:to:)` for why
    /// this cannot go through `NSFont(name:size:)`.
    /// Internal because `+Document`'s `setFontSize` resizes through it too.
    static func resized(_ base: NSFont, to size: CGFloat) -> NSFont {
        AppConfig.resized(base, to: size)
    }
}
