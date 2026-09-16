//
//  StickyScrollView.swift
//  Sticky-scroll overlay: when the user scrolls past a function/class/block,
//  pin its opening line at the top of the editor so the enclosing context is
//  always visible.
//
//  Architecture
//  ────────────
//  `StickyScrollOverlay` is a transparent overlay view positioned above the
//  `NSScrollView`'s content area. It reacts to `NSScrollView` scroll
//  notifications and re-evaluates which scope header (if any) to show.
//
//  Scope detection uses indent-based heuristics — the same strategy Nova and
//  CotEditor use for their code-folding ranges. No AST, no LSP, no grammar
//  bundles. This is correct for indent-sensitive languages (Python, YAML, Swift)
//  and acceptably approximate for C-family (the opening `{` lands one line
//  below the declaration; that is still the right context line to show).
//
//  The overlay owns a single `NSTextField` label. It draws a translucent
//  background from the editor's theme palette — the same shade as the status
//  bar — and clips to the label's height, so it does not occlude any content
//  below the pinned line.
//
//  Config: enabled by default; toggled by `AppConfig.stickyScroll`. Wired by
//  `FileViewerPane+Layout.swift`'s `installStickyScroll(over:)`.
//

import AppKit

// MARK: - StickyScrollOverlay

/// A non-interactive overlay that pins the enclosing scope header to the top
/// of the editor scroll view.
@MainActor
final class StickyScrollOverlay: NSView {
    // MARK: - Subviews

    private let label = NSTextField(labelWithString: "")
    private var backgroundLayer: CALayer?

    // MARK: - State

    /// The text view whose content drives the pinned header.
    weak var textView: NSTextView?

    /// Whether the overlay is active. When false, the view is hidden.
    var isEnabled: Bool = true {
        didSet { isHidden = !isEnabled || pinnedLine.isEmpty }
    }

    /// Background and foreground colours — updated from `applyTheme`.
    private var bgColor: NSColor = .windowBackgroundColor
    private var fgColor: NSColor = .labelColor

    /// The text currently pinned at the top. Empty string = nothing to show.
    private var pinnedLine: String = "" {
        didSet {
            let show = isEnabled && !pinnedLine.isEmpty
            isHidden = !show
            if show {
                label.stringValue = pinnedLine
                sizeToFit()
            }
        }
    }

    static let overlayHeight: CGFloat = 22

    // MARK: - Init

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        buildSubviews(font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func buildSubviews(font: NSFont) {
        wantsLayer = true
        isHidden = true

        // Semi-transparent background separates the pinned line from the
        // document body beneath — drawn by the layer, not by `draw(_:)`, so
        // AppKit's compositing handles transparency correctly.
        let layer = CALayer()
        layer.opacity = 0.93
        self.layer?.addSublayer(layer)
        backgroundLayer = layer

        label.font = font
        label.textColor = fgColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func layout() {
        super.layout()
        backgroundLayer?.frame = bounds
    }

    // MARK: - Theme

    /// Called from `applyChrome(config:)` when the theme changes.
    func applyTheme(background: NSColor, foreground: NSColor, font: NSFont) {
        bgColor = background
        fgColor = foreground
        // Slightly lifted background matching the status bar — same visual weight.
        let overlayBg = background.blended(withFraction: 0.07, of: .white) ?? background
        backgroundLayer?.backgroundColor = overlayBg.cgColor
        label.textColor = foreground.withAlphaComponent(0.85)
        label.font = font
    }

    private func sizeToFit() {
        // Height is fixed; width is driven by the superview's auto-resize mask.
        frame.size.height = Self.overlayHeight
    }

    // MARK: - Scroll notification handler

    /// Re-evaluate which header to pin. Call this from the scroll notification.
    func scrollViewDidScroll(_ scrollView: NSScrollView) {
        guard isEnabled, let tv = textView,
              let lm = tv.layoutManager, let tc = tv.textContainer else {
            pinnedLine = ""
            return
        }

        let str = tv.string as NSString
        guard str.length > 0 else { pinnedLine = ""; return }

        // The character at the top-left corner of the visible area.
        // `glyphIndex(for:in:fractionOfDistanceBetweenInsertionPoints:)` is the
        // full-signature API; we don't need the fraction value.
        let visibleOrigin = scrollView.contentView.bounds.origin
        var fraction: CGFloat = 0
        let glyphIdx = lm.glyphIndex(
            for: NSPoint(x: visibleOrigin.x,
                         y: visibleOrigin.y + tv.textContainerInset.height),
            in: tc,
            fractionOfDistanceThroughGlyph: &fraction)

        guard lm.numberOfGlyphs > 0 else { pinnedLine = ""; return }

        // `characterIndexForGlyph(at:)` is the correct zero-argument variant.
        let safeGlyph = min(glyphIdx, lm.numberOfGlyphs - 1)
        let charIdx = lm.characterIndexForGlyph(at: safeGlyph)
        guard charIdx < str.length else { pinnedLine = ""; return }

        // The indent level of the first visible line determines what "enclosing
        // scope" means: we want the last line ABOVE the visible area whose indent
        // is strictly less than the first visible line's indent.
        let firstVisibleLine = str.lineRange(
            for: NSRange(location: charIdx, length: 0))
        let firstIndent = leadingIndent(of: str.substring(with: firstVisibleLine))

        // Don't pin anything if the first visible line itself has zero indent —
        // we're at the top level, there is no enclosing scope.
        guard firstIndent > 0 else { pinnedLine = ""; return }

        // Walk backwards from the line above the visible area to find the
        // enclosing scope opener.
        var searchIdx = firstVisibleLine.location
        var found: String? = nil
        var linesWalked = 0

        while searchIdx > 0 {
            searchIdx -= 1
            let prevLine = str.lineRange(for: NSRange(location: searchIdx, length: 0))
            let lineText = str.substring(with: prevLine)
            let indent = leadingIndent(of: lineText)
            // Opener: non-empty line with strictly less indent than the first visible.
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && indent < firstIndent {
                found = trimmed
                break
            }
            // Don't walk more than 200 lines — past that we're in a file where the
            // enclosing context is too far away to be useful, and the walk cost is
            // not worth it.
            linesWalked += 1
            if linesWalked > 200 { break }
            searchIdx = prevLine.location
        }

        pinnedLine = found ?? ""
    }

    // MARK: - Helpers

    /// Count leading spaces/tabs, treating each tab as `tabSize` spaces.
    private func leadingIndent(of line: String, tabSize: Int = 4) -> Int {
        var count = 0
        for ch in line {
            switch ch {
            case " ": count += 1
            case "\t": count += tabSize - (count % tabSize)
            default: return count
            }
        }
        return count  // All whitespace = treat as blank for scope purposes.
    }
}
