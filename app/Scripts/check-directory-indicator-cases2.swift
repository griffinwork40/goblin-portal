// check-directory-indicator-cases2.swift
// Compiled alongside check-directory-indicator-harness.swift into one binary.
// Contains cases 8–10 and the FakeShellHost helper.
//
// WHY SPLIT. Both harness files together exceed 700 lines; the ceiling is 350 per
// file (AFK.md, "Conventions"). The seam is clean: this file is test infrastructure
// (helper types + three cases) while the primary harness is the entry point and
// cases 1–7. Neither file knows anything the other does not need.
//
// CASES HERE:
//   8  GIT-HEADER-ORDER     — git header stays above indicator in NSStackView.
//   9  POLLER-DRIVES-STATUS — fake ShellHosting drives indicator via pollNow();
//                             setRoot never called when directory is nil;
//                             refreshDirectoryState() called every tick.
//  10  LOCAL-RECOVERY       — .local after .remote hides note and calls setRoot.
//
// `runCases8to10` is called from the primary harness's MainActor.assumeIsolated block.

import AppKit
@testable import GoblinPortal

// MARK: - FakeShellHost

/// A minimal ShellHosting conformer the harness can drive freely.
/// Uses `DirectoryFollow.testShellHostOverride` so the poller reads this host
/// instead of `space.focusedShellHost`. refreshDirectoryState() is counted.
@MainActor final class FakeShellHost: NSObject, ShellHosting {

    // SpaceDocument required members (no-ops or minimal stubs).
    var documentView: NSView = NSView()
    var documentTitle: String = "fake-shell"
    var documentSymbolName: String = "terminal"
    weak var delegate: SpaceDocumentDelegate?
    weak var reportingDelegate: SpaceDocumentReporting?
    func documentDidBecomeActive() {}
    func apply(config: AppConfig) {}
    var currentFontSize: CGFloat { 14 }
    func setFontSize(_ size: CGFloat, persist: Bool) {}
    func resetFontSize() {}
    func documentWillClose() {}

    // ShellHosting
    var fakeContext: ShellContext = ShellContext(
        foreground: nil, directory: nil, followStatus: .unavailable)
    var shellContext: ShellContext { fakeContext }
    var currentDirectory: URL? { fakeContext.directory }
    func send(text: String) {}
    private(set) var refreshCount = 0
    func refreshDirectoryState() { refreshCount += 1 }
}

// MARK: - Cases 8–10

/// Called from the primary harness after cases 1–7 pass.
/// `bad` and the helpers (ok/fail/pump/findIndicator/countIndicators) are defined
/// in the primary harness and visible here through the shared compilation unit.
@MainActor func runCases8to10(space: SpaceViewController, spaceRoot: URL) {

    let tree = space.fileTree

    // -------------------------------------------------------------------------
    // Case 8 — GIT-HEADER-ORDER
    // The git header must appear above the indicator in arrangedSubviews.
    // -------------------------------------------------------------------------
    print("  [case 8] git header stays above indicator and remains in stack")
    guard let stack = tree.view as? NSStackView else {
        print("  ENV  sidebar view is not NSStackView"); exit(2)
    }
    // Ensure indicator is installed and git header is visible.
    tree.updateDirectoryFollowStatus(.remote(host: "ordertest"))
    tree.gitHeader.isHidden = false
    pump(0.1)

    let arranged = stack.arrangedSubviews
    let gitIdx = arranged.firstIndex(where: { $0 === tree.gitHeader })
    let indIdx = arranged.firstIndex(where: { $0 is DirectoryFollowIndicatorView })

    if let gi = gitIdx, let ii = indIdx {
        if gi < ii { ok("case 8: git header (idx \(gi)) above indicator (idx \(ii))") }
        else { fail("case 8: indicator (idx \(ii)) above git header (idx \(gi)) — wrong order") }
    } else if gitIdx == nil {
        fail("case 8: git header missing from arrangedSubviews")
    } else {
        fail("case 8: indicator missing from arrangedSubviews")
    }

    // -------------------------------------------------------------------------
    // Case 9 — POLLER-DRIVES-STATUS
    // A FakeShellHost with nil directory and .remote status drives the indicator
    // via directoryFollowPollNow() (which calls tick()). setRoot must not be
    // called; refreshDirectoryState() must be called at least once.
    // -------------------------------------------------------------------------
    print("  [case 9] poller drives indicator; setRoot not called when directory nil")
    let wc2 = SpaceWindowController(config: .defaults(), root: spaceRoot)
    guard let win2 = wc2.window else { print("  ENV  no second window"); exit(2) }
    let space2 = wc2.space
    let tree2 = space2.fileTree
    win2.setFrame(NSRect(x: -21000, y: -21000, width: 1100, height: 680), display: false)
    win2.orderFront(nil); win2.makeKey()
    pump(0.2)

    let fake = FakeShellHost()
    // Inject the fake host as the sole document so focusedShellHost returns it.
    space2.addDocumentForTesting(fake)

    fake.fakeContext = ShellContext(
        foreground: nil, directory: nil, followStatus: .remote(host: "testhost"))

    let rootBefore = tree2.root.url
    space2.directoryFollowPollNow()
    pump(0.2)

    let rootAfter = tree2.root.url
    let setRootCalled = rootAfter.resolvingSymlinksInPath().path !=
                        rootBefore.resolvingSymlinksInPath().path

    if setRootCalled {
        fail("case 9: setRoot called when directory was nil — must not happen")
    } else {
        ok("case 9: setRoot not called with nil directory")
    }

    if let ind9 = findIndicator(in: tree2), !ind9.isHidden {
        ok("case 9: indicator updated by poller with nil directory")
    } else {
        fail("case 9: indicator not shown for .remote with nil directory")
    }

    if fake.refreshCount > 0 {
        ok("case 9: refreshDirectoryState() called \(fake.refreshCount)× by poller")
    } else {
        fail("case 9: refreshDirectoryState() never called by poller")
    }

    // -------------------------------------------------------------------------
    // Case 10 — LOCAL-RECOVERY
    // A local directory after .remote hides the indicator AND calls setRoot.
    // Use a different directory than spaceRoot so setRoot's path-equality guard
    // does not short-circuit (the tree was rooted at spaceRoot on creation).
    // -------------------------------------------------------------------------
    print("  [case 10] .local after .remote hides note and moves root")
    // Create a distinct temp dir so the path differs from the current tree root.
    let localURL: URL
    if let tmp = try? FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask,
        appropriateFor: spaceRoot, create: true)
    {
        localURL = tmp
    } else {
        localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cwd-follow-case10-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: localURL) }

    fake.fakeContext = ShellContext(
        foreground: nil, directory: localURL, followStatus: .local)

    let rootBefore10 = tree2.root.url
    space2.directoryFollowPollNow()
    pump(0.2)
    let rootAfter10 = tree2.root.url
    let movedRoot = rootAfter10.resolvingSymlinksInPath().path !=
                    rootBefore10.resolvingSymlinksInPath().path

    if let ind10 = findIndicator(in: tree2) {
        if ind10.isHidden { ok("case 10: indicator hidden after .local recovery") }
        else { fail("case 10: indicator still visible after .local") }
    } else {
        ok("case 10: no indicator for .local (never installed for local status)")
    }

    if movedRoot { ok("case 10: setRoot called — root moved to local directory") }
    else { fail("case 10: setRoot not called — root did not move on local recovery") }
}
