//
//  LineNumberRulerView.swift
//  A line-number gutter for the file viewer, drawn via NSRulerView.
//
//  Self-contained: imports AppKit only, no Goblin Portal types. The file viewer creates
//  it, passes its `NSTextView`, and calls `updateAppearance` on theme/font
//  changes. Everything else — scroll tracking, text-change redraw, line-start
//  caching — is internal.
//
//  TextKit 1 throughout (NSLayoutManager, not NSTextLayoutManager), matching the
//  file viewer's own backing. The draw path uses `enumerateLineFragments` on
//  the visible glyph range, deduplicating wrapped-line continuations with a
//  `Set<Int>` on logical line start offsets — so the same code works for both
//  wrapping and non-wrapping modes without special-casing.
//
//  The line-start cache is an `[Int]` of UTF-16 offsets. Rebuilt O(n) on text
//  change; binary-searched O(log n) per visible line during draw. The gutter
//  width adapts to the digit count with a deferred `RunLoop.main.perform` to
//  avoid calling `scrollView.tile()` mid-draw.
//

import AppKit

@MainActor
final class LineNumberRulerView: NSRulerView {

    private weak var textView: NSTextView?

    // Gutter typography — tabular figures so 9→10 doesn't jitter.
    private var lineNumberFont: NSFont = .monospacedDigitSystemFont(
        ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private var lineNumberColor: NSColor = .secondaryLabelColor
    private var gutterBackground: NSColor = .controlBackgroundColor

    // Line-start cache: UTF-16 offsets of each '\n' + 1.
    private var cachedLineStarts: [Int] = [0]
    private var cachedTextLength: Int = 0
    private var needsCacheRebuild = true

    private let padding: CGFloat = 8
    private static let minimumDigits = 2

    // `nonisolated(unsafe)` because `deinit` is nonisolated and must remove
    // these tokens. Safe: deinit runs on the main thread for a @MainActor type,
    // and these are only mutated from `installObservers()` during `init`.
    nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    // MARK: - Init

    init(textView: NSTextView) {
        self.textView = textView
        super.init(
            scrollView: textView.enclosingScrollView,
            orientation: .verticalRuler)
        // macOS 14+: without this the background fill overpaints the text area.
        clipsToBounds = true
        clientView = textView
        ruleThickness = initialThickness()
        installObservers()
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: - Public — called by FileViewerPane on theme/font changes

    /// Update colours and font to match the current theme. Call from
    /// `apply(config:)` whenever the theme or font changes.
    func updateAppearance(background: NSColor, foreground: NSColor, font: NSFont) {
        gutterBackground = background
        // Subdued: 50% alpha of the theme foreground, so line numbers never
        // compete with the code for attention.
        lineNumberColor = foreground.withAlphaComponent(0.50)
        lineNumberFont = .monospacedDigitSystemFont(
            ofSize: font.pointSize * 0.85, weight: .regular)
        deferredThicknessUpdate()
        needsDisplay = true
    }

    // MARK: - Observers

    private func installObservers() {
        guard let tv = textView else { return }
        let nc = NotificationCenter.default

        func observe(_ name: NSNotification.Name, object: AnyObject?,
                     handler: @escaping @MainActor () -> Void) {
            observers.append(nc.addObserver(
                forName: name, object: object, queue: .main) { _ in
                    // The closure captures `handler` which is @MainActor; we are
                    // already on .main queue, but Swift 6 wants the annotation.
                    MainActor.assumeIsolated { handler() }
                })
        }

        // Text edited → rebuild line cache, maybe widen gutter, redraw.
        observe(NSText.didChangeNotification, object: tv) { [weak self] in
            guard let self else { return }
            self.needsCacheRebuild = true
            self.deferredThicknessUpdate()
            self.needsDisplay = true
        }

        // Scrolled → different lines visible.
        if let clip = tv.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observe(NSView.boundsDidChangeNotification, object: clip) { [weak self] in
                self?.needsDisplay = true
            }
        }

        // Frame changed → font zoom, wrap toggle, window resize.
        // needsCacheRebuild is intentionally NOT set here: frame changes do not
        // alter line positions (NSText.didChangeNotification owns that). Setting it
        // here triggered an O(n) UTF-16 scan on every window resize and wrap toggle
        // with no benefit — the existing cache is still correct.
        observe(NSView.frameDidChangeNotification, object: tv) { [weak self] in
            guard let self else { return }
            self.deferredThicknessUpdate()
            self.needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        gutterBackground.setFill()
        bounds.fill()
        // Subtle right-edge separator.
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else { return }

        rebuildCacheIfNeeded()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont, .foregroundColor: lineNumberColor,
        ]
        let tcOrigin = tv.textContainerOrigin
        let textLength = (tv.string as NSString).length

        // Empty document: always show "1".
        if textLength == 0 {
            let s = "1" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(
                x: bounds.maxX - sz.width - padding,
                y: convert(NSPoint(x: 0, y: tcOrigin.y), from: tv).y
            ), withAttributes: attrs)
            return
        }

        // Visible glyph range in container coordinates.
        let visibleInContainer = tv.visibleRect.offsetBy(
            dx: -tcOrigin.x, dy: -tcOrigin.y)
        let glyphRange = lm.glyphRange(forBoundingRect: visibleInContainer, in: tc)
        guard glyphRange.location != NSNotFound else { return }

        // One number per logical line — skip wrapped-line continuations.
        var drawnStarts = Set<Int>()

        lm.enumerateLineFragments(forGlyphRange: glyphRange) {
            [self] _, usedRect, _, fragGlyphRange, _ in

            guard fragGlyphRange.location != NSNotFound else { return }
            let charRange = lm.characterRange(
                forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            guard charRange.location < textLength else { return }

            // cachedLineStarts already holds the logical line start for every
            // line (built by rebuildCacheIfNeeded above). Reusing it avoids the
            // O(k) UTF-16 scan that NSString.lineRange(for:) performs per fragment,
            // turning the deduplication probe from O(visible_frags × line_len) to
            // O(log n) (the binary search inside lineNumber(forCharLocation:)).
            let lineStart = self.cachedLineStarts[
                self.lineNumber(forCharLocation: charRange.location) - 1]
            guard !drawnStarts.contains(lineStart) else { return }
            drawnStarts.insert(lineStart)

            let lineNum = self.lineNumber(forCharLocation: lineStart)
            let label = "\(lineNum)" as NSString
            let sz = label.size(withAttributes: attrs)
            let viewY = usedRect.minY + tcOrigin.y
            let rulerY = self.convert(NSPoint(x: 0, y: viewY), from: tv).y
            let drawY = rulerY + (usedRect.height - sz.height) / 2.0
            label.draw(at: NSPoint(
                x: self.bounds.maxX - sz.width - self.padding, y: drawY
            ), withAttributes: attrs)
        }

        // Extra line fragment — cursor on a trailing blank line.
        if lm.extraLineFragmentTextContainer != nil {
            let extraRect = lm.extraLineFragmentUsedRect
            let lineNum = cachedLineStarts.count + 1
            let label = "\(lineNum)" as NSString
            let sz = label.size(withAttributes: attrs)
            let viewY = extraRect.minY + tcOrigin.y
            let rulerY = convert(NSPoint(x: 0, y: viewY), from: tv).y
            let drawY = rulerY + (extraRect.height - sz.height) / 2.0
            label.draw(at: NSPoint(
                x: bounds.maxX - sz.width - padding, y: drawY
            ), withAttributes: attrs)
        }
    }

    // MARK: - Thickness

    private func initialThickness() -> CGFloat {
        thickness(forDigits: Self.minimumDigits)
    }

    private func thickness(forDigits digits: Int) -> CGFloat {
        let w = ("8" as NSString).size(withAttributes: [.font: lineNumberFont]).width
        return ceil(w * CGFloat(max(digits, Self.minimumDigits)) + padding * 2)
    }

    /// Deferred because setting `ruleThickness` calls `scrollView.tile()`, which
    /// must not happen mid-draw.
    private func deferredThicknessUpdate() {
        rebuildCacheIfNeeded()
        let needed = thickness(forDigits:
            max(Self.minimumDigits, String(cachedLineStarts.count).count))
        guard abs(needed - ruleThickness) > 0.5 else { return }
        RunLoop.main.perform { [weak self] in
            guard let self else { return }
            self.ruleThickness = needed
            self.needsDisplay = true
        }
    }

    // MARK: - Line-start cache

    private func rebuildCacheIfNeeded() {
        guard let tv = textView else { return }
        let len = (tv.string as NSString).length
        guard needsCacheRebuild || len != cachedTextLength else { return }
        var starts: [Int] = [0]
        var i = 0
        for u in tv.string.utf16 {
            i += 1
            if u == 10 { starts.append(i) }    // '\n' == 10; offset is char AFTER it
        }
        cachedLineStarts = starts
        cachedTextLength = len
        needsCacheRebuild = false
    }

    /// O(log n) binary search for the 1-based line number containing `loc`.
    private func lineNumber(forCharLocation loc: Int) -> Int {
        let loc = max(0, min(loc, cachedTextLength))
        var lo = 0, hi = cachedLineStarts.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cachedLineStarts[mid] <= loc { best = mid; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return best + 1
    }
}
