//
//  DocumentTabStrip.swift
//  The in-window document tabs. Hand-rolled, on purpose.
//
//  Native macOS window tabs are KEPT by this design — they were promoted to mean
//  *Spaces* (projects), which is where drag-out-to-detach and Merge All Windows
//  actually mean something (plan §12.3, branch C). They cannot also serve
//  documents: a window tab is an NSWindow, so a mixed terminal/editor strip would
//  put each document in its own window and there could be no shared sidebar
//  (plan §12.2). Hence this strip — the one piece of chrome (C) pays to hand-roll.
//
//  Drawn in a single view with rect hit-testing rather than assembled from
//  per-tab NSButton/NSTextField subviews. Fewer moving parts, no subview
//  teardown churn on every title change (the shell repaints titles constantly via
//  OSC 0/2), and exact control of the one visual trick that makes a flat strip
//  read correctly: the active tab is painted in the *terminal's* background colour
//  so it merges with the content below it, while inactive tabs sit on a slightly
//  contrasted rail.
//

import AppKit

@MainActor
protocol DocumentTabStripDelegate: AnyObject {
    func tabStrip(_ strip: DocumentTabStrip, didSelect index: Int)
    func tabStrip(_ strip: DocumentTabStrip, didRequestClose index: Int)
    func tabStripDidRequestNewDocument(_ strip: DocumentTabStrip)
}

@MainActor
final class DocumentTabStrip: NSView {
    struct Item {
        let title: String
        let symbolName: String
        /// Unsaved changes. Drawn as a dot where the × would go — see `draw`.
        var isEdited: Bool = false
        /// What this document wants the user to know. Drawn in the same box as the
        /// unsaved dot, with the same hover-reveals-× rule — see `drawStatusDot`.
        var status: DocumentStatus = .idle
    }

    /// Matches the visual weight of a Safari/Ghostty tab rail. Anything taller
    /// starts stealing rows from the terminal, which is the primary surface.
    static let height: CGFloat = 30

    /// Hard floor on a tab's width, and the reason the strip can be laid out at all
    /// at high document counts. It was 96 — a *comfort* number that read well but
    /// was applied as a floor with no escape hatch, so past ~8 documents on a normal
    /// window `tabRect` handed out x positions beyond `bounds.width`: those tabs (and
    /// the "+" at `count * tabWidth`) were drawn and hit-tested off the right edge and
    /// were unreachable by mouse, ⌘1–9 being the only way to select them.
    ///
    /// 56 is derived from `drawTab`, not picked: padding 8 + symbol 12 + gap 5 +
    /// close box 15 + padding 8 = 48pt of fixed furniture, so 56 keeps the icon and
    /// the close/edited box intact and merely elides the title (`drawTab` already
    /// declines to draw text when the reserved span collapses — see the
    /// `textRight > textLeft` guard). Below that a tab is not a tab, so anything that
    /// does not fit at 56 moves into the overflow menu instead of being squeezed
    /// into an unclickable sliver.
    // why these six are internal, not `private`: they are the strip's geometry metrics
    // and this file is their ONE definition. Drawing measures the close box and the text
    // inset from them, so they have to cross the file edge — the alternative is a second
    // copy of `closeBoxSide` in the drawing file, which is exactly the silent divergence
    // AFK.md's "one source of truth for defaults" convention exists to prevent.
    static let minTabWidth: CGFloat = 56
    static let maxTabWidth: CGFloat = 210
    static let newButtonWidth: CGFloat = 30
    /// The chevron that opens the full document list. Narrower than the "+" because
    /// it is a fallback affordance, not one you reach for every few minutes.
    static let overflowButtonWidth: CGFloat = 24
    static let closeBoxSide: CGFloat = 15
    static let horizontalPadding: CGFloat = 8

    weak var delegate: DocumentTabStripDelegate?

    // Everything below was `private` when the strip was one file. Drawing and the
    // accessibility tree now live in sibling files and Swift's `private` stops at the
    // file edge, so each property is promoted to the narrowest level that still
    // compiles — never `public`, and `private(set)` wherever the writer stayed here.
    //
    // why `private(set)`: `reload` below is the only writer of these two, and the two
    // reading files (drawing, accessibility) must never mutate them. `private(set)`
    // makes that *mechanical* rather than a convention — the drawn strip, the spoken
    // strip and the hit-tested strip cannot drift apart because only one path assigns.
    private(set) var items: [Item] = []
    private(set) var activeIndex: Int = 0
    // why plain internal and not `private(set)`: hover is written by `mouseMoved` /
    // `mouseExited`, which moved to `DocumentTabStrip+Mouse.swift`. A `private(set)`
    // here would not compile for that file, and routing four flags through a setter
    // would mean rewriting the tracking code rather than moving it. Drawing reads all
    // four; the mouse file is still their only writer.
    var hoveredTab: Int?
    var hoveredClose: Int?
    var isHoveringNewButton = false
    var isHoveringOverflowButton = false
    /// Tab index the middle button went down on, held until the matching up so a
    /// press-then-drag-away does not close anything. See `otherMouseDown`.
    // why internal: `otherMouseDown` / `otherMouseUp` in `DocumentTabStrip+Mouse.swift`
    // are its only reader and writer, and they need write access from that file.
    var middleClickCandidate: Int?

