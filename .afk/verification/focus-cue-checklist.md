# Focus Cue Checklist (#166)

Rendering is unverified by an automated gate — `CALayer` mutation requires a live
window. Confirm each item with daily-drive before closing the issue.

Source: `SpaceViewController+FocusCue.swift`

## Required cases

- [ ] **A. Border appears on split** — open a tab, ⌘⇧\\ to split right; a 1pt accent
      border appears on the focused (left) pane inside its edge; no border on the right pane.

- [ ] **B. Border follows ⌘⇧H/J/K/L** — navigate between panes with keyboard shortcuts;
      border moves to the newly focused pane within the same animation frame as focus.

- [ ] **C. Border follows click** — click an unfocused pane; border moves to it immediately.

- [ ] **D. Border absent on single pane** — collapse the split (⌘W on the peer); border
      disappears entirely.

- [ ] **E. Border survives tab switch** — switch away and back to a split tab; border is
      still on the correct focused pane.

- [ ] **F. Border updates on ⌘R theme reload** — change theme in config.json, ⌘R; border
      colour updates to the new theme's accent colour.

- [ ] **G. Border survives auto appearance flip** — if `afk-light` is set (light chrome),
      switch OS between light/dark mode; border repaints correctly.

- [ ] **H. No cell overlap** — the border is drawn INSIDE the clip view (0.5pt inset);
      it does not paint over terminal cell content or the 1pt divider.

- [ ] **I. Works with 3–4 panes** — add a sub-split (⌘⇧-); border on focused pane only,
      no border on the other two/three panes.

- [ ] **J. Classic-repaired specific** — under the default theme, where dimming is
      suppressed (opacity == 1.0), the border is the sole split-focus cue alongside the
      hollow unfocused cursor. Confirm both are perceptible.

- [ ] **K. Border tracks resize** — with a split tab open, drag the window larger and
      smaller; drag the divider left and right. The border must hug the focused pane's
      edge at every size — no stale frame left over from the previous geometry.
      Mechanism: `TerminalClipView.layout()` re-applies `bounds.insetBy(dx:0.5,dy:0.5)`
      to any `"goblin.focusBorder"` sublayer with animations disabled.

## Notes

- Colour source: `config.effectiveAccent` (theme cursor colour, or `.controlAccentColor`
  as fallback). At 0.55 alpha it should be a soft tint, not a neon ring.
- Layer name: `"goblin.focusBorder"` (inspectable with Xcode view debugger).
- No automated gate was added for this concern — rendering cannot be verified headlessly.
  If a gate becomes feasible (e.g. offscreen screenshot diff), move these items there and
  tick with the gate named, per the AFK.md convention.
