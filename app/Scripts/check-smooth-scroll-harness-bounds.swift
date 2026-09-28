// check-smooth-scroll-harness-bounds.swift
// Truth-table cases 11-15 for SmoothScrollModel: gesture ownership (re-review R1), the
// scrollback headroom clamp (R2) and the gaps the re-review found in cases 1-10 (R6).
// Compiled by check-smooth-scroll.sh next to check-smooth-scroll-harness.swift, whose
// helpers (`ev`, `mom`, `expect`, `ok`, `fail`) it uses. It lives in its own file only to
// keep both under the 350-LOC ceiling. Like its sibling, it has no top-level code;
// `runAllCases()` in the sibling calls `runBoundsCases()` below.
//
// WHY THESE CASES. At 5fe23d01, the gate passed 10/10 while the model (a) claimed a new
// `.began` over the sidebar during this pane's grace window and logged it "interrupted",
// and (b) built a -15 px offset at the live prompt, where SwiftTerm's `scrollDown` clamps
// to `lines.count - rows` (AppleTerminalView.swift:2145-2149), so the view slid over a
// blank strip and snapped back on every event. Each case below fails on one of those
// shipped behaviours; see the falsification notes in check-smooth-scroll.sh.

import Foundation

func at(_ input: ScrollInput, _ room: ScrollHeadroom) -> ScrollInput {
    var i = input; i.headroom = room; return i
}

// MARK: - Case 11: a new gesture outside the pane is not claimed; release settles ours

func case11_newGestureOutsideReleases() {
    // Grace window: finger lifted with 12 px (> half a 20 px cell) in flight.
    var m = SmoothScrollModel()
    _ = m.handle(ev(.began, dy: 0))
    _ = m.handle(ev(.changed, dy: 12))
    _ = m.handle(ev(.ended, dy: 0))
    expect("case11: .began outside during grace → refused",
           got: m.shouldClaim(ev(.began, dy: 0), pointerInside: false), want: false)
    expect("case11: .mayBegin outside during grace → refused",
           got: m.shouldClaim(ev(.mayBegin, dy: 0), pointerInside: false), want: false)
    let rel = m.release()
    expect("case11: release settles to the nearest line (+1)", got: rel.lines, want: 1)
    expect("case11: release is not a consume", got: rel.consumed, want: false)
    expect("case11: offset 0 after release", got: m.offset, want: 0.0)
    expect("case11: idle after release", got: m.state, want: .idle)
    expect("case11: summary path is released", got: rel.finished?.path, want: "released")
    expect("case11: the new gesture's .changed outside → refused",
           got: m.shouldClaim(ev(.changed, dy: 4), pointerInside: false), want: false)

    // OS momentum: a new swipe elsewhere must not be stolen either.
    var mo = SmoothScrollModel()
    _ = mo.handle(ev(.began, dy: 0))
    _ = mo.handle(ev(.changed, dy: 5))
    _ = mo.handle(ev(.ended, dy: 0))
    _ = mo.handle(mom(.began, dy: 3))
    expect("case11: .began outside during momentum → refused",
           got: mo.shouldClaim(ev(.began, dy: 0), pointerInside: false), want: false)
    expect("case11: a finger phase after the lift is a new gesture → refused",
           got: mo.shouldClaim(ev(.changed, dy: 2), pointerInside: false), want: false)
    expect("case11: own momentum still latched with pointer outside",
           got: mo.shouldClaim(mom(.changed, dy: 2), pointerInside: false), want: true)
    expect("case11: .began INSIDE during momentum → claimed (interrupt)",
           got: mo.shouldClaim(ev(.began, dy: 0), pointerInside: true), want: true)
    var idle = SmoothScrollModel()
    expect("case11: release while idle is a no-op", got: idle.release().finished, want: nil)
    ok("case11: new gesture outside the pane is refused; release settles the owned gesture")
}

// MARK: - Case 12: a phaseless precise event is handed back

func case12_phaselessNotConsumed() {
    var idle = SmoothScrollModel()
    expect("case12: phaseless while idle → not claimed",
           got: idle.shouldClaim(ev(.none, dy: 3), pointerInside: true), want: false)
    expect("case12: phaseless handle → consumed false", got: idle.handle(ev(.none, dy: 3)).consumed, want: false)
    var m = SmoothScrollModel()
    _ = m.handle(ev(.began, dy: 0))
    _ = m.handle(ev(.changed, dy: 15))
    let out = m.handle(ev(.none, dy: 3))
    expect("case12: phaseless mid-gesture → consumed false", got: out.consumed, want: false)
    expect("case12: phaseless mid-gesture settles (+1)", got: out.lines, want: 1)
    expect("case12: phaseless summary path", got: out.finished?.path, want: "phaseless")
    ok("case12: a phaseless precise event returns consumed == false")
}

// MARK: - Case 13: a negative-direction settle rounds to -1

func case13_negativeSettle() {
    var m = SmoothScrollModel()
    _ = m.handle(ev(.began, dy: 0))
    let ch = m.handle(ev(.changed, dy: -12))
    expect("case13: -12 px → 0 lines in flight", got: ch.lines, want: 0)
    expect("case13: -12 px → offset -12", got: m.offset, want: -12.0)
    _ = m.handle(ev(.ended, dy: 0))
    let g = m.graceExpired(generation: m.graceGeneration)
    expect("case13: settle rounds to -1", got: g.lines, want: -1)
    expect("case13: summary settle -1", got: g.finished?.settleLines, want: -1)
    var small = SmoothScrollModel()
    _ = small.handle(ev(.began, dy: 0))
    _ = small.handle(ev(.changed, dy: -9))
    _ = small.handle(ev(.ended, dy: 0))
    expect("case13: -9 px (< half) settles to 0",
           got: small.graceExpired(generation: small.graceGeneration).lines, want: 0)
    ok("case13: a negative-direction settle rounds to -1")
}

