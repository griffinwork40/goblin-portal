//
//  FileViewerPane+Document.swift
//  The `SpaceDocument` conformance: everything the Space's strip is allowed to ask for.
//
//  Its own file because `SpaceDocument` is the seam that lets a terminal, a file
//  viewer, and a future editor/diff/Ghostty pane share one container without the
//  container knowing their types (`SpaceDocument.swift:8-32`, plan §12.3). Keeping
//  the conformance whole and by itself is what makes that claim checkable: this is
//  the complete list of what a document owes its Space, readable end to end, and
//  the file a third conformer gets written against. Nothing here reaches back into
//  `SpaceViewController` — the dependency runs one way, container ← document.
//

import AppKit

// MARK: - SpaceDocument

extension FileViewerPane: SpaceDocument {
    var documentView: NSView { containerView }

    var documentTitle: String { url.lastPathComponent }

    /// Distinguishable from `TerminalPane`'s "terminal" at tab size, which is the
    /// whole reason `documentSymbolName` is on the protocol (`SpaceDocument.swift:33`).
    var documentSymbolName: String { "doc.text" }

    func documentDidBecomeActive() {
        // Takes first responder for the same reason the terminal does: so ⌘F,
        // arrow-key scrolling and ⌘C work without a stray click into the view first.
        scrollView.window?.makeFirstResponder(textView)
    }

    func apply(config: AppConfig) {
        self.config = config
        // Theme changed — invalidate the syntax-colour cache so `syntaxColours()`
        // recomputes hex→RGB + APCA on the next call rather than serving stale values.
        cachedSyntaxColours = nil
        scrollView.backgroundColor = config.effectiveBackground
        textView.backgroundColor = config.effectiveBackground
        textView.textColor = config.effectiveForeground
        // The theme's selection colour, which until 2026-08-03 nothing in the app consumed:
        // it was measured with the rest of the palette and then dropped at the AppKit bridge
        // (`Theme.swift` had no such field), so no consumer could have read it. Against an
        // unthemed editor the stock highlight is a system blue that has no relationship to a
        // warm umber background.
        //
        // Only the BACKGROUND is set here. Overriding the selected text's foreground would be
        // the obvious next line and it is deliberately absent — the normal foreground is meant
        // to show through, which is the same trick iTerm2 plays in `TextViewPorthole.swift`.
        // `selectedTextAttributes` REPLACES rather than merges, so omitting `.foregroundColor`
        // is what makes that happen; AppKit does not substitute `.selectedTextColor` back in.
        //
        // That is precisely why the pair has to be MEASURED here rather than asserted once in
        // the harness. §5h checks `umber`'s foreground on `umber`'s selection; a config file
        // can pair a user's foreground with a preset's selection, because `selection` is the
        // one `ThemePalette` field with no override (#29). See `SelectionPairing` for the
        // configuration that reaches APCA Lc 0.0 that way.
        //
        // Falls back to the COMPLETE system pair in BOTH failing cases — no theme
        // (`"preset": "classic"`), and a theme whose selection this foreground cannot be read
        // on. `selectedTextAttributes` replaces rather than merges, so installing only the
        // system background would leave the normal foreground in place; under dark Aqua that
        // measured Lc 17.8 instead of the system pair's 86.1. Supplying both halves preserves
        // AppKit's Increase Contrast and appearance-aware choice.
        //
        // `effectiveSelectionColors()` is the shared rule, promoted to `Config+Chrome.swift`
        // (#31) — only the background half is installed here; SwiftTerm requires both halves
        // explicitly (AppleTerminalView.swift:751-752) so the terminal path sets both.
        textView.selectedTextAttributes = config.effectiveSelectionColors().map {
            [.backgroundColor: $0.background]
        } ?? [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor,
        ]
        // Re-resolve rather than reusing `fontSize`, so editing `font.size` and
        // hitting ⌘R changes the size here exactly as it does in a terminal
        // (`TerminalPane.apply(config:)`). A live ⌘+ zoom still outranks the file.
        setFontSize(FontZoom.override ?? config.font.pointSize, persist: false)
        // Update the line-number gutter to match the new theme and font.
        rulerView?.updateAppearance(
            background: config.effectiveBackground,
            foreground: config.effectiveForeground,
            font: Self.resized(config.font, to: fontSize))
        // Re-resolve wrap mode and tab width — the config may have changed both.
        applyWrapping()
        applyTabWidth()
        // Re-highlight: the theme may have changed, and the font re-set above cleared
        // attributed runs. Full re-tokenise rather than range-based, because a theme
        // change affects every token.
        highlightSyntax()
        // Editor chrome — current-line highlight, column guide, trailing whitespace,
        // indent rainbow. Drives EditorTextView properties from AppConfig.
        applyChrome(config: config)
        // Sticky scroll overlay — reinstalled on every config push so a toggle in
        // config.json + ⌘R takes effect immediately.
        applyStickyScroll()
    }

    var currentFontSize: CGFloat { fontSize }

    func setFontSize(_ size: CGFloat, persist: Bool = true) {
        let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
        fontSize = clamped
        textView.font = Self.resized(config.font, to: clamped)
        if persist {
            FontZoom.override = clamped == config.font.pointSize ? nil : clamped
        }
    }

    func resetFontSize() {
        FontZoom.override = nil
        setFontSize(config.font.pointSize, persist: false)
    }

    /// Re-read if disk moved under us. This is the difference between a viewer and
    /// a screenshot: in this app the file on screen is being rewritten by an agent
    /// in the terminal beside it, so a viewer that never re-reads would spend most
    /// of its life confidently showing a stale file.
    func documentWindowDidBecomeKey() {
        let current = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        // A vanished file counts as changed — a clean viewer re-reads and renders the
        // "could not read" placeholder rather than leaving stale content up.
        guard let date = current?.contentModificationDate, let size = current?.fileSize,
            let loaded = loadedStamp
        else {
            refresh(diskChanged: true)
            return
        }
        refresh(diskChanged: loaded.date != date || loaded.size != size)
    }

    /// Rule 1, in one place: reload a clean buffer, never a dirty one.
    ///
    /// Auto-reloading over unsaved edits would destroy work with no gesture from the
    /// user and no way back — the single worst thing this class could do. So a dirty
    /// buffer only records that disk moved; the choice gets made later, deliberately,
    /// at save time (`confirmOverwriteOfChangedFile`).
    private func refresh(diskChanged: Bool) {
        guard diskChanged else { return }
        guard !isDirty else {
            hasExternalChange = true
            return
        }
        reload(preservingScroll: true)
    }

    var documentIsEdited: Bool { isDirty }

    func documentShouldClose() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(url.lastPathComponent)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        // Save / Cancel / Don't Save, in that order — the macOS HIG arrangement, and
        // the one muscle memory expects when ⌘W is followed by a blind ⏎.
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return write()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func saveDocument() -> Bool { write() }

    /// Nothing to release, and this empty body is the answer rather than a stub.
    ///
    /// This pane holds an `NSScrollView`, an `NSTextView` and a `String` — all ARC's. It
    /// owns no process, no file handle (the file is read into memory and closed) and no
    /// manually-freed resource. The protocol requires this member with no default
    /// precisely so that claim is written down by whoever knows it, rather than inferred
    /// later from an absence.
    ///
    /// Note what does NOT belong here: unsaved work is `documentShouldClose()`'s job,
    /// above, which prompts and can still veto. By the time this runs the user has already
    /// been asked, so saving here would either double-prompt or silently overwrite a file
    /// the user just chose to discard.
    func documentWillClose() {}
}
