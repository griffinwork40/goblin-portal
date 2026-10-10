// check-directory-indicator-harness.swift
// Compiled and linked by check-directory-indicator.sh against GoblinPortal's own
// object files. Holds cases 1–7 (indicator state machine, idempotency, text).
// Cases 8–10 (order, poller seam, recovery) live in check-directory-indicator-cases2.swift.
// Same split rationale as check-sidebar-activity-harness.swift: both files under 350 LOC.
//
// EXIT CODES: 0 pass · 1 real assertion failure · 2 environmental
//
// CASES HERE:
//   1  NO-INDICATOR-BEFORE-STATUS  — no indicator before any non-local status.
//   2  REMOTE-HOST          — .remote(host:"h") shows "remote: h" + "following paused".
//   3  REMOTE-NO-HOST       — .remote(host:nil) shows "remote session" + "following paused".
//   4  PAUSED               — .paused("zellij") text contains "zellij" and "paused".
//   5  LOCAL-HIDES          — .local hides the indicator.
//   6  UNAVAILABLE-SILENT   — .unavailable does NOT show the indicator.
//   7  IDEMPOTENT           — 5 repeated calls install exactly one view.
//   8–10 in check-directory-indicator-cases2.swift (linked together in one binary).

import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String)   { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

@MainActor func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

@MainActor func findIndicator(in tree: FileTreeViewController) -> DirectoryFollowIndicatorView? {
    return followIndicatorView(on: tree)
}

@MainActor func countIndicators(in tree: FileTreeViewController) -> Int {
    guard let stack = tree.view as? NSStackView else { return 0 }
    return stack.arrangedSubviews.filter { $0 is DirectoryFollowIndicatorView }.count
}

MainActor.assumeIsolated {
    let spaceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    appDelegate.buildMenu()

    let wc = SpaceWindowController(config: .defaults(), root: spaceRoot)
    guard let window = wc.window else { print("  ENV  no window"); exit(2) }
    let space = wc.space
    let tree = space.fileTree
    window.setFrame(NSRect(x: -20000, y: -20000, width: 1100, height: 680), display: false)
    window.orderFront(nil)
    window.makeKey()
    pump(0.3)

    // --- Case 1: no indicator before first non-local status ---
    print("  [case 1] no indicator before first non-local status")
    if findIndicator(in: tree) == nil {
        ok("case 1: no indicator before any status update")
    } else {
        fail("case 1: indicator existed before any status update — eager install forbidden")
    }

    // --- Case 2: .remote(host:"h") ---
    print("  [case 2] .remote(host:\"h\") shows exact text")
    tree.updateDirectoryFollowStatus(.remote(host: "h"))
    pump(0.1)
    if let ind = findIndicator(in: tree) {
        let l1 = ind.line1Label.stringValue; let l2 = ind.line2Label.stringValue
        if !ind.isHidden && l1.contains("remote: h") && l2.contains("following paused") {
            ok("case 2: \"\(l1)\" / \"\(l2)\"")
        } else {
            fail("case 2: hidden=\(ind.isHidden) text=\"\(l1)\" / \"\(l2)\"")
        }
    } else {
        fail("case 2: no indicator installed after .remote(host:\"h\")")
    }

    // --- Case 3: .remote(host:nil) ---
    print("  [case 3] .remote(host:nil) shows generic text")
    tree.updateDirectoryFollowStatus(.remote(host: nil))
    pump(0.1)
    if let ind = findIndicator(in: tree) {
        let l1 = ind.line1Label.stringValue; let l2 = ind.line2Label.stringValue
        if l1.contains("remote session") && l2.contains("following paused") {
            ok("case 3: \"\(l1)\" / \"\(l2)\"")
        } else {
            fail("case 3: \"\(l1)\" / \"\(l2)\"")
        }
    } else { fail("case 3: no indicator after .remote(host:nil)") }

    // --- Case 4: .paused("zellij") ---
    print("  [case 4] .paused(\"zellij\") shows program name")
    tree.updateDirectoryFollowStatus(.paused(program: "zellij"))
    pump(0.1)
    if let ind = findIndicator(in: tree) {
        let combined = "\(ind.line1Label.stringValue) \(ind.line2Label.stringValue)"
        if !ind.isHidden && combined.contains("zellij") && combined.lowercased().contains("paused") {
            ok("case 4: .paused text correct: \"\(combined)\"")
        } else {
            fail("case 4: hidden=\(ind.isHidden) combined=\"\(combined)\"")
        }
    } else { fail("case 4: no indicator after .paused") }

    // --- Case 5: .local hides ---
    print("  [case 5] .local hides the indicator")
    tree.updateDirectoryFollowStatus(.local)
    pump(0.1)
    if let ind = findIndicator(in: tree) {
        if ind.isHidden { ok("case 5: .local hides indicator") }
        else { fail("case 5: indicator still visible after .local") }
    } else { fail("case 5: no indicator found to verify .local") }

    // --- Case 6: .unavailable does not show ---
    print("  [case 6] .unavailable does not show indicator")
    tree.updateDirectoryFollowStatus(.remote(host: "x"))
    pump(0.05)
    tree.updateDirectoryFollowStatus(.unavailable)
    pump(0.1)
    if let ind = findIndicator(in: tree) {
        if ind.isHidden { ok("case 6: .unavailable keeps indicator hidden") }
        else { fail("case 6: indicator visible for .unavailable — transient state must not show") }
    } else { ok("case 6: no indicator for .unavailable — acceptable") }

    // --- Case 7: idempotent installation ---
    print("  [case 7] repeated calls install exactly one view")
    for _ in 0..<5 { tree.updateDirectoryFollowStatus(.remote(host: "h")) }
    pump(0.1)
    let cnt = countIndicators(in: tree)
    if cnt == 1 { ok("case 7: exactly 1 indicator after 5 calls") }
    else { fail("case 7: expected 1, found \(cnt)") }

    // Hand off to cases 8–10 in the second harness file (linked into the same binary).
    // runCases8to10 is defined in check-directory-indicator-cases2.swift.
    runCases8to10(space: space, spaceRoot: spaceRoot)

    if bad == 0 {
        print("==> check-directory-indicator: ALL CASES PASSED")
        exit(0)
    } else {
        print("==> check-directory-indicator: \(bad) case(s) FAILED")
        exit(1)
    }
}
