//
//  check-focus-cue-k4.swift
//  K4: the live accent-refresh path (subscribeToSystemColorChanges → notification →
//  updateSplitDimming → updateFocusCue) is wired correctly and runs end-to-end.
//
//  WHY THIS FILE EXISTS
//
//  check-focus-cue.sh (K1-K3) gates TerminalClipView.layout() re-frames the border on
//  resize. K4 gates the complementary concern from #260: that posting
//  NSColor.systemColorsDidChangeNotification causes the SHIPPED observer installed by
//  subscribeToSystemColorChanges() to re-run updateSplitDimming, updating the border
//  colour immediately without a ⌘R reload. Sourced from check-focus-cue-falsify.sh.
//
//  TWO-PART GATE
//
//  Part A — structural wiring check:
//    Grep SpaceViewController+FocusCue.swift for the two expressions that wire the
//    notification path: the addObserver call site and the updateSplitDimming call inside
//    the closure. Uses comment-stripped grep to avoid false positives from doc-comment
//    lines that name the same symbols (check-theme-contrast.sh's lesson: "grep the
//    construct, not the vocabulary").
//
//  Part B — runtime end-to-end check:
//    Build a real SpaceViewController via viewDidLoad() so subscribeToSystemColorChanges()
//    is called through the production path. Add a split so gatherLeaves sees two panes.
//    Paint a sentinel CGColor on the focused pane's border layer (different from the
//    accent colour the shipped code would apply). Post systemColorsDidChangeNotification
//    on NotificationCenter.default. Pump RunLoop.main. Assert the border colour is no
//    longer the sentinel — proving the SHIPPED observer fired, called updateSplitDimming,
//    which called updateFocusCue, which called addFocusBorder with the real accent colour.
//    NO test observer is installed. The only observer that can repair the sentinel is the
//    one subscribeToSystemColorChanges() registered.
//
//  SENTINEL VALIDITY
//
//  If the sentinel step were skipped (border already at the accent colour), posting the
//  notification would leave the colour unchanged and the assert would still pass —
//  making K4 trivially green without exercising anything. The sentinel (a visibly wrong
//  colour set WITHOUT going through updateSplitDimming) is what makes Part B meaningful:
//  it forces the notification handler to do observable work.
//
//  FALSIFICATION (in check-focus-cue-falsify.sh)
//
//  The app/ directory is cloned (APFS clonefile, incremental rebuild) into $TMP.
//  subscribeToSystemColorChanges() is emptied in the CLONE's +FocusCue.swift.
//  The clone is rebuilt; the K4 harness is linked against the clone's objects.
//  Part B must fail for the mutant — the border stays at the sentinel because no
//  observer fires. Part A also fails (wiring greps miss). K4-CONTROL requires the
//  mutant to exit 1 because Part B (the runtime case) fails, not only Part A.
//  The env flag SKIP_PART_A=1 disables Part A so the falsification proves Part B
//  alone is sufficient to catch the mutant.
//
//  EXIT CODES — same three-valued contract as every other gate in this repo:
//    0 = K4 passed (Part A wiring greps found; Part B runtime sentinel repaired)
//    1 = real failure (Part A grep missing, or Part B sentinel not repaired)
//    2 = environmental (harness did not compile, objects missing, setup failed)
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

/// The CGColor currently set as borderColor on the goblin.focusBorder sublayer of view,
/// or nil if no such layer exists.
@MainActor
func borderColor(on view: NSView) -> CGColor? {
    view.layer?.sublayers?
        .first(where: { $0.name == TerminalClipView.focusBorderLayerName })?
        .borderColor
}

// ---------------------------------------------------------------------------
// Part A — structural wiring check
//
// Grep SpaceViewController+FocusCue.swift for:
//   1. The addObserver call that subscribes to systemColorsDidChangeNotification.
//   2. The updateSplitDimming call inside that subscriber's closure.
//
// Comment-stripped: strip `/`-prefixed lines before grepping so a doc-comment
// mentioning the same symbol doesn't produce a false positive (the lesson from
// check-theme-contrast.sh's preset grep). SKIP_PART_A=1 lets K4-CONTROL disable
// this check so it can prove Part B alone fails for the mutant.
// ---------------------------------------------------------------------------
// FOCUS_CUE_SRC_PATH may be overridden by the K4-CONTROL falsification run so the
// grep reads the MUTANT source (the copy compiled into the mutant binary), not the
// shipped source. Without this, the grep always reads the original file even when
// the mutant binary is under test, making the wiring check blind to mutations.
let focusCueSrcPath: String
if let envPath = ProcessInfo.processInfo.environment["FOCUS_CUE_SRC_PATH"] {
    focusCueSrcPath = envPath
} else {
    let url = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()           // Scripts/
        .appendingPathComponent("../Sources/GoblinPortal/SpaceViewController+FocusCue.swift")
    focusCueSrcPath = url.standardized.path
}

let skipPartA = ProcessInfo.processInfo.environment["SKIP_PART_A"] == "1"

