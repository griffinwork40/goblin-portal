//
//  SpaceViewController+FocusCue.swift
//  Accent-border focus cue for split panes — the visible complement to hollow cursor.
//
//  WHY THIS EXISTS
//
//  Under the default theme (classic-repaired), `PaneDimming.effectiveOpacity` returns
//  1.0 because the undimmed body text (#8A8A8A on #000000, Lc 39.6) is already below
//  the Lc 45 floor — any opacity < 1.0 would only worsen contrast. The hollow
//  unfocused cursor that SwiftTerm draws is then the sole split-focus cue, which is
//  subtle enough to be missed. This file supplies a second cue that never touches text
//  contrast: a 1pt border layer on the focused pane's TerminalClipView, coloured from
//  `config.effectiveAccent` (the cursor/accent colour) at 0.55 alpha.
//
//  DESIGN CHOICE — always show when split, not only when dimming is ineffective
//
//  The cue is shown whenever a tab has ≥ 2 panes, regardless of the effective opacity.
//  Rationale: dimming and a border address different perceptual channels. Dimming draws
//  the eye away from unfocused panes; the border draws it toward the focused one. They
//  are complementary, not substitutes. Showing the border only when opacity == 1.0 would
//  make its behaviour theme-dependent (visible under classic-repaired, absent under
//  umber), which is harder to reason about and harder to test than "always with splits".
//  A user who finds the border redundant may want a `showFocusBorder: false` config key
//  to disable it — no such key exists in `ConfigFile`/`AppConfig` yet; wire only if
//  daily-drive reveals the demand (tracked in #249).
//
//  IMPLEMENTATION
//
//  A `CALayer` named `"goblin.focusBorder"` is added to the focused pane's
//  `TerminalClipView.layer`. It is sized to the clip view's bounds with an inset of
//  0.5pt so the 1pt stroke is entirely INSIDE the pane — it never overlaps the divider
//  or a neighbouring pane's pixel row, and it never covers a terminal cell (it is drawn
//  on the inside face of the clip, where the cell grid has already ended). The layer is
//  removed from every non-focused pane. CALayer add/remove is used rather than
//  `alphaValue` because the clip view's own `alphaValue` is already managed by
//  `updateSplitDimming`; stacking two opacity-animated properties on the same view
//  produces unpredictable compositing.
//
//  RESIZE TRACKING
//
//  `SplitContainerView.layout()` resizes pane frames on every window resize and divider
//  drag without re-running `updateFocusCue`, so `TerminalClipView.layout()` re-frames
//  the border on every layout pass. The layer name and the inset rule both live on
//  `TerminalClipView` (`focusBorderLayerName`, `focusBorderFrame(in:)`) so this file and
//  the view cannot disagree about either.
//
//  `update(focusCue:accentColor:)` is called from `updateSplitDimming` after the
//  dimming pass, so a single code path drives both effects for every focus-change event:
//  ⌘⇧H/J/K/L, clicks, splits, collapse, tab switch, and ⌘R reload.
//
//  LIVE ACCENT-COLOUR REFRESH (#249)
//
//  When no theme is set (`"preset": "classic"`), `effectiveAccent` falls back to
//  `NSColor.controlAccentColor` (Config+Chrome.swift:102) — a dynamic catalog colour.
//  `.cgColor` on a catalog colour resolves for the current appearance at the moment of
//  the call, so a System Settings accent-colour change made mid-session was only
//  reflected at the next `apply(config:)` call. The observer added in
//  `subscribeToSystemColorChanges()` catches `NSColor.systemColorsDidChangeNotification`
//  and re-runs `updateSplitDimming` so the border colour updates immediately.
//
//  `SpaceViewController.viewDidLoad()` calls `subscribeToSystemColorChanges()` once.
//  The `NotificationCenter` token is held in `systemColorObserver` and removed in
//  `unsubscribeFromSystemColorChanges()`, called from the `deinit`-equivalent
//  `tearDownAllDocuments()` path via `SpaceDocument` lifecycle — or automatically when
//  the token is released because `NotificationCenter.default.addObserver(forName:…)`
//  returns an opaque object whose dealloc removes the observation.
//
//  WHAT IS NOT VERIFIED
//
//  Rendering is unverified by an automated gate — the border is a CALayer mutation and
//  requires a live window. Visual correctness (border visible, correct colour, animates
//  on focus change, disappears after collapse) is documented in
//  `.afk/verification/focus-cue-checklist.md` for daily-drive confirmation.
//  Case K (border tracks resize) is gated mechanically by `check-focus-cue.sh`.
//

import AppKit

extension SpaceViewController {

    // MARK: - System accent-colour subscription

