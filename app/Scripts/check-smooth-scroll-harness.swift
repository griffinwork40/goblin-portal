// check-smooth-scroll-harness.swift
// Truth table for SmoothScrollModel — compiled by check-smooth-scroll.sh.
//
// WHAT IS UNDER TEST. Sources/GoblinPortal/SmoothScrollModel.swift only —
// the pure state machine (Foundation only, zero AppKit). Same trick as
// check-paste-guard.sh on PasteGuardPolicy.swift.
//
// WHAT IT CANNOT REACH, stated explicitly:
//   • NSEvent routing in SmoothScroll.swift / GoblinPortalTerminalView+SmoothScroll.swift
//     — those import AppKit and cannot compile headless.
//   • The real CALayer transform: layerTranslationY is tested arithmetically here,
//     but whether the rendered frame visually moves correctly requires a live compositor.
//   • Native momentum feel: whether the OS momentumPhase stream feels right is daily-drive.
//   • Grace timer wall-clock accuracy: graceExpired is called synchronously here.
//   • The reattach/reuse lifecycle of SmoothScroll — that involves AppKit view hierarchy.

import Foundation

// MARK: - Helpers

var bad = 0

func ok(_ label: String) { print("  ok  \(label)") }
func fail(_ label: String, _ detail: String) { print("  FAIL \(label): \(detail)"); bad += 1 }
func expect<T: Equatable>(_ l: String, got: T, want: T) { if got != want { fail(l, "got \(got), expected \(want)") } }

func ev(_ phase: ScrollPhase, dy: Double, cell: Double = 20.0) -> ScrollInput {
    ScrollInput(phase: phase, momentum: .none, deltaY: dy, cellHeight: cell)
}
func mom(_ mp: ScrollPhase, dy: Double, cell: Double = 20.0) -> ScrollInput {
    ScrollInput(phase: .none, momentum: mp, deltaY: dy, cellHeight: cell)
}

// MARK: - Case 1: Realistic flick — carry forward past finger-lift, offset 0 at end

func case1_realisticFlick() {
    var m = SmoothScrollModel()
    var _ = m.handle(ev(.began, dy: 0))
    var totalLines = 0
    for _ in 0..<8 { totalLines += m.handle(ev(.changed, dy: 2.5)).lines }
    let endOut = m.handle(ev(.ended, dy: 0))
    totalLines += endOut.lines
    expect("case1: startGrace on .ended", got: endOut.startGrace, want: true)
    expect("case1: awaitingMomentum after .ended", got: m.state, want: .awaitingMomentum)
    totalLines += m.handle(mom(.began, dy: 5)).lines
    expect("case1: state enters momentum", got: m.state, want: .momentum)
    for _ in 0..<2 { totalLines += m.handle(mom(.changed, dy: 5)).lines }
    let meOut = m.handle(mom(.ended, dy: 0))
    totalLines += meOut.lines
    expect("case1: offset 0 after momentum ended", got: m.offset, want: 0.0)
    expect("case1: idle after momentum ended", got: m.state, want: .idle)
    guard let s = meOut.finished else { fail("case1", "no GestureSummary on momentum ended"); return }
    expect("case1: path is momentum", got: s.path, want: "momentum")
    expect("case1: momentum flag set", got: s.momentum, want: true)
    expect("case1: totalLines > 0 (momentum carried forward)", got: totalLines > 0, want: true)
    ok("case1: realistic flick carries past finger-lift and finishes at offset 0")
}

// MARK: - Case 2: Slow drag, .ended, grace expiry, offset 0

func case2_slowDragGraceExpiry() {
    var m = SmoothScrollModel()
    var _ = m.handle(ev(.began, dy: 0))
    var totalLines = 0
    for _ in 0..<3 { totalLines += m.handle(ev(.changed, dy: 3.0)).lines }
    let endOut = m.handle(ev(.ended, dy: 0))
    totalLines += endOut.lines
    let gen = m.graceGeneration
    expect("case2: startGrace set", got: endOut.startGrace, want: true)
    expect("case2: awaitingMomentum after .ended", got: m.state, want: .awaitingMomentum)
    let graceOut = m.graceExpired(generation: gen)
    totalLines += graceOut.lines
    expect("case2: offset 0 after grace", got: m.offset, want: 0.0)
    expect("case2: idle after grace", got: m.state, want: .idle)
    guard let s = graceOut.finished else { fail("case2", "no GestureSummary on grace"); return }
    expect("case2: path is touch", got: s.path, want: "touch")
    expect("case2: momentum did not run", got: s.momentum, want: false)
    ok("case2: slow drag + grace expiry settles to offset 0")
}