    /// Colours are pushed in from the resolved config rather than read from a
    /// global: a nil theme leaves SwiftTerm on its own defaults (black), and the
    /// strip has to agree with whatever the terminal actually rendered or the two
    /// halves of the window visibly disagree — the same reasoning as
    /// `SpaceWindowController`'s window `backgroundColor`.
    // why `private(set)`: drawing reads both on every paint; `apply(background:foreground:)`
    // below is the only writer, which is the invariant that keeps the strip agreeing
    // with the terminal.
    private(set) var contentBackground: NSColor = .black
    private(set) var contentForeground: NSColor = .white
    /// Accent colour for the active-tab indicator line. Sourced from `effectiveAccent`
    /// in `Config+Chrome.swift` — see its doc comment for the sourcing rationale.
    private(set) var contentAccent: NSColor = .controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — views are created programmatically")
    }

    // MARK: - Input from the owner

    func apply(background: NSColor, foreground: NSColor, accent: NSColor) {
        contentBackground = background
        contentForeground = foreground
        contentAccent = accent
        needsDisplay = true
    }

    func reload(items: [Item], activeIndex: Int) {
        self.items = items
        self.activeIndex = activeIndex
        needsDisplay = true
    }

    // MARK: - Geometry
    //
    // One source of truth for the layout, consumed by both drawing and hit
    // testing. Two independent copies of this arithmetic is how a strip ends up
    // closing the tab next to the one you clicked.
    //
    // That invariant is now *structural*: everything geometric derives from a single
    // `Layout` value, so the visible window cannot be computed one way for `draw`
    // and another way for `mouseDown`.
    //
    // Strategy for more documents than fit: compress to a 56pt floor, then window
    // the strip and put the whole document list behind an overflow chevron.
    //   - Compress first because it is free and covers the common case: a
    //     1200pt window fits 20 tabs at the floor, so most people never see the
    //     chevron at all.
    //   - Window (rather than pan/scroll) because the window is *derived from
    //     `activeIndex`* and needs no stored scroll offset — one less piece of state
    //     to get stale against `reload`, and it makes ⌘1–9 / ⌘⇧[ ] scroll the strip
    //     for free: selecting a document always brings it into view.
    //   - Overflow *menu* rather than trackpad scrolling as the escape hatch,
    //     because a menu is the affordance that is guaranteed reachable — it is
    //     pinned to the right edge, keyboard- and VoiceOver-navigable, and lists
    //     every document including the ones the window is not showing. Trackpad
    //     scrolling would leave a mouse-only user with no visible way to reach a
    //     tab, which is the exact bug being fixed.
    //
    // Layout is strictly left-to-right and always ends at `bounds.maxX`:
    // [visible tabs][overflow chevron, if overflowing][+]. Nothing is ever placed
    // past the right edge, which is what the pre-fix `CGFloat(index) * tabWidth`
    // and `CGFloat(items.count) * tabWidth` both did once `tabWidth` hit its floor.

    /// A resolved layout for the current `bounds`, `items` and `activeIndex`.
    /// Purely derived — no stored scroll state to fall out of sync.
    // why internal: drawing and the accessibility tree both take a resolved `Layout`
    // as a parameter so they cannot re-derive the visible window a second way.
    struct Layout {
        let tabWidth: CGFloat
        /// Absolute item indices drawn, left to right. Always contains `activeIndex`
        /// when `items` is non-empty.
        let visible: Range<Int>
        /// True when `visible` is a strict subset of `items.indices`, i.e. the
        /// chevron is present and consuming width.
        let isOverflowing: Bool
    }

    // why internal: drawing, hit-testing and the accessibility tree all resolve the
    // layout through this one property. It must out-rank `NSView.layout()`, which it
    // does once it is internal — while it was `private` the sibling files silently fell
    // through to the inherited method ("value of type '@MainActor @Sendable () -> Void'
    // has no member 'visible'"), so the promotion is what makes the single-source-of-
    // truth claim above hold across the split rather than only within this file.
    var layout: Layout {
        guard !items.isEmpty else {
            return Layout(tabWidth: 0, visible: 0..<0, isOverflowing: false)
        }

        // The "+" is never sacrificed: it is the only way to open a document with
        // the mouse, so its width comes off the top before tabs get any.
        let withoutNewButton = max(bounds.width - Self.newButtonWidth, 0)
        let fitsAtFloor = Int(withoutNewButton / Self.minTabWidth)

        if items.count <= fitsAtFloor {
            // Everything fits: divide evenly, clamped as before. `maxTabWidth` is
            // what leaves the "+" adjacent to the last tab instead of stranded at
            // the far edge of a wide window.
            let even = withoutNewButton / CGFloat(items.count)
            let width = min(max(even, Self.minTabWidth), Self.maxTabWidth)
            return Layout(tabWidth: width, visible: items.indices, isOverflowing: false)
        }

        let forTabs = max(bounds.width - Self.newButtonWidth - Self.overflowButtonWidth, 0)
        // `max(_, 1)` so a window too narrow for even one floor-width tab still
        // draws one (degenerate, sub-floor) tab rather than dividing by zero. The
        // chevron stays reachable in that state, so no document is lost.
        let count = max(Int(forTabs / Self.minTabWidth), 1)
        let width = min(forTabs / CGFloat(count), Self.maxTabWidth)

        // Slide the window just far enough to contain the active tab. Anchoring on
        // the selection is why no scroll offset has to be stored or invalidated.
        var first = min(max(activeIndex - count + 1, 0), max(items.count - count, 0))
        if activeIndex < first { first = activeIndex }
        let upper = min(first + count, items.count)
        return Layout(tabWidth: width, visible: first..<upper, isOverflowing: true)
    }

    /// Rect for an absolute item index, or `nil` when the windowed strip is not
    /// showing that index. Returning `nil` rather than an off-screen rect is what
    /// keeps drawing and hit-testing honest about which tabs exist on screen.
    func tabRect(_ index: Int, _ layout: Layout) -> NSRect? {
        guard layout.visible.contains(index) else { return nil }
        let slot = CGFloat(index - layout.visible.lowerBound)
        return NSRect(x: slot * layout.tabWidth, y: 0, width: layout.tabWidth, height: bounds.height)
    }

    func closeRect(_ tab: NSRect) -> NSRect {
        NSRect(
            x: tab.maxX - Self.horizontalPadding - Self.closeBoxSide,
            y: (tab.height - Self.closeBoxSide) / 2,
            width: Self.closeBoxSide,
            height: Self.closeBoxSide
        )
    }

    /// Pinned to the right edge, immediately left of the "+". Both buttons are
    /// measured back from `bounds.maxX` so neither can be pushed off by tab count.
    func overflowButtonRect(_ layout: Layout) -> NSRect? {
        guard layout.isOverflowing else { return nil }
        return NSRect(
            x: bounds.maxX - Self.newButtonWidth - Self.overflowButtonWidth, y: 0,
            width: Self.overflowButtonWidth, height: bounds.height
        )
    }

    func newButtonRect(_ layout: Layout) -> NSRect {
        // When overflowing, the tabs plus the chevron consume exactly the width up
        // to `bounds.maxX - newButtonWidth`, so both branches agree; the explicit
        // right-edge anchor is the guarantee, not the coincidence.
        let x =
            layout.isOverflowing
            ? bounds.maxX - Self.newButtonWidth
            : min(
                CGFloat(layout.visible.count) * layout.tabWidth,
                max(bounds.maxX - Self.newButtonWidth, 0))
        return NSRect(x: x, y: 0, width: Self.newButtonWidth, height: bounds.height)
    }

    func tabIndex(at point: NSPoint, _ layout: Layout) -> Int? {
        guard layout.tabWidth > 0, point.x >= 0 else { return nil }
        let slot = Int(point.x / layout.tabWidth)
        guard slot >= 0, slot < layout.visible.count else { return nil }
        let index = layout.visible.lowerBound + slot
        return items.indices.contains(index) ? index : nil
    }

    /// The one read accessor for `items`, shared by drawing and the accessibility
    /// tree. Internal rather than `private` because both of those now live in sibling
    /// files and Swift's `private` stops at the file edge; keeping a single accessor
    /// is what stops three files from each writing their own `items[index]` and
    /// disagreeing about what an out-of-range index means.
    func item(_ index: Int) -> Item { items[index] }
}