    /// Subscribe to `NSColor.systemColorsDidChangeNotification` so that a mid-session
    /// System Settings accent-colour change is reflected in the focus border immediately,
    /// without requiring a `⌘R` config reload.
    ///
    /// Only matters when `effectiveAccent` resolves to `NSColor.controlAccentColor` —
    /// i.e. when `"preset": "classic"` is active or the theme has no cursor colour.
    /// Under a real theme the colour is a fixed hex value and the notification fires
    /// harmlessly (re-running `updateSplitDimming` is cheap and idempotent).
    ///
    /// Called once from `viewDidLoad()`. The returned token is stored in
    /// `systemColorObserver`; releasing it (or calling `unsubscribeFromSystemColorChanges()`)
    /// removes the observation — no dangling reference.
    func subscribeToSystemColorChanges() {
        systemColorObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Re-resolve the accent colour and repaint the focus border.
            // `activeDocument` is nil when no split is open, and `updateSplitDimming`
            // is a no-op when there is no split entry, so this is safe to call
            // unconditionally. MainActor isolation is guaranteed because the observer
            // is delivered on `.main` (queue: .main above).
            MainActor.assumeIsolated {
                if let active = self.activeDocument {
                    self.updateSplitDimming(for: active)
                }
            }
        }
    }

    /// Remove the system-colour observer. Called when the Space is torn down.
    ///
    /// Defensive — the token's own dealloc already removes the observation, but
    /// explicit removal makes the lifecycle clear and guards against a future refactor
    /// that holds the token somewhere with a longer lifetime.
    func unsubscribeFromSystemColorChanges() {
        if let token = systemColorObserver {
            NotificationCenter.default.removeObserver(token)
            systemColorObserver = nil
        }
    }

    // MARK: - Focus cue (accent border on the focused pane)

    /// Update the 1pt accent border that marks the focused pane.
    ///
    /// Called from `updateSplitDimming` after the opacity pass. `leaves` and
    /// `focusedView` are the same values already computed there — passed in to
    /// avoid repeating `gatherLeaves` and `firstResponder` queries.
    ///
    /// - Parameters:
    ///   - leaves:      All visible leaf panes for the current tab.
    ///   - focusedView: The `documentView` (`TerminalClipView`) of the focused pane,
    ///                  or `nil` when no pane has focus yet.
    ///   - accentColor: `config.effectiveAccent` — the theme's cursor/accent colour.
    func updateFocusCue(
        leaves: [LeafPane],
        focusedView: NSView?,
        accentColor: NSColor
    ) {
        guard leaves.count > 1 else {
            // Single-pane tab: remove any stale border (e.g. after collapse).
            removeFocusBorder(from: leaves.first?.view)
            return
        }

        // Resolve the accent CGColor once. `.cgColor` resolves a dynamic catalog
        // colour (like `NSColor.controlAccentColor`) for the current appearance at
        // the moment of call — which is correct now that `subscribeToSystemColorChanges()`
        // re-runs this path whenever the system accent changes mid-session (#249).
        let borderCGColor = accentColor.withAlphaComponent(0.55).cgColor

        for leaf in leaves {
            if leaf.view === focusedView {
                addFocusBorder(to: leaf.view, color: borderCGColor)
            } else {
                removeFocusBorder(from: leaf.view)
            }
        }
    }

    // MARK: - Private layer helpers

    /// Add (or update) the focus border layer on `view`.
    ///
    /// If the layer already exists (e.g. after a resize or theme reload), its
    /// frame and colour are refreshed in place rather than replaced, to avoid
    /// the implicit animation a layer-tree mutation would trigger.
    private func addFocusBorder(to view: NSView?, color: CGColor) {
        guard let hostLayer = view?.layer else { return }

        let border: CALayer
        if let existing = hostLayer.sublayers?.first(where: { $0.name == TerminalClipView.focusBorderLayerName }) {
            border = existing
        } else {
            let newLayer = CALayer()
            newLayer.name = TerminalClipView.focusBorderLayerName
            newLayer.zPosition = 1000   // above cell content; below any overlay views
            hostLayer.addSublayer(newLayer)
            border = newLayer
        }

        // Disable the implicit position/bounds/colour animations that CALayer applies
        // by default: the border should snap with focus, not lag behind it. The frame
        // is set here too; TerminalClipView.layout() keeps it current on every resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = TerminalClipView.focusBorderFrame(in: hostLayer.bounds)
        border.borderWidth = 1.0
        border.borderColor = color
        CATransaction.commit()
    }

    /// Remove the focus border layer from `view` if one is present.
    private func removeFocusBorder(from view: NSView?) {
        guard let sublayers = view?.layer?.sublayers else { return }
        for layer in sublayers where layer.name == TerminalClipView.focusBorderLayerName {
            layer.removeFromSuperlayer()
        }
    }
}
