//
//  SmoothScroll.swift
//  Pixel-level smooth scrolling overlay for the terminal view.
//
//  Intercepts trackpad scroll events, applies sub-cell pixel offsets via
//  CALayer transform, and fires whole-line scrolls when the accumulated
//  offset crosses a cell-height boundary. A CVDisplayLink drives momentum
//  decay after the user lifts their fingers (NSEvent.Phase.ended).
//
//  Architecture:
//  - SmoothScroll holds all mutable state and calls back via two closures.
//  - GoblinPortalTerminalView owns one instance and wires the closures.
//  - The terminal's own scrollWheel is suppressed when this class handles it,
//    so the two scroll paths (ours vs SwiftTerm's) never double-fire.
//
//  Guards enforced by the caller:
//  - Alternate buffer (vim, tmux): fall through to super.scrollWheel.
//  - Mouse reporting mode != .off: fall through to super.scrollWheel.
//  - Config.smoothScrolling == false: fall through to super.scrollWheel.
//

import AppKit
import CoreVideo

/// Pixel-level smooth scrolling state machine for the terminal view.
///
/// Call `configure(view:cellHeight:)` once after the view is set up, then
/// call `handleScrollWheel(_:)` from the view's `scrollWheel(with:)` override.
/// The two callbacks feed back into the view: `onScrollLines` triggers the real
/// buffer scroll, and `onOffsetChanged` applies the sub-cell layer transform.
@MainActor
final class SmoothScroll {

    // MARK: - Configuration

    private weak var view: NSView?
    private(set) var cellHeight: CGFloat = 0

    // MARK: - Scroll state

    /// Accumulated sub-cell pixel offset (positive = scrolled up = content moves down).
    private var pixelOffset: CGFloat = 0

    /// Velocity in pixels/frame driving the momentum animation.
    private var velocity: CGFloat = 0

    /// Phase accumulator: sub-cell pixels carried across events during active touch.
    private var phaseAccumulator: CGFloat = 0

    // MARK: - Display link

    private var displayLink: CVDisplayLink?
    private var isAnimating = false

    // MARK: - Callbacks

    /// Called when the pixel accumulator crosses N cell heights. Positive = scroll up.
    var onScrollLines: ((Int) -> Void)?

    /// Called each frame with the sub-cell pixel offset to apply as a layer transform.
    /// Positive offset = content shifted down (user scrolled up, peeking at earlier output).
    var onOffsetChanged: ((CGFloat) -> Void)?

    // MARK: - Setup

    func configure(view: NSView, cellHeight: CGFloat) {
        self.view = view
        self.cellHeight = cellHeight
    }

    // MARK: - Public interface

    /// Handle a scroll-wheel event. Returns `true` when the event is consumed by
    /// the smooth path (caller should NOT forward to super). Returns `false` when
    /// the event is not a precise trackpad event and should fall through normally.
    @discardableResult
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, cellHeight > 0 else { return false }

        stopDisplayLink()

        let dy = event.scrollingDeltaY  // positive = finger moved down = scroll up

        switch event.phase {
        case .began:
            // New gesture: reset everything.
            phaseAccumulator = 0
            velocity = 0
            pixelOffset = 0
            commitOffset()

        case .changed:
            phaseAccumulator += dy
            drainAccumulator()

        case .ended, .cancelled:
            // Fingers lifted: hand off to momentum if we have velocity.
            velocity = dy  // seed from last delta so the curve feels continuous
            if abs(velocity) > 0.5 {
                startDisplayLink()
            }

        default:
            // momentumPhase events from the system — we drive our own momentum,
            // so swallow them to avoid doubling.
            if event.momentumPhase != [] { return true }
            // Any other phase we don't recognise: let super handle it.
            return false
        }

        return true
    }

    /// Snap the sub-cell pixel offset to zero. Call on mouseDown so any in-flight
    /// inertia is cancelled before text selection begins.
    func snapToGrid() {
        stopDisplayLink()
        velocity = 0
        pixelOffset = 0
        phaseAccumulator = 0
        commitOffset()
    }

    /// Release resources. Call from the view's deinit or when the view is removed.
    func invalidate() {
        stopDisplayLink()
        onScrollLines = nil
        onOffsetChanged = nil
    }

    // MARK: - Internal: accumulator drain

    /// Consume whole-cell multiples from `phaseAccumulator`, fire `onScrollLines`,
    /// and keep the remainder as `pixelOffset`.
    private func drainAccumulator() {
        guard cellHeight > 0 else { return }
        let totalOffset = pixelOffset + phaseAccumulator
        let lines = Int(totalOffset / cellHeight)
        if lines != 0 {
            pixelOffset = totalOffset - CGFloat(lines) * cellHeight
            phaseAccumulator = 0
            onScrollLines?(lines)
        } else {
            pixelOffset = totalOffset
            phaseAccumulator = 0
        }
        commitOffset()
    }

    /// Push the current `pixelOffset` to the view's layer transform.
    private func commitOffset() {
        onOffsetChanged?(pixelOffset)
    }

    // MARK: - Internal: display link (momentum)

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        guard CVDisplayLinkCreateWithActiveCGDisplays(&displayLink) == kCVReturnSuccess,
              let dl = displayLink else {
            displayLink = nil
            return
        }
        isAnimating = true
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let ctx = context else { return kCVReturnSuccess }
            let me = Unmanaged<SmoothScroll>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                me.momentumTick()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(dl, callback,
                                       Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
    }

    private func stopDisplayLink() {
        guard let dl = displayLink else { return }
        CVDisplayLinkStop(dl)
        displayLink = nil
        isAnimating = false
    }

    /// Called once per display refresh during momentum phase.
    private func momentumTick() {
        guard isAnimating, cellHeight > 0 else {
            stopDisplayLink()
            return
        }
        // Exponential decay: ~0.92 per frame → comfortable half-life of ~8 frames.
        velocity *= 0.92
        guard abs(velocity) >= 0.5 else {
            stopDisplayLink()
            // Snap any residual sub-cell offset: round toward zero so the final
            // resting position is exactly on a cell boundary.
            if abs(pixelOffset) > 0 {
                let snapLines = Int(pixelOffset / cellHeight)
                if snapLines != 0 {
                    pixelOffset -= CGFloat(snapLines) * cellHeight
                    onScrollLines?(snapLines)
                }
                pixelOffset = 0
                commitOffset()
            }
            return
        }
        phaseAccumulator += velocity
        drainAccumulator()
    }
}