// MARK: - Case 3: Line conservation

func case3_lineConservation() {
    let cellH = 20.0
    var m = SmoothScrollModel()
    var _ = m.handle(ev(.began, dy: 0))
    var emitted = 0
    for _ in 0..<5 { emitted += m.handle(ev(.changed, dy: cellH)).lines }
    var _ = m.handle(ev(.ended, dy: 0))
    let g = m.graceGeneration
    emitted += m.graceExpired(generation: g).lines
    expect("case3: 5 full cells → 5 lines", got: emitted, want: 5)

    // 30px / 20px cell: Int(30/20)=1 in flight; 10px leftover ≥ 10 (half of 20) → +1 settle = 2
    var m2 = SmoothScrollModel()
    var _ = m2.handle(ev(.began, dy: 0))
    var em2 = m2.handle(ev(.changed, dy: 30.0)).lines
    var _ = m2.handle(ev(.ended, dy: 0))
    let g2 = m2.graceGeneration
    em2 += m2.graceExpired(generation: g2).lines
    expect("case3: 30px / 20px cell → 2 lines (1 + settle)", got: em2, want: 2)
    ok("case3: line conservation holds — whole pixels / cellHeight + nearest settle")
}

// MARK: - Case 4: Sign convention

func case4_signConvention() {
    var m = SmoothScrollModel()
    var _ = m.handle(ev(.began, dy: 0))
    expect("case4: positive deltaY → positive lines", got: m.handle(ev(.changed, dy: 40.0)).lines, want: 2)
    var m2 = SmoothScrollModel()
    var _ = m2.handle(ev(.began, dy: 0))
    expect("case4: negative deltaY → negative lines", got: m2.handle(ev(.changed, dy: -40.0)).lines, want: -2)
    let pos = 10.0
    expect("case4: unflipped → -offset", got: SmoothScrollModel.layerTranslationY(offset: pos, superviewFlipped: false), want: -pos)
    expect("case4: flipped → +offset", got: SmoothScrollModel.layerTranslationY(offset: pos, superviewFlipped: true), want: pos)
    ok("case4: positive deltaY = scrollUp; layerTranslationY is -offset (unflipped), +offset (flipped)")
}

// MARK: - Case 5: .began resets a stale offset

func case5_beganResetsOffset() {
    var m = SmoothScrollModel()
    var _ = m.handle(ev(.began, dy: 0))
    var _ = m.handle(ev(.changed, dy: 5.0))
    var _ = m.handle(ev(.began, dy: 0)) // interrupt
    expect("case5: offset zeroed on new .began", got: m.offset, want: 0.0)
    expect("case5: touching after new .began", got: m.state, want: .touching)
    ok("case5: .began resets a stale offset")
}

// MARK: - Case 6: .cancelled settles

func case6_cancelledSettles() {
    var m = SmoothScrollModel()
    var _ = m.handle(ev(.began, dy: 0))
    var _ = m.handle(ev(.changed, dy: 7.0))
    let out = m.handle(ev(.cancelled, dy: 0))
    expect("case6: offset 0 after cancelled", got: m.offset, want: 0.0)
    expect("case6: idle after cancelled", got: m.state, want: .idle)
    guard let s = out.finished else { fail("case6", "no GestureSummary on cancelled"); return }
    expect("case6: path is cancelled", got: s.path, want: "cancelled")
    ok("case6: .cancelled settles gesture")
}

// MARK: - Case 7: Stale grace generation is ignored

func case7_staleGraceIgnored() {
    var m = SmoothScrollModel()
    var _ = m.handle(ev(.began, dy: 0))
    var _ = m.handle(ev(.changed, dy: 5.0))
    var _ = m.handle(ev(.ended, dy: 0))
    let staleGen = m.graceGeneration
    var _ = m.handle(ev(.began, dy: 0))
    var _ = m.handle(ev(.changed, dy: 3.0))
    var _ = m.handle(ev(.ended, dy: 0))
    expect("case7: two .ended events bump generation twice", got: m.graceGeneration, want: staleGen + 1)
    let graceOut = m.graceExpired(generation: staleGen)
    expect("case7: stale grace leaves state awaitingMomentum", got: m.state, want: .awaitingMomentum)
    expect("case7: stale grace emits no lines", got: graceOut.lines, want: 0)
    expect("case7: stale grace has no finished summary", got: graceOut.finished, want: nil)
    ok("case7: stale grace generation is ignored")
}

