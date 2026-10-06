//
//  GoblinPortalTerminalView+SmoothScroll.swift
//  Pixel-smooth trackpad scrolling wiring for the terminal view: the scroll-event monitor,
//  the callbacks into SwiftTerm and the layer, and the NSView overrides that snap to the grid.
//
//  The gesture state machine lives in `SmoothScrollModel.swift` (Foundation-only, gated by
//  `check-smooth-scroll.sh`); the NSEvent-to-model adapter and grace timer in `SmoothScroll.swift`.
//  Nothing in this file can be compiled headless, so the routing below (which pane owns an
//  event, when to snap) is daily-drive verified, not gated.
//
//  SwiftTerm's `scrollWheel(with:)` is `public` (not `open`, Mac/MacTerminalView.swift:2754),
//  so subclasses outside the module cannot override it. We intercept scroll events via an
//  `NSEvent.addLocalMonitorForEvents` monitor instead: it fires before the responder chain,
//  and returning `nil` consumes the event so SwiftTerm's line-by-line path never sees it.
//  Returning the event unchanged lets SwiftTerm handle it normally (hardware wheel, alternate
//  buffer, mouse reporting, or feature disabled).
//
//  The `@objc` NSView overrides (`viewDidMoveToWindow`, `mouseDown`) live here rather than in
//  the class to keep `GoblinPortalTerminalView.swift` under the 350-LOC ceiling. Swift allows
//  overriding `@objc` members in an extension; the stored properties they touch
//  (`smoothScroll`, `scrollMonitor`) stay in the class, where they must. Clipping the shift
//  is not done here: it belongs to the pane's own `TerminalClipView` (see that file for why
//  the shared split container cannot do it).
//

import AppKit
import SwiftTerm

extension GoblinPortalTerminalView {

    // MARK: - View lifecycle overrides

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installScrollMonitor() } else { removeScrollMonitor() }
        resnapCellGridIfNeeded()  // cell-snap: see +CellSnap.swift for why
    }

    /// Drop to the grid before a click: selection and mouse reporting both map the click's
    /// point to a cell (MacTerminalView.swift:2491), and a half-cell offset would pick the
    /// wrong row.
    override func mouseDown(with event: NSEvent) {
        smoothScroll.snapToGrid(reason: "mouseDown")
        super.mouseDown(with: event)
    }

    // MARK: - Scroll event monitor

    /// True when the smooth path may run at all. Alternate buffer (vim, less) has no scrollback
    /// to scroll through, and mouse reporting means the program wants the wheel itself; both
    /// are SwiftTerm's to handle (Mac/MacTerminalView.swift:2754-2811).
    var smoothScrollEligible: Bool {
        let t = getTerminal()
        return smoothScrollEnabled && !t.isCurrentBufferAlternate && t.mouseMode == .off
    }

    /// Install the local scroll-event monitor. Called from `viewDidMoveToWindow`
    /// when the view gains a window; removed when the view loses it.
    ///
    /// Every terminal pane installs its own monitor, and each decides for itself (review
    /// item 2). There is deliberately NO first-responder test: before this feature, scrolling
    /// an unfocused split pane scrolled THAT pane, because AppKit routes a scroll to the view
    /// under the pointer. The pointer test restores that, and also stops a focused terminal
    /// from stealing scrolls aimed at the sidebar file tree or Source Control outline.
    func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            guard self.smoothScrollEligible else {
                // The path flipped ineligible mid-gesture (an app entered the alt buffer or
                // turned mouse mode on while momentum ran). Land on the grid and hand over.
                if self.smoothScroll.isMidGesture { self.smoothScroll.snapToGrid(reason: "ineligible") }
                return event
            }
            // `isHiddenOrHasHiddenAncestor` covers a pane that is still in the window but
            // hidden. `convert(_:from:)` ignores the layer transform, which is what we want:
            // the claim is about the view's frame, not where its pixels currently sit.
            let point = self.convert(event.locationInWindow, from: nil)
            let inside = !self.isHiddenOrHasHiddenAncestor && self.bounds.contains(point)
            return self.smoothScroll.handleScrollWheel(event, pointerInside: inside) ? nil : event
        }
    }

    /// Remove the scroll-event monitor. Called when the view loses its window, which is a tab
    /// switch or a split (SplitContainerView.swift:89, :134-144), NOT a close. So this must
    /// be fully reversible: snap to the grid but keep the callbacks, and the monitor comes back
    /// on `viewDidMoveToWindow`. Final teardown is `smoothScroll.invalidate()`, from
    /// `TerminalPane.documentWillClose()` only (review item 1).
    func removeScrollMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        smoothScroll.snapToGrid(reason: "window")
    }

    // MARK: - Smooth scroll callbacks

    /// Wire `SmoothScroll` to the terminal view. Called from `TerminalPane.apply(config:)` on
    /// every config load, so it must be idempotent. The callbacks are wired unconditionally,
    /// even when the cell height is still zero (a zero-size initial frame): `layout()` fills
    /// in the height later (`layout()` is owned by `GoblinPortalTerminalView+SearchOverlay.swift`),
    /// and an unwired callback would make the monitor swallow scrolls.
    func configureSmoothScroll() {
        smoothScroll.cellHeight = terminalCellSize.height

        smoothScroll.onScrollLines = { [weak self] lines in
            guard let self else { return }
            // Feed whole-line scrolls back into SwiftTerm's public TerminalView API
            // (AppleTerminalView.swift:2138/2145). These are on the view, not Terminal.
            if lines > 0 {
                self.scrollUp(lines: lines)
            } else if lines < 0 {
                self.scrollDown(lines: -lines)
            }
        }

        smoothScroll.onOffsetChanged = { [weak self] offset in
            guard let self else { return }
            // WHY the sign goes through `layerTranslationY`: a positive model offset means
            // "part of the way to the next `scrollUp`", and `scrollUp` moves content DOWN the
            // screen (AppleTerminalView.swift:2138-2142 lowers `yDisp`). The transform is in
            // the superlayer's space, and no view in this chain overrides `isFlipped`, so +y
            // points UP there and the shift needs the opposite sign. Using +offset directly
            // (the first cut) moved the partial shift against the whole-line step and made
            // every gesture jitter (review item 6). The model owns the mapping so that the
            // headless gate can pin it. See `layerTranslationY` for the evidence behind the sign.
            let dy = SmoothScrollModel.layerTranslationY(
                offset: Double(offset), superviewFlipped: self.superview?.isFlipped ?? false)
            self.layer?.setAffineTransform(
                offset == 0 ? .identity : CGAffineTransform(translationX: 0, y: CGFloat(dy)))
        }

        smoothScroll.isEligible = { [weak self] in self?.smoothScrollEligible ?? false }

        // Where `scrollUp`/`scrollDown` would clamp (AppleTerminalView.swift:2138-2149). Only
        // public SwiftTerm surface is read; see `ScrollHeadroom.derive` for why and how.
        smoothScroll.headroom = { [weak self] in
            guard let self else { return .pinned }
            return ScrollHeadroom.derive(yDisp: self.getTerminal().buffer.yDisp,
                                         scrollPosition: self.scrollPosition, canScroll: self.canScroll)
        }

        // A reload that turned `smoothScrolling` off, or landed while an app holds the alt
        // buffer, must not leave a sub-cell offset stranded (review item 5).
        if !smoothScrollEligible { smoothScroll.snapToGrid(reason: "ineligible") }
    }
}