// MARK: - Case 14: the headroom clamp at the ends of scrollback

func case14_headroomClamp() {
    let bottom = ScrollHeadroom(earlier: 40, later: 0)   // the live prompt
    let top = ScrollHeadroom(earlier: 0, later: 40)      // oldest scrollback line
    let mid = ScrollHeadroom(earlier: 10, later: 10)

    var b = SmoothScrollModel()
    _ = b.handle(at(ev(.began, dy: 0), bottom))
    for i in 0..<3 {
        let o = b.handle(at(ev(.changed, dy: -15), bottom))
        expect("case14: bottom, toward newer #\(i) → 0 lines", got: o.lines, want: 0)
        expect("case14: bottom, toward newer #\(i) → offset 0", got: o.offset, want: 0.0)
    }
    expect("case14: bottom, toward earlier still moves", got: b.handle(at(ev(.changed, dy: 25), bottom)).lines, want: 1)
    expect("case14: bottom, toward earlier keeps its offset", got: b.offset, want: 5.0)

    var t = SmoothScrollModel()
    _ = t.handle(at(ev(.began, dy: 0), top))
    let tOut = t.handle(at(ev(.changed, dy: 15), top))
    expect("case14: top, toward earlier → 0 lines", got: tOut.lines, want: 0)
    expect("case14: top, toward earlier → offset 0", got: tOut.offset, want: 0.0)

    var mm = SmoothScrollModel()
    _ = mm.handle(at(ev(.began, dy: 0), mid))
    expect("case14: mid, -15 → 0 lines", got: mm.handle(at(ev(.changed, dy: -15), mid)).lines, want: 0)
    expect("case14: mid, -15 → offset -15 (normal)", got: mm.offset, want: -15.0)
    expect("case14: mid, -30 more → -2 lines", got: mm.handle(at(ev(.changed, dy: -30), mid)).lines, want: -2)
    expect("case14: mid, offset -5 carried", got: mm.offset, want: -5.0)

    // Partial room: 2 lines left, a 50 px (2.5 cell) event lands exactly on the last line.
    var p = SmoothScrollModel()
    _ = p.handle(at(ev(.began, dy: 0), ScrollHeadroom(earlier: 2, later: 5)))
    expect("case14: 2 lines of room, +50 px → 2 lines",
           got: p.handle(at(ev(.changed, dy: 50), ScrollHeadroom(earlier: 2, later: 5))).lines, want: 2)
    expect("case14: 2 lines of room, +50 px → offset 0", got: p.offset, want: 0.0)

    // The settle step respects the room read at settle time.
    var s = SmoothScrollModel()
    _ = s.handle(ev(.began, dy: 0))
    _ = s.handle(ev(.changed, dy: 12))
    _ = s.handle(ev(.ended, dy: 0))
    let sOut = s.graceExpired(generation: s.graceGeneration, headroom: .pinned)
    expect("case14: settle with no room → 0 lines", got: sOut.lines, want: 0)
    expect("case14: settle with no room → offset 0", got: s.offset, want: 0.0)

    // derive(): the adapter's mapping from SwiftTerm's public yDisp/scrollPosition/canScroll.
    expect("case14: derive, no scrollback", got: ScrollHeadroom.derive(yDisp: 0, scrollPosition: 0, canScroll: false),
           want: ScrollHeadroom.pinned)
    expect("case14: derive, bottom", got: ScrollHeadroom.derive(yDisp: 100, scrollPosition: 1, canScroll: true),
           want: ScrollHeadroom(earlier: 100, later: 0))
    expect("case14: derive, middle", got: ScrollHeadroom.derive(yDisp: 50, scrollPosition: 0.5, canScroll: true),
           want: ScrollHeadroom(earlier: 50, later: 50))
    expect("case14: derive, top", got: ScrollHeadroom.derive(yDisp: 0, scrollPosition: 0, canScroll: true),
           want: ScrollHeadroom(earlier: 0, later: ScrollHeadroom.unbounded.later))
    ok("case14: no newer-ward offset at the bottom, no earlier-ward at the top, normal mid-scrollback")
}

// MARK: - Case 15: momentum into the bottom edge stops cleanly

func case15_momentumIntoEdge() {
    // A flick toward newer output with 1 line of room: the first momentum event uses it,
    // the rest must not rebuild an offset (the sawtooth the re-review measured).
    var m = SmoothScrollModel()
    var room = ScrollHeadroom(earlier: 30, later: 1)
    _ = m.handle(at(ev(.began, dy: 0), room))
    _ = m.handle(at(ev(.changed, dy: -8), room))
    _ = m.handle(at(ev(.ended, dy: 0), room))
    var lines = m.handle(at(mom(.began, dy: -20), room)).lines
    room = ScrollHeadroom(earlier: 31, later: 0)  // SwiftTerm applied it: now at the bottom
    for i in 0..<3 {
        let o = m.handle(at(mom(.changed, dy: -20), room))
        lines += o.lines
        expect("case15: momentum at the edge #\(i) → offset 0", got: o.offset, want: 0.0)
    }
    let end = m.handle(at(mom(.ended, dy: 0), room))
    lines += end.lines
    expect("case15: total lines == the one line of room", got: lines, want: -1)
    expect("case15: no settle past the edge", got: end.finished?.settleLines, want: 0)
    ok("case15: momentum into the bottom edge stops cleanly with no offset")
}

func runBoundsCases() {
    case11_newGestureOutsideReleases()
    case12_phaselessNotConsumed()
    case13_negativeSettle()
    case14_headroomClamp()
    case15_momentumIntoEdge()
}
