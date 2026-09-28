//
//  SmoothScroll.swift
//  The AppKit half of pixel-smooth trackpad scrolling: NSEvent in, callbacks out.
//
//  SwiftTerm's `scrollWheel(with:)` is `public`, not `open` (Mac/MacTerminalView.swift:2754),
//  so this app cannot override it. Instead `GoblinPortalTerminalView+SmoothScroll.swift`
//  installs an `NSEvent.addLocalMonitorForEvents` monitor, which sees every scroll event in
//  the app before the responder chain does. For each event the monitor decides whether this
//  terminal owns it (right window, pointer inside, smooth path eligible) and, if so, passes
//  it here. Returning `true` means the monitor returns `nil`, so SwiftTerm's line-by-line
//  path never sees the event and the two paths cannot double-scroll.
//
//  This file only translates. `NSEvent` phases become `ScrollInput` for the pure model in
//  `SmoothScrollModel.swift`, which is where every decision lives and what
//  `check-smooth-scroll.sh` gates. The model's output becomes two callbacks: `onScrollLines`
//  (a real buffer scroll) and `onOffsetChanged` (the sub-cell layer transform).
//
//  There is no display link and no timer thread. Momentum is the OS's own momentum-phase
//  event stream (see the model's header). The one timer is the post-lift grace period. It
//  is a main-actor `Task` that captures `self` weakly and carries a generation number, so a
//  closed tab can neither be kept alive by it nor be touched by it after release.
//
//  Eligibility is the caller's: alternate buffer, mouse reporting and `smoothScrolling:
//  false` all hand the event back to SwiftTerm (see `installScrollMonitor`).
//
//  ONE OWNER AT A TIME (re-review R1). An event this pane does not claim is handed to
//  `SmoothScrollModel.release`, which settles an in-flight gesture on the nearest line. That
//  covers a new swipe over the sidebar, which no terminal claims, so every pane's monitor
//  sees it. It does NOT cover a new swipe over the split peer: a local monitor that returns
//  `nil` ends dispatch, so if the peer's monitor runs first this pane never sees the event.
//  So a claimed gesture START also releases the previous owner directly, through the
//  main-actor `owner` reference below. There is only one trackpad, so there is only ever one
//  live gesture, across every pane and window.
//
//  HEADROOM (R2). `headroom` is read fresh for every event and for the grace settle, because
//  output can move `yDisp` between events. The model clamps to it; see its header.
//

import AppKit

@MainActor
final class SmoothScroll {
    private var model = SmoothScrollModel()
    private var graceTask: Task<Void, Never>?
    /// The pane that claimed the most recent gesture start. Weak, so a closed pane drops out.
    private static weak var owner: SmoothScroll?

    /// Set from the view's `layout()` and `configureSmoothScroll()`. Zero disables the path.
    var cellHeight: CGFloat = 0

    /// Whole lines to scroll. Positive = `scrollUp(lines:)` (toward earlier output).
    var onScrollLines: ((Int) -> Void)?
    /// Sub-cell offset in model sign (positive = content shifted toward earlier output).
    /// The view turns it into a screen direction via `SmoothScrollModel.layerTranslationY`.
    var onOffsetChanged: ((CGFloat) -> Void)?
    /// Re-checked when the grace timer fires, because the buffer or mouse mode can flip
    /// between a finger lift and the settle it schedules.
    var isEligible: () -> Bool = { true }
    /// Lines SwiftTerm can still scroll each way, from the view's buffer (see
    /// `ScrollHeadroom.derive`). The default never clamps, so an unwired adapter behaves as before.
    var headroom: () -> ScrollHeadroom = { .unbounded }

    var isMidGesture: Bool { model.isMidGesture }