// MARK: - Case 8: snap(reason:) zeroes offset without emitting lines

func case8_snapZeroesOffset() {
    var m = SmoothScrollModel()
    var _ = m.handle(ev(.began, dy: 0))
    var _ = m.handle(ev(.changed, dy: 9.5))
    expect("case8: pre-snap offset non-zero", got: m.offset, want: 9.5)
    let snapOut = m.snap(reason: "test")
    expect("case8: snap emits 0 lines", got: snapOut.lines, want: 0)
    expect("case8: offset 0 after snap", got: m.offset, want: 0.0)
    expect("case8: idle after snap", got: m.state, want: .idle)
    guard let s = snapOut.finished else { fail("case8", "no GestureSummary on snap"); return }
    expect("case8: path starts with snap:", got: s.path.hasPrefix("snap:"), want: true)
    ok("case8: snap(reason:) zeroes offset without emitting lines")
}

// MARK: - Case 9: shouldClaim

func case9_shouldClaim() {
    var m = SmoothScrollModel()
    let beg = ev(.began, dy: 0)
    expect("case9: idle+outside → refused", got: m.shouldClaim(beg, pointerInside: false), want: false)
    expect("case9: idle+inside → claimed", got: m.shouldClaim(beg, pointerInside: true), want: true)
    var _ = m.handle(ev(.began, dy: 0))
    var _ = m.handle(ev(.changed, dy: 5.0))
    expect("case9: mid-gesture+outside → still claimed",
           got: m.shouldClaim(ev(.changed, dy: 2.0), pointerInside: false), want: true)
    // The latch is for the OWNED gesture only: a new start outside is refused even mid-gesture.
    expect("case9: mid-gesture, new .began outside → refused",
           got: m.shouldClaim(ev(.began, dy: 0), pointerInside: false), want: false)
    ok("case9: shouldClaim refuses new gesture outside pointer; keeps owned gesture")
}

// MARK: - Case 10: FALSIFICATION — naive model without momentum loses carry-forward

func case10_falsification() {
    // Shipped model: full flick with momentum.
    var shipped = SmoothScrollModel()
    var _ = shipped.handle(ev(.began, dy: 0))
    var shippedLines = 0
    for _ in 0..<8 { shippedLines += shipped.handle(ev(.changed, dy: 2.5)).lines }
    var _ = shipped.handle(ev(.ended, dy: 0))
    for _ in 0..<3 { shippedLines += shipped.handle(mom(.changed, dy: 5.0)).lines }
    shippedLines += shipped.handle(mom(.ended, dy: 0)).lines

    // Naive model: identical drag, then settle via grace before any momentum arrives.
    var naive = SmoothScrollModel()
    var _ = naive.handle(ev(.began, dy: 0))
    var naiveLines = 0
    for _ in 0..<8 { naiveLines += naive.handle(ev(.changed, dy: 2.5)).lines }
    var _ = naive.handle(ev(.ended, dy: 0))
    let naiveGen = naive.graceGeneration
    naiveLines += naive.graceExpired(generation: naiveGen).lines
    // Naive never receives momentum events.

    if shippedLines > naiveLines {
        ok("case10: FALSIFICATION — shipped \(shippedLines) lines > naive \(naiveLines) lines; momentum carry-forward is real")
    } else {
        let msg = "shipped=\(shippedLines) should exceed naive=\(naiveLines); the harness is measuring nothing"
        fail("case10: FALSIFICATION pin broken", msg)
    }
}

// MARK: - Entry point (called from main.swift)

func runAllCases() {
    case1_realisticFlick()
    case2_slowDragGraceExpiry()
    case3_lineConservation()
    case4_signConvention()
    case5_beganResetsOffset()
    case6_cancelledSettles()
    case7_staleGraceIgnored()
    case8_snapZeroesOffset()
    case9_shouldClaim()
    case10_falsification()
    runBoundsCases()  // cases 11-15, check-smooth-scroll-harness-bounds.swift

    if bad == 0 {
        print("\nall smooth-scroll cases passed (15 cases)")
    } else {
        print("\n\(bad) smooth-scroll case(s) FAILED")
    }
    exit(bad == 0 ? 0 : 1)
}