if !skipPartA {
    let focusCueSrc: String
    do {
        focusCueSrc = try String(contentsOfFile: focusCueSrcPath, encoding: .utf8)
    } catch {
        print("error: cannot read SpaceViewController+FocusCue.swift at \(focusCueSrcPath) — \(error)")
        exit(2)
    }

    // Strip comment lines before grepping.
    let codeLines = focusCueSrc.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    let strippedCode = codeLines.joined(separator: "\n")

    // Wiring grep 1: addObserver for systemColorsDidChangeNotification.
    if strippedCode.contains("addObserver") &&
       strippedCode.contains("systemColorsDidChangeNotification") {
        ok("K4-A1 WIRING: addObserver(forName: NSColor.systemColorsDidChangeNotification)" +
           " found in SpaceViewController+FocusCue.swift (code, not comment)")
    } else {
        fail("K4-A1 WIRING: addObserver for systemColorsDidChangeNotification NOT found" +
             " in SpaceViewController+FocusCue.swift — subscription is missing")
    }

    // Wiring grep 2: updateSplitDimming call inside the subscriber body.
    if strippedCode.contains("updateSplitDimming") {
        ok("K4-A2 WIRING: updateSplitDimming call found in SpaceViewController+FocusCue.swift" +
           " — notification closure is wired to the refresh path")
    } else {
        fail("K4-A2 WIRING: updateSplitDimming NOT found in SpaceViewController+FocusCue.swift" +
             " — notification closure is not wired to the refresh path")
    }

    if bad > 0 {
        print("\nK4 FAILED — wiring check failed; skipping runtime test")
        exit(1)
    }
} else {
    print("  (Part A skipped via SKIP_PART_A=1 — proving Part B alone catches the mutant)")
}

// ---------------------------------------------------------------------------
// Part B — runtime end-to-end check
//
// Proves the SHIPPED observer (registered by subscribeToSystemColorChanges(), called
// from viewDidLoad()) fires when systemColorsDidChangeNotification is posted and
// repairs the border colour from a sentinel value back to the accent colour.
//
// NO test observer is installed. The only path that can repair the sentinel is:
//   notification → shipped observer → updateSplitDimming → updateFocusCue → addFocusBorder
//
// Sentinel: an arbitrary CGColor (opaque red) that is visibly wrong and guaranteed
// different from any accent colour the code computes (accent is always at 0.55 alpha,
// so CGColor(red:1,green:0,blue:0,alpha:1.0) cannot be the result of the production
// path). Set directly on the CALayer to bypass updateSplitDimming — the sentinel is
// what makes the case meaningful (see SENTINEL VALIDITY in the header above).
// ---------------------------------------------------------------------------
MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
    let svc = SpaceViewController(config: AppConfig.defaults(), root: root)

    // Use a real offscreen window so viewDidLoad fires and the view hierarchy is live.
    let win = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)
    win.contentViewController = svc
    win.makeKeyAndOrderFront(nil)
    pump(0.2)
    // viewDidLoad() has now run → subscribeToSystemColorChanges() has been called →
    // the shipped NotificationCenter observer is installed.

    // Add a document so the Space has a primary pane.
    let primaryDoc = svc.addTerminalDocument()
    pump(0.1)

    // Create a split so gatherLeaves returns ≥2 leaves — without this,
    // updateSplitDimming is a no-op and updateFocusCue never runs.
    svc.splitHorizontal(nil as Any?)
    pump(0.1)
    guard svc.splitPeers[ObjectIdentifier(primaryDoc)] != nil else {
        print("error: split was not created — setup failed")
        exit(2)
    }

    // Give primaryDoc focus so updateSplitDimming installs the border on its clip view.
    win.makeFirstResponder(primaryDoc.documentView)
    svc.updateSplitDimming(for: primaryDoc)
    pump(0.05)

    guard let clipView = primaryDoc.documentView as? TerminalClipView else {
        print("error: primaryDoc.documentView is not a TerminalClipView — setup failed")
        exit(2)
    }
    guard borderColor(on: clipView) != nil else {
        print("error: no focus-border layer after initial updateSplitDimming — setup failed")
        exit(2)
    }

    // Paint a sentinel colour directly on the border layer, bypassing updateSplitDimming.
    // This is the step that makes K4 meaningful: without it, the assertion would pass
    // trivially even if the notification handler never fired.
    let sentinel = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)  // opaque red
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    clipView.layer?.sublayers?
        .first(where: { $0.name == TerminalClipView.focusBorderLayerName })?
        .borderColor = sentinel
    CATransaction.commit()

    guard borderColor(on: clipView) == sentinel else {
        print("error: sentinel colour did not apply — setup failed")
        exit(2)
    }

    // Post the notification. The SHIPPED observer (installed by subscribeToSystemColorChanges
    // in viewDidLoad) must call updateSplitDimming → updateFocusCue → addFocusBorder,
    // replacing the sentinel with the computed accent colour (effectiveAccent at 0.55 alpha).
    // No test observer is registered; nothing else can repair the sentinel.
    NotificationCenter.default.post(
        name: NSColor.systemColorsDidChangeNotification, object: nil)
    pump(0.3, until: { borderColor(on: clipView) != sentinel })

    let afterColor = borderColor(on: clipView)
    if afterColor != nil && afterColor != sentinel {
        ok("K4-B RUNTIME: posting systemColorsDidChangeNotification caused the SHIPPED" +
           " observer to call updateSplitDimming → border sentinel was replaced by" +
           " the computed accent colour — end-to-end path confirmed")
    } else if afterColor == sentinel {
        fail("K4-B RUNTIME: border colour is still the sentinel after notification post" +
             " — the shipped observer did not call updateSplitDimming (or it was not" +
             " registered by subscribeToSystemColorChanges)")
    } else {
        fail("K4-B RUNTIME: border layer disappeared after notification post" +
             " — updateFocusCue ran but removed the layer instead of updating it")
    }

    if bad == 0 {
        print("\nK4 passed — notification wiring verified (Part A) and" +
              " shipped observer end-to-end path confirmed (Part B)")
    } else {
        print("\nK4 FAILED — see failures above")
    }
    exit(bad == 0 ? 0 : 1)
}
