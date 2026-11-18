//
//  TerminalPane+DrawableShrink.swift
//  Shrink the Metal drawable to 1×1 when a tab is hidden, restore on re-show.
//
//  WHY THIS FILE EXISTS: a 2329×1564 Retina terminal drawable at BGRA8 occupies
//  ~14.2 MiB of GPU memory per pane. When a tab is hidden inside a visible window,
//  SwiftTerm's render loop already stops (patch 0010 / FrameDriver idle-pause), but
//  the CAMetalLayer drawable pool remains allocated. Setting `drawableSize` to 1×1
//  releases the pool immediately — no renderer rebuild, no glyph-atlas loss, no
//  pipeline teardown. On re-activation `setFrameSize` → `updateDrawableSize()` in
//  `TerminalMetalLayerView.swift:138-151` recomputes the full size from bounds×scale,
//  so restore is automatic even without calling `restoreDrawable()` explicitly; we
//  call it anyway (belt-and-suspenders) before `makeFirstResponder` so the first
//  frame arrives at full resolution.
//
//  VENDOR DEPENDENCY: `metalDrawableSize` and `metalContentsScale` are public
//  only via patch 0016 (0016-expose-metal-view-for-drawable-resize.patch). Without
//  the patch this file does not compile.
//
//  SPLIT-PEER GUARD: a split peer's `documentView` (the `TerminalClipView`) remains
//  in the window's view hierarchy even when its tab is not "active" in the strip —
//  `SplitContainerView` keeps both halves visible. We must NOT shrink a peer whose
//  view is still on screen. The guard `view.window != nil` is sufficient: SwiftTerm
//  removes the metal view from the window when the pane is hidden, but a split peer
//  stays attached. `clipView.window` mirrors this — if the clip is in a window the
//  pane is visible.
//

import AppKit
import SwiftTerm

extension TerminalPane {
    /// Release the Metal drawable pool by collapsing the drawable to 1×1.
    ///
    /// No-op when: not using Metal, the metal view is not a `TerminalMetalLayerView`
    /// (i.e. the MTKView fallback path is active), or the pane is still visible
    /// (split peer). Safe to call redundantly — the setter guards unchanged sizes
    /// (`TerminalMetalLayerView.swift:207`).
    func shrinkDrawable() {
        guard liveRenderer == .metal else { return }
        // Split-peer guard: if the clip view is still in a window, this pane is
        // visible (e.g. a split peer whose OTHER tab was just selected). Never
        // shrink a drawable that is currently on screen.
        guard clipView.window == nil else { return }
        view.metalDrawableSize = CGSize(width: 1, height: 1)
    }

    /// Restore the Metal drawable to the pane's current pixel size.
    ///
    /// Belt-and-suspenders: `TerminalMetalLayerView.updateDrawableSize()` already
    /// fires on the next `setFrameSize`, so the drawable self-heals on first layout.
    /// We call this explicitly in `documentDidBecomeActive()` so the very first frame
    /// after re-activation renders at full resolution rather than 1×1.
    func restoreDrawable() {
        guard liveRenderer == .metal else { return }
        let scale = view.metalContentsScale
        let size = CGSize(width: max(1, clipView.bounds.width * scale),
                         height: max(1, clipView.bounds.height * scale))
        view.metalDrawableSize = size
    }
}
