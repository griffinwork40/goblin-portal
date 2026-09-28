//
//  SmoothScrollModel.swift
//  The pure state machine behind pixel-smooth trackpad scrolling. It has no AppKit.
//
//  Its own file and Foundation-only for the same reason `PasteGuardPolicy.swift` is: the
//  interesting part of smooth scrolling is a *policy*. Given a gesture phase, a momentum
//  phase, a pixel delta and a cell height, it decides how many whole lines to scroll and
//  what sub-cell offset to leave. A pure function of its inputs compiles headless with
//  `swiftc`, so `check-smooth-scroll.sh` gates the SHIPPED file rather than a copy of it.
//  `NSEvent`, the layer transform and the event monitor stay in `SmoothScroll.swift` and
//  `GoblinPortalTerminalView+SmoothScroll.swift`, which a headless gate cannot reach.
//
//  MOMENTUM IS THE OS'S, NOT OURS. After the fingers lift, macOS delivers its own inertia
//  as further scroll events with `phase == []` and `momentumPhase` = began/changed/ended.
//  Those events feed the same accumulator as the finger-down deltas. The first cut of
//  this feature ran a private CVDisplayLink decay instead, and it failed three ways (PR
//  #135 review): it never started, because `.ended` carries a near-zero delta; it
//  swallowed the OS momentum it was meant to replace; and it passed an unretained pointer
//  across threads. Feeding the OS stream gives native feel and refresh-rate independence
//  with no timer thread at all.
//
//  SIGN CONVENTION, one for every quantity in this file. Positive = the direction
//  `scrollUp(lines:)` moves content. That is toward EARLIER output, and on screen the
//  content moves DOWN (`scrollUp` lowers `yDisp`, AppleTerminalView.swift:2138-2142).
//  AppKit's `scrollingDeltaY` is positive for the same gesture, which is why SwiftTerm's
//  own `scrollWheel` maps `lines > 0` to `scrollUp` (Mac/MacTerminalView.swift:2779-2811).
//  So `lines` and `offset` share the sign of the deltas that produced them, and
//  `layerTranslationY` below is the ONE place that turns this into a screen direction.
//

import Foundation

/// One NSEvent phase, flattened. `NSEvent.Phase` is an AppKit OptionSet; the adapter maps
/// it onto this so the model never imports AppKit.
enum ScrollPhase: Equatable {
    case none, mayBegin, began, stationary, changed, ended, cancelled
}

/// One precise scroll event, as the model sees it.
struct ScrollInput: Equatable {
    var phase: ScrollPhase
    var momentum: ScrollPhase
    var deltaY: Double
    var cellHeight: Double
}

/// What the view should do after one input.
struct ScrollOutput: Equatable {
    /// True when the smooth path owns this event and SwiftTerm must not see it.
    var consumed = false
    /// Whole lines to scroll now. Positive = `scrollUp(lines:)`, negative = `scrollDown`.
    var lines = 0
    /// Sub-cell offset to show after `lines` has been applied. |offset| < cellHeight.
    var offset: Double = 0
    /// The finger lifted, and the adapter should arm the momentum grace timer for
    /// `SmoothScrollModel.graceGeneration`.
    var startGrace = false
    /// Set exactly once per gesture, when it finishes. Used for the diagnostic line.
    var finished: GestureSummary?
}

/// Per-gesture record for the `GOBLIN_PORTAL_DIAG` line. One per gesture, never one per event.
struct GestureSummary: Equatable {
    /// How the gesture ended: "touch" (lift with no momentum), "momentum", "cancelled",
    /// "interrupted" (a new touch arrived first), or "snap:<reason>".
    var path: String
    var events: Int
    /// Net lines scrolled, including `settleLines`.
    var lines: Int
    var momentum: Bool
    /// -1, 0 or +1: the round-to-nearest-line step taken when the gesture finished.
    var settleLines: Int
}

struct SmoothScrollModel {
    enum State: Equatable { case idle, touching, awaitingMomentum, momentum }

    /// How long after a finger lift to wait for momentum before settling. The OS sends
    /// `momentumPhase == .began` straight after `.ended` when a flick has velocity, within a
    /// frame or two. 100 ms is well past that, and short enough that a slow drag's final
    /// snap reads as the end of the drag rather than as a separate jump.
    static let momentumGrace: Duration = .milliseconds(100)

    private(set) var state: State = .idle
    private(set) var offset: Double = 0
    /// Bumped on every finger lift. A grace timer only acts if the generation it captured
    /// is still current, so a stale timer from an earlier gesture can never settle a later one.
    private(set) var graceGeneration = 0
    private var cellHeight: Double = 0
    private var events = 0
    private var gestureLines = 0
    private var momentumRan = false

    var isMidGesture: Bool { state != .idle }

    /// Whether a view should take this event at all. An idle view claims only the START of a
    /// gesture, and only under the pointer. A view that owns a gesture keeps it until it
    /// finishes, the way AppKit latches a scroll to its first target. So a scroll that begins
    /// over the sidebar and drifts over the terminal stays the sidebar's (PR #135 review, item 2).
    func shouldClaim(_ input: ScrollInput, pointerInside: Bool) -> Bool {
        if isMidGesture { return true }
        return pointerInside && (input.phase == .began || input.phase == .mayBegin)
    }

