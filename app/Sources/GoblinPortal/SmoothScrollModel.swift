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
//  OWNERSHIP (PR #135 re-review R1). AppKit latches a scroll to its first target, so a pane
//  keeps the events of a gesture it began. It does not keep a NEW gesture. A `.began` outside
//  the pane, or a finger-phase event arriving while the pane only waits for momentum, proves
//  the user started scrolling somewhere else. `shouldClaim` refuses it, and the adapter calls
//  `release`, which settles the owned gesture on the nearest line instead of dropping it.
//
//  HEADROOM (R2). SwiftTerm clamps both scroll calls: `scrollUp` to `max(yDisp - lines, 0)`
//  and `scrollDown` to `lines.count - rows` (AppleTerminalView.swift:2138-2149, via
//  `scrollTo`, :2084-2088). A model that does not know this builds a sub-cell offset into a
//  direction with no content, so at the live prompt the view slid over a blank strip and
//  snapped back on every event. Each input carries `ScrollHeadroom`, and the model clamps
//  the lines AND the offset to it. The clamp lives here so `check-smooth-scroll.sh` gates it.
//

import Foundation

/// One NSEvent phase, flattened. `NSEvent.Phase` is an AppKit OptionSet; the adapter maps
/// it onto this so the model never imports AppKit.
enum ScrollPhase: Equatable {
    case none, mayBegin, began, stationary, changed, ended, cancelled
}

/// Whole lines SwiftTerm can still scroll in each direction, read just before an event.
struct ScrollHeadroom: Equatable {
    /// Room for `scrollUp` (positive model sign). This is `yDisp`.
    var earlier: Int
    /// Room for `scrollDown` (negative model sign): `lines.count - rows - yDisp`.
    var later: Int

    /// No clamp. Large but finite, so `room - lines` arithmetic can never overflow.
    static let unbounded = ScrollHeadroom(earlier: 1 << 40, later: 1 << 40)
    static let pinned = ScrollHeadroom(earlier: 0, later: 0)

    /// Derive the headroom from SwiftTerm's PUBLIC surface. The exact inputs (`displayBuffer`,
    /// `Buffer.lines`, `Buffer.rows`) are `internal` to SwiftTerm (Terminal.swift:347,
    /// Buffer.swift:203/212), so the app cannot read `lines.count - rows` directly. But
    /// `displayBuffer` is just `buffer` (Terminal.swift:347-349), whose `yDisp` is public
    /// (Buffer.swift:58), and `scrollPosition` is `yDisp / (lines.count - rows)`, 1 at or past
    /// the bottom and 0 when `yDisp <= 0` (AppleTerminalView.swift:2027-2041). `canScroll` is
    /// false when there is no scrollback at all (:2046-2051). At the top the bottom distance is
    /// unknowable from these (position reads 0), but it is at least one line, so it stays open.
    static func derive(yDisp: Int, scrollPosition: Double, canScroll: Bool) -> ScrollHeadroom {
        let earlier = max(0, yDisp)
        guard canScroll, scrollPosition < 1 else { return ScrollHeadroom(earlier: earlier, later: 0) }
        guard yDisp > 0, scrollPosition > 0 else { return ScrollHeadroom(earlier: earlier, later: unbounded.later) }
        let maxScrollback = Int((Double(yDisp) / scrollPosition).rounded())
        return ScrollHeadroom(earlier: earlier, later: max(0, maxScrollback - yDisp))
    }
}

/// One precise scroll event, as the model sees it.
struct ScrollInput: Equatable {
    var phase: ScrollPhase
    var momentum: ScrollPhase
    var deltaY: Double
    var cellHeight: Double
    var headroom: ScrollHeadroom = .unbounded
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
    /// "interrupted" (a new touch arrived first), "released" (a new gesture began outside
    /// the pane), "phaseless", or "snap:<reason>".
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
    /// Headroom of the entry point currently running, measured before its lines are applied.
    private var room = ScrollHeadroom.unbounded

    var isMidGesture: Bool { state != .idle }

