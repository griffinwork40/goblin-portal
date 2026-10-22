//
//  check-click-focus-harness.swift
//  Compiled by check-click-focus.sh: does CLICKING a split pane move the focus cue?
//
//  WHY THIS FILE EXISTS
//
//  The reported bug: after ⌘⇧\ or ⌘⇧-, clicking the other pane appeared to do nothing,
//  while ⌘⇧H/J/K/L worked. The click callback lived in SplitContainerView.mouseDown,
//  which a terminal click never reaches: SwiftTerm's MacTerminalView.mouseDown
//  (vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift:2496) handles the
//  event and never calls super. The fix (SpaceViewController+FirstResponderObserver.swift)
//  observes NSWindow.firstResponder instead.
//
//  This harness drives the REAL path: a real Space, a real ⌘⇧\ split (splitHorizontal),
//  and a synthesized left click dispatched like AppKit's: hit-test, then mouseDown on the
//  view hit. Calling makeFirstResponder directly would skip exactly the step that was
//  broken — nothing made a clicked terminal first responder (see click() for why
//  NSWindow.sendEvent is not used).
//
//  CASES (each split in two so a failure names WHICH half broke)
//
//    C0     SETUP      after the split the peer is focused and carries the border (exit 2
//                      if not: the harness could not build the scene it is about to test)
//    C1-FR  CLICK      clicking the primary makes the primary's terminal first responder
//    C1-CUE CLICK      ... and the focus border moves to the primary and off the peer
//    C2-FR  CLICK-BACK clicking the peer makes the peer's terminal first responder
//    C2-CUE CLICK-BACK ... and the border moves back
//    C3-FR  SUB-SPLIT  clicking the sub-peer (peerSubSplit) makes it first responder
//    C3-CUE SUB-SPLIT  ... and the focus border moves to the sub-peer
//                      (exercises the leaves.count > 2 per-leaf path in
//                      SpaceViewController+SplitPresentation.swift:64-79)
//    C4-CUE SIDEBAR    focus to file tree outline leaves the last-focused pane lit (#269)
//    C4-FR  SIDEBAR    file tree outline is actually first responder (control)
//    C5-CUE FINDBAR    focus to in-pane text field (find bar stand-in) keeps that pane lit
//
//  The FR halves are what makes the CUE halves worth believing: the falsification mutant
//  (observer never subscribed) must keep C1-FR green and fail C1-CUE. If C1-FR failed too,
//  the gate would be measuring the click synthesis, not the fix.
//
//  EXIT: 0 all passed · 1 a case failed · 2 environmental / setup failed.
//

