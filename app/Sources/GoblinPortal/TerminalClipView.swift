//
//  TerminalClipView.swift
//  The per-pane clip that holds a terminal view, so smooth scrolling's sub-cell shift
//  stays inside the pane it belongs to.
//
//  Smooth scrolling moves the terminal's layer by up to one cell with a layer transform
//  (`GoblinPortalTerminalView+SmoothScroll.swift`, `onOffsetChanged`). A layer cannot clip
//  its own transform: `masksToBounds` on the terminal's layer moves along with it, and
//  SwiftTerm's `clipsToBounds = true` (Mac/MacTerminalView.swift:361-363) clips drawing, not
//  translation. So the clip has to belong to a PARENT, and it has to be a parent owned by
//  this pane alone. The first cut set `masksToBounds` on the terminal's superview, which is
//  the `SplitContainerView` shared by both panes and the divider. That clipped only at the
//  outer edge, so in a split the shifted pane painted over the divider and the other pane's
//  edge row. It also made the shared container layer-backed as a side effect of adding a
//  child (PR #135 re-review, R4).
//
//  This view is that parent. `TerminalPane.documentView` returns it, so everything that
//  frames, presents, splits or dims a document (SplitContainerView, DocumentAreaViewController,
//  SpaceViewController+Splits) handles the clip and never the terminal. That is the same
//  object those callers already treated as opaque. The terminal fills the clip through
//  autoresizing and stays first responder itself (TerminalPane+Document.swift,
//  `documentDidBecomeActive`), because SwiftTerm reads keys on the terminal view.
//
//  Unflipped on purpose. `SmoothScrollModel.layerTranslationY` maps the offset using the
//  superview's `isFlipped`, and the measured mapping (+y moves content UP in an unflipped
//  superlayer) is the one this view keeps.
//
//  The background is painted in the terminal's own background colour. A shifted pane
//  exposes up to one cell of this view at its leading edge, and that strip has to read as
//  more terminal, not as a gap.
//

import AppKit

@MainActor
final class TerminalClipView: NSView {
    init(hosting terminal: NSView, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        clipsToBounds = true
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — created programmatically")
    }

    override var isFlipped: Bool { false }

    /// Set from `TerminalPane.apply(config:)` after the theme is installed, so a ⌘R
    /// theme change repaints the edge strip too.
    var fillColor: NSColor = .clear {
        didSet { layer?.backgroundColor = fillColor.cgColor }
    }
}