    /// Whether a view should take this event at all. A gesture START is claimed only under the
    /// pointer, even mid-gesture: the first cut latched every event while `isMidGesture`, so a
    /// swipe begun over the sidebar or the split peer during this pane's grace window or
    /// momentum was stolen (re-review R1). The rest of a gesture the pane owns stays latched
    /// even if the pointer drifts out, the way AppKit latches a scroll to its first target, so
    /// a scroll begun over the sidebar that drifts over the terminal stays the sidebar's
    /// (review item 2). Finger phases belong to a `.touching` gesture only. Once the finger
    /// has lifted, a finger phase can only come from a new gesture whose start another view
    /// took, so it is refused too. Non-mutating; when it says no, call `release`.
    func shouldClaim(_ input: ScrollInput, pointerInside: Bool) -> Bool {
        switch input.phase {
        case .began, .mayBegin: return pointerInside
        case .changed, .stationary, .ended, .cancelled: return state == .touching
        // Momentum, or a phaseless event taken only so `handle` can settle and hand it back.
        case .none: return isMidGesture
        }
    }

    /// An event this pane did NOT claim arrived. If a gesture is in flight, that event is
    /// someone else's new gesture, so this one is over: settle it on the nearest line, the
    /// same as `finish`, rather than leave a sub-cell offset stranded until the next click.
    /// Idle: a no-op. `consumed` is always false; the event belongs to whoever claims it.
    mutating func release(headroom: ScrollHeadroom = .unbounded) -> ScrollOutput {
        var out = ScrollOutput(offset: offset)
        guard isMidGesture else { return out }
        room = headroom
        finish("released", into: &out)
        out.offset = offset
        return out
    }

    mutating func handle(_ input: ScrollInput) -> ScrollOutput {
        guard input.cellHeight > 0 else { return ScrollOutput(offset: offset) }
        cellHeight = input.cellHeight
        room = input.headroom
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
    /// momentum, and do nothing if anything happened since. `headroom` is re-read at fire
    /// time, because output may have moved the buffer during the 100 ms wait.
    mutating func graceExpired(generation: Int, headroom: ScrollHeadroom = .unbounded) -> ScrollOutput {
        var out = ScrollOutput(offset: offset)
        guard state == .awaitingMomentum, generation == graceGeneration else { return out }
        room = headroom
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

    /// Room left in each direction for THIS call: its headroom minus the lines already queued
    /// in `out`, which the adapter applies only after the call returns.
    private func roomEarlier(_ out: ScrollOutput) -> Int { max(0, room.earlier - out.lines) }
    private func roomLater(_ out: ScrollOutput) -> Int { max(0, room.later + out.lines) }

    /// Add pixels and move every whole cell they contain out into `lines`. The remainder is
    /// truncated toward zero, so |offset| stays under one cell in both directions and shares
    /// the sign of `total`. Then clamp to the headroom (R2): once the lines use up the room in
    /// the direction of travel, the leftover offset would show rows that do not exist, so it
    /// is zeroed and the lines are capped. Truncation keeps `whole` and the remainder on the
    /// same side of zero, so only the direction of `total` needs a check.
    private mutating func accumulate(_ delta: Double, into out: inout ScrollOutput) {
        events += 1
        let total = offset + delta
        var whole = Int(total / cellHeight)
        var rest = total - Double(whole) * cellHeight
        if total > 0, whole >= roomEarlier(out) { whole = roomEarlier(out); rest = 0 }
        if total < 0, -whole >= roomLater(out) { whole = -roomLater(out); rest = 0 }
        offset = rest
        out.lines += whole
        gestureLines += whole
    }

    /// End the gesture on a cell boundary: round the leftover to the NEAREST line (one step
    /// when |offset| >= half a cell), then zero it. Without this, a drag with no momentum left
    /// the view shifted by up to a cell, with a gap at the clipped edge (review item 5).
    /// The step respects the headroom too: output may have used the room since the offset was
    /// built, and a step SwiftTerm would clamp away would still be counted in the summary.
    private mutating func finish(_ path: String, into out: inout ScrollOutput) {
        var step = 0
        if cellHeight > 0, abs(offset) >= cellHeight / 2 { step = offset > 0 ? 1 : -1 }
        if step > 0, roomEarlier(out) < 1 { step = 0 }
        if step < 0, roomLater(out) < 1 { step = 0 }
        out.lines += step
        gestureLines += step
        offset = 0
        state = .idle
        out.finished = GestureSummary(path: path, events: events, lines: gestureLines,
                                      momentum: momentumRan, settleLines: step)
    }
}
