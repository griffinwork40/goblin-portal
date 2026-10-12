//
//  DocumentAreaViewController+SafeArea.swift
//  How much of the document area's top edge sits under the titlebar, and the
//  re-layout trigger for when that changes without the view's bounds changing.
//
//  Its own file because it is one whole concern — reconciling manual frame layout
//  with the window's titlebar — and the reason it exists is a refuted claim worth
//  keeping next to the code. `LiquidGlass.swift` used to say NSSplitViewController
//  does not propagate `safeAreaInsets.top` to this controller. Measured on macOS 27
//  with `.fullSizeContentView`: it does (32pt, 68pt with the native Space tab bar),
//  and this view's safe-area rect equals `window.contentLayoutRect` exactly. The bug
//  was that `viewDidLayout` laid out against `view.bounds` and never asked
//  (`.afk/plans/titlebar-reclaim-scope.md` §1a). Gated by `check-titlebar-layout.sh`.
//

import AppKit

extension DocumentAreaViewController {
    /// Points at the top of `view.bounds` that the titlebar (title row, native tab
    /// bar, `.bottom` accessories such as `ConfigWarningBanner`) covers. Read from
    /// `contentLayoutRect` rather than `view.safeAreaInsets` because that rect is what
    /// the KVO below observes, so the value and its change signal cannot disagree; the
    /// two were measured equal. 0 whenever the content view does not extend under the
    /// titlebar — which is the shipped default style mask — so nothing moves today.
    var layoutTopInset: CGFloat {
        guard let window = view.window else { return 0 }
        let layoutRect = view.convert(window.contentLayoutRect, from: nil)
        return max(0, view.bounds.maxY - layoutRect.maxY)
    }

    /// Re-run layout when `contentLayoutRect` moves but our bounds do not. Under
    /// `.fullSizeContentView` this view is full height, so a second Space's tab bar or
    /// the config-warning banner appearing changes the inset with no resize, and
    /// `viewDidLayout` never ran: row 0 stayed 64pt under the tab bar (measured, scope
    /// §1b). Idempotent — installs once per window.
    func observeContentLayoutRect() {
        guard layoutRectObservation == nil, let window = view.window else { return }
        layoutRectObservation = window.observe(\.contentLayoutRect, options: [.new]) {
            [weak self] _, _ in
            // AppKit changes window geometry on the main thread; the hop exists only so a
            // stray off-main notification degrades to one deferred layout, not a trap.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.view.needsLayout = true }
            } else {
                Task { @MainActor in self?.view.needsLayout = true }
            }
        }
    }
}