import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String)   { print("  ok   \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

/// Pump the main run loop for up to `seconds`, returning early once `done()` holds.
@MainActor
func pump(_ seconds: Double, until done: @MainActor () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if done() { return }
    }
}

@MainActor
func hasBorder(_ view: NSView) -> Bool {
    view.layer?.sublayers?.contains { $0.name == TerminalClipView.focusBorderLayerName } ?? false
}

/// Deliver a left click at the centre of `target` the way AppKit dispatches one: hit-test
/// the window's content view at the click point, then send mouseDown/mouseUp to WHATEVER
/// view the hit-test returns (not to `target` — a click that lands on the wrong view must
/// fail). NSWindow.sendEvent is not used: in this never-key, never-activated offscreen
/// window it was measured to deliver nothing to the view (first responder unchanged, and
/// a direct mouseDown on the same view moved it), so it would test window activation
/// rather than the pane. The key-window gating it skips is AppKit's, not ours.
@MainActor
func click(_ target: NSView, in win: NSWindow) {
    guard let content = win.contentView else { print("error: no content view"); exit(2) }
    let p = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
    guard let hit = content.hitTest(content.convert(p, from: nil)) else {
        print("error: hit-test at the click point returned nil"); exit(2)
    }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let e = NSEvent.mouseEvent(
            with: type, location: p, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: win.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        else { print("error: could not synthesize \(type)"); exit(2) }
        if type == .leftMouseDown { hit.mouseDown(with: e) } else { hit.mouseUp(with: e) }
    }
}

@MainActor
func isFirstResponder(_ v: NSView, in win: NSWindow) -> Bool {
    guard let fr = win.firstResponder as? NSView else { return false }
    return fr === v || fr.isDescendant(of: v)
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
    let svc = SpaceViewController(config: AppConfig.defaults(), root: root)
    let win = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)
    win.contentViewController = svc
    win.makeKeyAndOrderFront(nil)
    pump(0.3)

    guard let primary = svc.addTerminalDocument() as? TerminalPane else {
        print("error: addTerminalDocument did not return a TerminalPane — setup failed"); exit(2)
    }
    pump(0.2)
    svc.splitHorizontal(nil as Any?)
    pump(0.4)
    guard let peer = svc.splitPeers[ObjectIdentifier(primary)]?.document as? TerminalPane else {
        print("error: ⌘⇧\\ split was not created — setup failed"); exit(2)
    }
    // A split does not move focus (makeOuterSplit, SpaceViewController+Splits.swift:46-66),
    // so establish "peer focused" the way ⌘⇧L does — focus, then an EXPLICIT dimming pass —
    // so the starting state is valid for the shipped code and the mutant alike.
    win.makeFirstResponder(peer.view)
    svc.updateSplitDimming(for: primary)
    pump(0.4, until: { hasBorder(peer.clipView) })

    // C0 — the scene we are about to click in really is "peer focused, border on peer".
    guard isFirstResponder(peer.view, in: win), hasBorder(peer.clipView),
          !hasBorder(primary.clipView) else {
        print("error: C0 SETUP — after the split, expected peer focused with the border " +
              "(fr-on-peer=\(isFirstResponder(peer.view, in: win)) " +
              "border peer=\(hasBorder(peer.clipView)) primary=\(hasBorder(primary.clipView)))")
        exit(2)
    }
    ok("C0 SETUP: split created, peer focused and bordered")

    // C1 — click the primary.
    click(primary.view, in: win)
    pump(0.5, until: { hasBorder(primary.clipView) && !hasBorder(peer.clipView) })
    if isFirstResponder(primary.view, in: win) {
        ok("C1-FR CLICK: clicking the primary made its terminal first responder")
    } else {
        fail("C1-FR CLICK: first responder after click is \(String(describing: win.firstResponder))")
    }
    let c1a = hasBorder(primary.clipView), c1b = hasBorder(peer.clipView)
    if c1a && !c1b {
        ok("C1-CUE CLICK: focus border moved to the clicked primary")
    } else {
        fail("C1-CUE CLICK: border primary=\(c1a) peer=\(c1b) — expected true/false")
    }

    // C2 — click the peer.
    click(peer.view, in: win)
    pump(0.5, until: { hasBorder(peer.clipView) && !hasBorder(primary.clipView) })
    if isFirstResponder(peer.view, in: win) {
        ok("C2-FR CLICK-BACK: clicking the peer made its terminal first responder")
    } else {
        fail("C2-FR CLICK-BACK: first responder after click is \(String(describing: win.firstResponder))")
    }
    let c2a = hasBorder(peer.clipView), c2b = hasBorder(primary.clipView)
    if c2a && !c2b {
        ok("C2-CUE CLICK-BACK: focus border moved back to the clicked peer")
    } else {
        fail("C2-CUE CLICK-BACK: border peer=\(c2a) primary=\(c2b) — expected true/false")
    }

    // C3 — sub-split the peer half (second ⌘⇧- inside the peer), then click the new
    // sub-peer. This exercises the leaves.count > 2 per-leaf dimming path in
    // SpaceViewController+SplitPresentation.swift:64-79 — the path C1/C2 never reach.
    //
    // Setup: peer currently holds focus (C2 left it there). splitVertical splits the
    // FOCUSED pane, which is the peer, producing a peerSubSplit leaf (sub-peer).
    // We then click the sub-peer and assert it takes focus AND the border.
    svc.splitVertical(nil as Any?)
    pump(0.5)
    guard let subPeer = svc.splitPeers[ObjectIdentifier(primary)]?.peerSubSplit?.document
              as? TerminalPane else {
        print("error: C3 SETUP — peerSubSplit was not created — setup failed"); exit(2)
    }
    // Establish a clean starting state: primary focused, border on primary.
    win.makeFirstResponder(primary.view)
    svc.updateSplitDimming(for: primary)
    pump(0.4, until: { hasBorder(primary.clipView) && !hasBorder(subPeer.clipView) })
    guard isFirstResponder(primary.view, in: win), hasBorder(primary.clipView),
          !hasBorder(subPeer.clipView) else {
        print("error: C3 SETUP — expected primary focused before sub-peer click " +
              "(fr-primary=\(isFirstResponder(primary.view, in: win)) " +
              "border primary=\(hasBorder(primary.clipView)) subpeer=\(hasBorder(subPeer.clipView)))")
        exit(2)
    }

    click(subPeer.view, in: win)
    pump(0.5, until: { hasBorder(subPeer.clipView) && !hasBorder(primary.clipView) })
    if isFirstResponder(subPeer.view, in: win) {
        ok("C3-FR SUB-SPLIT: clicking the sub-peer made it first responder")
    } else {
        fail("C3-FR SUB-SPLIT: first responder after click is \(String(describing: win.firstResponder))")
    }
    let c3a = hasBorder(subPeer.clipView), c3b = hasBorder(primary.clipView)
    if c3a && !c3b {
        ok("C3-CUE SUB-SPLIT: focus border moved to the sub-peer (leaves.count > 2 path)")
    } else {
        fail("C3-CUE SUB-SPLIT: border subPeer=\(c3a) primary=\(c3b) — expected true/false")
    }


    // C4 — focus moves to the file tree outline (sidebar); the last-focused pane stays lit.
    //
    // WHY THIS CASE EXISTS (R1.7, #269)
    //
    // The old guard in handleFirstResponderChange used `fr.isDescendant(of: view)`, where
    // `view` is the Space's whole root view including the sidebar/file tree outline.  A
    // sidebar click therefore passed the guard, reached updateSplitDimming with no leaf
    // owning the new first responder, and called setFocusedChild(nil, …) — dimming both
    // panes.  The fix narrows the guard to leaf descendants only.  This case asserts the
    // correct product decision: the last-focused pane (peer, from C2) keeps its border.
    //
    // The mutant (M3) reintroduces the old wide guard so C4-CUE fails while C4-FR is N/A
    // (the file tree does NOT move terminal focus — C4 only checks the border/dimming).
    //
    // Setup: C3 left the sub-peer focused.  Re-establish peer as the focused pane so C4's
    // starting state is defined independently of C3.
    win.makeFirstResponder(peer.view)
    svc.updateSplitDimming(for: primary)
    pump(0.3, until: { hasBorder(peer.clipView) && !hasBorder(primary.clipView) })

    // Make the file tree outline the first responder directly (the way a keyboard Tab or a
    // sidebar click would) and confirm updateSplitDimming was NOT triggered — the peer
    // border must stay.
    win.makeFirstResponder(svc.fileTree.view)
    pump(0.3)   // one run-loop turn for the deferred handler to fire (if broken, it dims)
    let c4a = hasBorder(peer.clipView), c4b = hasBorder(primary.clipView)
    if c4a && !c4b {
        ok("C4-CUE SIDEBAR: focus to file tree leaves the last-focused pane (peer) lit")
    } else {
        fail("C4-CUE SIDEBAR: border peer=\(c4a) primary=\(c4b) — expected true/false " +
             "(sidebar focus should NOT move the accent border)")
    }
    // Confirm the file tree actually is first responder so the case is testing the right thing.
    let c4fr = win.firstResponder
    if let frv = c4fr as? NSView, (frv === svc.fileTree.view || frv.isDescendant(of: svc.fileTree.view)) {
        ok("C4-FR SIDEBAR: file tree outline is first responder after makeFirstResponder")
    } else {
        fail("C4-FR SIDEBAR: expected file tree as FR, got \(String(describing: c4fr))")
    }

    // C5 — focus moves to an NSTextField standing in for a find bar / filter field.
    //
    // WHY THIS CASE EXISTS (R1.7, #269)
    //
    // SwiftTerm mounts its find bar inside the terminal pane's own view hierarchy — it is a
    // child of MacTerminalView.  Focusing the find bar therefore satisfies
    // isDescendant(fr, of: leaf.view) for that pane's leaf, so updateSplitDimming fires
    // and keeps THAT pane lit.  This case simulates that path with a synthesised NSTextField
    // added as a child of peer.view (the same containment relationship the real find bar has),
    // then asserts the peer border stays on — i.e. updateSplitDimming ran and correctly
    // identified the peer as the focused leaf.
    //
    // After C4 the peer border is still on (asserted by C4).  Re-establish peer first
    // responder so C5's starting state is defined independently of C4.
    win.makeFirstResponder(peer.view)
    svc.updateSplitDimming(for: primary)
    pump(0.3, until: { hasBorder(peer.clipView) && !hasBorder(primary.clipView) })

    // Install a stand-in text field inside peer.view (mirrors find bar containment).
    let fakeBar = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    peer.view.addSubview(fakeBar)
    win.makeFirstResponder(fakeBar)
    pump(0.3, until: { hasBorder(peer.clipView) })
    let c5a = hasBorder(peer.clipView), c5b = hasBorder(primary.clipView)
    if c5a && !c5b {
        ok("C5-CUE FINDBAR: focus to in-pane text field keeps the pane (peer) lit")
    } else {
        fail("C5-CUE FINDBAR: border peer=\(c5a) primary=\(c5b) — expected true/false " +
             "(find bar inside the pane should keep that pane's accent border)")
    }
    fakeBar.removeFromSuperview()
    win.makeFirstResponder(peer.view)

    svc.tearDownAllDocuments()
    pump(0.1)
    print(bad == 0 ? "\nall click-focus cases passed" : "\n\(bad) click-focus case(s) FAILED")
    exit(bad == 0 ? 0 : 1)
}