    /// Offer one scroll event. Returns `true` when the smooth path consumed it. `pointerInside`
    /// only matters for claiming a NEW gesture; see `SmoothScrollModel.shouldClaim`.
    func handleScrollWheel(_ event: NSEvent, pointerInside: Bool) -> Bool {
        // `onScrollLines == nil` means `invalidate()` ran (the pane closed). A closed pane
        // must hand events back rather than swallow them into callbacks that no longer exist.
        guard event.hasPreciseScrollingDeltas, cellHeight > 0, onScrollLines != nil else { return false }
        let input = ScrollInput(phase: ScrollPhase(event.phase),
                                momentum: ScrollPhase(event.momentumPhase),
                                deltaY: Double(event.scrollingDeltaY),
                                cellHeight: Double(cellHeight),
                                headroom: headroom())
        guard model.shouldClaim(input, pointerInside: pointerInside) else {
            // Someone else's gesture. Settle ours if one is in flight, and hand the event on.
            // The idle case must stay free: this runs for every sidebar scroll in every pane.
            if model.isMidGesture { release() }
            return false
        }
        if input.phase == .began || input.phase == .mayBegin {
            if let prev = Self.owner, prev !== self { prev.release() }
            Self.owner = self
        }
        let out = model.handle(input)
        apply(out)
        return out.consumed
    }

    /// Settle an in-flight gesture on the nearest line because a new gesture started
    /// elsewhere. Unlike `snapToGrid`, this keeps the half-line rounding.
    private func release() {
        guard model.isMidGesture else { return }
        graceTask?.cancel()
        graceTask = nil
        apply(model.release(headroom: headroom()))
    }

    /// Drop to the grid at once, with no line step, keeping the callbacks. Used for mouseDown,
    /// typing, leaving the window, and the path turning ineligible. Leaving the window is a
    /// tab switch or a split (SplitContainerView.swift:89, :134-144), so it has to be fully
    /// reversible. The first cut nil'd the callbacks here and killed scrolling for good.
    func snapToGrid(reason: String) {
        // Called on every keystroke's `send` and every mouseDown, so the common case (idle,
        // already on the grid) must be free: no layer write, no summary line. `apply` always
        // pushes the model's offset out, so an idle zero-offset model means identity already.
        guard model.isMidGesture || model.offset != 0 || graceTask != nil else { return }
        graceTask?.cancel()
        graceTask = nil
        apply(model.snap(reason: reason))
        onOffsetChanged?(0)
    }

    /// Final teardown, from `TerminalPane.documentWillClose()` only.
    func invalidate() {
        graceTask?.cancel()
        graceTask = nil
        _ = model.snap(reason: "closed")
        onScrollLines = nil
        onOffsetChanged = nil
        isEligible = { false }
        headroom = { .pinned }
    }

    // MARK: - Internals

    private func apply(_ out: ScrollOutput) {
        if out.lines != 0 { onScrollLines?(out.lines) }
        onOffsetChanged?(CGFloat(out.offset))
        if out.startGrace { armGrace(generation: model.graceGeneration) }
        if let summary = out.finished { Self.log(summary) }
    }

    private func armGrace(generation: Int) {
        graceTask?.cancel()
        graceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: SmoothScrollModel.momentumGrace)
            guard !Task.isCancelled, let self else { return }
            self.graceTask = nil
            guard self.isEligible() else { self.snapToGrid(reason: "ineligible"); return }
            self.apply(self.model.graceExpired(generation: generation, headroom: self.headroom()))
        }
    }

    private static let diagEnabled = ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil

    /// One stderr line per finished gesture, never per event (review item 8). It separates
    /// "momentum never ran" from "momentum ran and the settle stepped the wrong way".
    private static func log(_ s: GestureSummary) {
        guard diagEnabled else { return }
        let line = "[diag] smooth-scroll: path=\(s.path) events=\(s.events) lines=\(s.lines) "
            + "momentum=\(s.momentum) settle=\(s.settleLines)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

extension ScrollPhase {
    /// `NSEvent.Phase` is an OptionSet, but a real event carries at most one phase bit.
    init(_ phase: NSEvent.Phase) {
        if phase.contains(.began) { self = .began }
        else if phase.contains(.changed) { self = .changed }
        else if phase.contains(.ended) { self = .ended }
        else if phase.contains(.cancelled) { self = .cancelled }
        else if phase.contains(.stationary) { self = .stationary }
        else if phase.contains(.mayBegin) { self = .mayBegin }
        else { self = .none }
    }
}
