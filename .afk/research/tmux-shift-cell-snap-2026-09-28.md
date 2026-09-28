# tmux "shifts everything" on the external monitor — diagnosis (2026-09-28)

## Symptom
Screenshot, Goblin Portal fullscreen on the 1x ES-G27F4Q (2560x1440), tmux 3.6a with a
vertical split (afk REPL left, zsh right), font zoomed to 18pt (`GoblinPortal.fontSizeOverride`),
`"renderer": "metal"`. tmux's `│` border drew ~44-52px (~4 columns) right of where the right
pane's text starts, cutting through `~/Pr│/open_source`; the goblin half-block art sat right of
the text column it is laid out against.

## Root cause
1. SwiftTerm snaps the cell width ONCE, at font-set time: `ceil(w*scale)/scale`, with
   `scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor`
   (`Apple/AppleTerminalView.swift:272-276`, `Mac/MacTerminalView.swift:771-774`). The vendored
   view has no `viewDidChangeBackingProperties`, so nothing re-snaps when the window moves to a
   display with a different scale.
2. The two glyph paths disagree on a fractional cell. Text: `cellWidth * column`
   (`Apple/Metal/MetalTerminalRenderer.swift:1222`). Box-drawing / block glyphs:
   `column * round(cellWidthPx)` (`:895`, `:946`, `:994` unless anti-aliased blocks). Core Text
   does the same (`Apple/AppleTerminalView.swift:1236`), so `renderer: coretext` is NOT a
   workaround.
3. System mono 18pt: raw advance 11.127pt → snapped at 2x = 11.5pt → on a 1x screen 11.5px text
   steps vs 12px box steps → +0.5px/col → +52px at column 104. At 14pt the 2x snap is 9.0 and
   nothing drifts. Only snapped-HIGH/drawn-LOW drifts (a 1x snap is whole points, whole px at 2x).

Fix: `GoblinPortalTerminalView+CellSnap.swift` re-applies the font (the ⌘+ zoom path) when the
view's window scale differs from the recorded snap scale. Gate: `app/Scripts/check-cell-snap.sh`.

## Ruled out, with evidence
- **Emulator / tmux protocol divergence.** A real tmux 3.6a recorded in a pty (private socket,
  margins+rectfill features forced as live), replayed byte-for-byte with resizes at exact
  offsets through the vendored `Terminal`, compared against tmux's own `capture-pane` per pane:
  single pane, vertical split, horizontal split, 3 panes, a 7-step fullscreen-style resize
  storm, and the storm with output in flight — **0 mismatched rows in all six**. Tools:
  `.afk/tmp/tmuxdiff/{record.py,replay.swift,compare.py}`. This refutes a static audit's claims
  of margin (DECSLRM/DECLRMM), ECH and SU/SD bugs for tmux's traffic.
- **`softReset()` on a same-size `resize()`** (`AppleTerminalView.swift:2245-2250`, reached on
  every ⌘R / Preferences save via `view.font = …`) does reset scroll region + L/R margins without
  a SIGWINCH — real, but replaying a no-SIGWINCH softReset mid-split showed 0 mismatches: tmux
  re-sends DECSTBM/DECSLRM before each scroll. Latent hazard (it also resets SGR, DECCKM), not
  this bug.
- **Metal row cache staleness.** Every `BufferLine` mutator bumps `generation`
  (`BufferLine.swift:40`), and the cache signature carries scale/cols/rows/alt-buffer.
- **Status bar ~2 columns short of the right edge.** Reserved legacy-scroller width plus the
  fractional remainder; benign.
- **"Interac / tive Mode" wrap in the left pane.** tmux reflowing a line afk drew at a wider
  pane width; expected tmux behaviour, not an emulator defect.

## Side finding (not fixed)
`check-pane-teardown.sh` (and any gate copying it) runs plain `swift build`, which on the current
toolchain refreshes `.build/arm64-apple-macosx/`, then links objects from `.build/out/` — written
only by `--build-system swiftbuild`. Those were stale (Sep 27) until a swiftbuild build ran, so
such a gate can pass against old code. `check-cell-snap.sh` uses the swiftbuild backend.
