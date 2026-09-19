//
//  SplitContainerView+Appearance.swift
//  Theme-aware divider colour for the split pane container.
//
//  WHY A SEPARATE FILE: `SplitContainerView.swift` sits at 345/350 LOC (the project
//  ceiling — AFK.md, "Conventions"). Any new method goes in an extension file;
//  this follows the pattern of `+Persistence.swift` extracted at the same ceiling.
//
//  WHY THIS COLOUR: the divider uses the theme's content foreground at 0.15 alpha
//  rather than the hardcoded `NSColor.gray.withAlphaComponent(0.4)`. Gray reads as
//  chromatic noise on warm palettes (umber, classic-repaired) and too saturated on
//  cool ones (tokyo-night). Deriving from the foreground ensures the divider is
//  always "the same hue as the text", which is what makes it feel like structure
//  rather than an artifact. At 0.15 it is just visible enough to locate without
//  competing with the content — the same design decision FileViewerPane+Folding uses
//  for gutter triangles (`effectiveForeground.withAlphaComponent(0.4)`, line 72).
//
//  CALL SITE: `SpaceViewController` calls `applyDividerColor` from both `viewDidLoad`
//  (initial colour) and `apply(config:)` (on ⌘R reload), mirroring the pattern the
//  tab strip uses: `documentArea.strip.apply(background:foreground:accent:)`.
//

import AppKit

extension SplitContainerView {

    /// Update the 1px divider to derive from the theme's foreground colour.
    ///
    /// Called whenever the theme changes — from `SpaceViewController.viewDidLoad` and
    /// `SpaceViewController.apply(config:)`. The divider is drawn at 0.15 alpha so it
    /// registers as structure without drawing attention away from the content.
    ///
    /// The layer property is set directly (not via `NSAnimationContext`) because a
    /// colour change on a config reload does not need a transition — the whole window
    /// is already repainting.
    func applyDividerColor(_ foreground: NSColor) {
        // `config.effectiveForeground` is already a concrete RGB colour (not a dynamic
        // system colour), so `.cgColor` is safe here — no appearance resolution needed.
        // The alpha is applied after so the .cgColor carries the right opacity.
        dividerView.layer?.backgroundColor = foreground.withAlphaComponent(0.15).cgColor
    }
}