    mutating func handle(_ input: ScrollInput) -> ScrollOutput {
        guard input.cellHeight > 0 else { return ScrollOutput(offset: offset) }
        cellHeight = input.cellHeight
        var out = ScrollOutput(consumed: true)
        if input.phase != .none {
            switch input.phase {
            case .mayBegin, .began:
                // A touch while a previous gesture is still settling (fingers down during
                // momentum, or inside the grace window). Settle that gesture first, so its
                // half-line rounding is not lost, then start clean. `.mayBegin` followed by
                // `.began` is ONE gesture, so an untouched `.touching` state carries over.
                let untouched = state == .touching && gestureLines == 0 && offset == 0
                if isMidGesture && !untouched { finish("interrupted", into: &out) }
                if state == .idle { start() }
                accumulate(input.deltaY, into: &out)
            case .changed, .stationary:
                if state == .idle { start() }
                state = .touching
                accumulate(input.deltaY, into: &out)
            case .ended:
                accumulate(input.deltaY, into: &out)
                state = .awaitingMomentum
                graceGeneration &+= 1
                out.startGrace = true
            case .cancelled:
                accumulate(input.deltaY, into: &out)
                finish("cancelled", into: &out)
            case .none:
                break
            }
        } else if input.momentum != .none {
            switch input.momentum {
            case .ended, .cancelled:
                accumulate(input.deltaY, into: &out)
                finish("momentum", into: &out)
            default:
                if state == .idle { start() }
                state = .momentum
                momentumRan = true
                accumulate(input.deltaY, into: &out)
            }
        } else {
            // A precise event with no phase at all is not a gesture this model understands.
            // Settle anything in flight and hand the event back to SwiftTerm.
            if isMidGesture { finish("phaseless", into: &out) }
            out.consumed = false
        }
        out.offset = offset
        return out
    }

    /// The grace timer fired. Settle if the finger lift it was armed for was not followed by
    /// momentum, and do nothing if anything happened since.
    mutating func graceExpired(generation: Int) -> ScrollOutput {
        var out = ScrollOutput(offset: offset)
        guard state == .awaitingMomentum, generation == graceGeneration else { return out }
        finish("touch", into: &out)
        out.offset = offset
        return out
    }

    /// Drop to the grid at once, with no line step. Used for mouseDown, leaving the window,
    /// typing, and the smooth path turning ineligible (alt buffer, mouse reporting).
    mutating func snap(reason: String) -> ScrollOutput {
        var out = ScrollOutput()
        guard isMidGesture || offset != 0 else { return out }
        out.finished = GestureSummary(path: "snap:" + reason, events: events, lines: gestureLines,
                                      momentum: momentumRan, settleLines: 0)
        offset = 0
        state = .idle
        return out
    }

    /// Turn a model offset into the layer's y translation. The transform is expressed in the
    /// superlayer's space, which AppKit orients like the superview. An unflipped superview has
    /// +y pointing UP the screen, so content that must move DOWN (positive offset, see the
    /// header) needs a NEGATIVE translation there. A flipped superview needs a positive one.
    /// Measured once, not assumed: an offscreen `CALayer.render` probe made during the PR #135
    /// fix moved a child layer UP under a +10 y translation in an unflipped superlayer
    /// (`geometryFlipped == false`), and DOWN in a flipped one. `check-smooth-scroll.sh` pins
    /// this mapping arithmetically. It does NOT render a layer, so the direction under the
    /// Metal renderer is daily-drive territory.
    static func layerTranslationY(offset: Double, superviewFlipped: Bool) -> Double {
        superviewFlipped ? offset : -offset
    }

    // MARK: - Internals

    private mutating func start() {
        state = .touching
        offset = 0
        events = 0
        gestureLines = 0
        momentumRan = false
    }

    /// Add pixels and move every whole cell they contain out into `lines`. The remainder is
    /// truncated toward zero, so |offset| stays under one cell in both directions.
    private mutating func accumulate(_ delta: Double, into out: inout ScrollOutput) {
        events += 1
        let total = offset + delta
        let whole = Int(total / cellHeight)
        offset = total - Double(whole) * cellHeight
        out.lines += whole
        gestureLines += whole
    }

    /// End the gesture on a cell boundary: round the leftover to the NEAREST line (one step
    /// when |offset| >= half a cell), then zero it. Without this, a drag with no momentum left
    /// the view shifted by up to a cell, with a gap at the clipped edge (review item 5).
    private mutating func finish(_ path: String, into out: inout ScrollOutput) {
        var step = 0
        if cellHeight > 0, abs(offset) >= cellHeight / 2 { step = offset > 0 ? 1 : -1 }
        out.lines += step
        gestureLines += step
        offset = 0
        state = .idle
        out.finished = GestureSummary(path: path, events: events, lines: gestureLines,
                                      momentum: momentumRan, settleLines: step)
    }
}
