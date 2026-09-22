//
//  GoblinPortalTerminalView+SmoothScroll.swift
//  Pixel-smooth trackpad scrolling wiring for the terminal view.
//
//  The scroll event monitor and mouseDown interception live here; the state
//  machine and display-link momentum live in `SmoothScroll.swift`.
//
//  SwiftTerm's `scrollWheel(with:)` is `public` (not `open`), so subclasses
//  outside the module cannot override it. We intercept scroll events via an
//  `NSEvent.addLocalMonitorForEvents` monitor instead: it fires before the
//  responder chain, and returning `nil` consumes the event so SwiftTerm's
//  line-by-line path never sees it. Returning the event unchanged lets
//  SwiftTerm handle it normally (hardware wheel, alternate buffer, mouse
//  reporting, or feature disabled).
//

import AppKit
import SwiftTerm

extension GoblinPortalTerminalView {

    // MARK: - Scroll event monitor

    /// Install the local scroll-event monitor. Called from `viewDidMoveToWindow`
    /// when the view gains a window; removed when the view loses it.
    func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard let self, self.window?.firstResponder === self else { return event }
            let t = self.getTerminal()
            guard self.smoothScrollEnabled,
                  !t.isCurrentBufferAlternate,
                  t.mouseMode == .off else { return event }
            return self.smoothScroll.handleScrollWheel(event) ? nil : event
        }
    }

    /// Remove the scroll-event monitor. Called when the view loses its window or
    /// when the view is deallocated.
    func removeScrollMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    // MARK: - Smooth scroll callbacks

    /// Wire `SmoothScroll` callbacks to the terminal view. Call once during setup
    /// (from `TerminalPane.start()` or wherever the view's cell dimensions are known).
    func configureSmoothScroll() {
        let cell = terminalCellSize
        guard cell.height > 0 else { return }
        smoothScroll.configure(view: self, cellHeight: cell.height)

        smoothScroll.onScrollLines = { [weak self] lines in
            guard let self else { return }
            // Feed whole-line scrolls back into SwiftTerm's public TerminalView API
            // (AppleTerminalView.swift:2120/2127). These are on the view, not Terminal.
            if lines > 0 {
                self.scrollUp(lines: lines)
            } else if lines < 0 {
                self.scrollDown(lines: -lines)
            }
        }

        smoothScroll.onOffsetChanged = { [weak self] offset in
            guard let self else { return }
            self.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: offset))
        }
    }
}
