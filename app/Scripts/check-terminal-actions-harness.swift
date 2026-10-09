// check-terminal-actions-harness.swift
// Compiled by check-terminal-actions.sh against @testable GoblinPortal objects.
// NEVER run directly.
//
// SEAMS USED:
//   · SpaceViewController delegate methods (A6-A9) — called on a real SpaceViewController
//     whose documents[] contains only FakeShellHost. TerminalActionGuard.production's
//     foregroundReader returns a controlled ForegroundKind before each call.
//
//   · AppDelegate.sendPathToTerminal / runInTerminal (A1-A5, M1) — called on a real
//     AppDelegate. SpaceWindowController.presentForWaitMode adds the controller to
//     SpaceWindowController.open so focusedSpace resolves. FileViewerPane is activeDocument
//     (from presentForWaitMode); FakeShellHost is shellHosts.last (added via space.add).
//     selectDocument(at:0) restores FileViewerPane as active after add(document:).
//
//   · AppDelegate.validateMenuItem (V1, M1) — called with real NSMenuItems carrying the
//     shipped selectors. Same SpaceViewController graph as A1-A5.
//
// WHY presentForWaitMode. It appends to SpaceWindowController.open without spawning a
// terminal (open.append is in present()/presentAsTab()/presentForWaitMode). It also opens
// the test file as a FileViewerPane, which is the document kind the shipped guard requires.
// Setting isTerminating prevents UserDefaults writes from polluting the user's session.
//
import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String)   { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

// ── FakeShellHost ────────────────────────────────────────────────────────────────────

/// A minimal ShellHosting conformer that records bytes sent and exposes foregroundKind
/// so tests control the TerminalInputPolicy decision without a real pty.
///
/// SpaceDocument default implementations (documentIsEdited, documentStatus,
/// clearAttention, notifyWindowFocus, documentWindowDidBecomeKey) come from the
/// protocol extension in SpaceDocument.swift — no overrides needed here.
@MainActor
final class FakeShellHost: NSObject, SpaceDocumentReporting, ShellHosting {
    // SpaceDocument required members with no protocol-extension default.
    var documentTitle: String = "Fake"
    var documentSymbolName: String = "terminal"
    var documentView: NSView = NSView()
    var documentDelegate: SpaceDocumentDelegate?
    var documentReporting: SpaceDocumentReporting?
    var currentFontSize: CGFloat = 14
    func apply(config: AppConfig) {}
    func setFontSize(_ size: CGFloat, persist: Bool) {}
    func resetFontSize() {}
    func documentWillClose() {}
    func documentDidBecomeActive() {}
    // ShellHosting.
    var capturedText: String = ""
    var currentDirectory: URL? { nil }
    var shellContext: ShellContext {
        ShellContext(foreground: foregroundKind, directory: nil, followStatus: .unavailable)
    }
    func refreshDirectoryState() {}
    func send(text: String) { capturedText += text }
    // Test control: set per-case before calling the action.
    var foregroundKind: ForegroundKind? = nil
}

// ── Beep counter ─────────────────────────────────────────────────────────────────────
// A class so closures capture it by reference without needing inout.
final class BeepCounter { var count = 0 }

// ─────────────────────────────────────────────────────────────────────────────────────
MainActor.assumeIsolated {

let cfg = AppConfig.defaults()
let spaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("gp-terminal-actions-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: spaceRoot, withIntermediateDirectories: true)

// ── T1. TerminalInputPolicy truth table ──────────────────────────────────────────────
// Pure function — no seam or Space graph needed.
let allowedKinds: [ForegroundKind] = [
    .shell, .knownShell(pid: 1, name: "bash"), .tmuxClient(pid: 2, tty: "/dev/ttys001"),
]
let refusedKinds: [ForegroundKind?] = [
    .command(name: "python3"), .remote(name: "ssh"),
    .otherMultiplexer(name: "screen"), nil,
]
for k in allowedKinds {
    if TerminalInputPolicy.allowsTyping(into: k) { ok("T1 allowsTyping(\(k)) == true") }
    else { fail("T1 allowsTyping(\(k)) returned false — should be allowed") }
}
for k in refusedKinds {
    let label = k.map { "\($0)" } ?? "nil"
    if !TerminalInputPolicy.allowsTyping(into: k) { ok("T1 allowsTyping(\(label)) == false") }
    else { fail("T1 allowsTyping(\(label)) returned true — should be refused") }
}

// ── SpaceViewController graph for A6-A9 ─────────────────────────────────────────────
// A minimal Space with only FakeShellHost in documents[]. No AppDelegate needed:
// the delegate method is called directly on the Space, bypassing focusedSpace resolution.
let spaceForDelegates = SpaceViewController(config: cfg, root: spaceRoot)
let wcDelegate = SpaceWindowController(config: cfg, root: spaceRoot)

let h_delegates = FakeShellHost()

// ── A6. Insert Path: .knownShell → quoted path + space, no beep ──────────────────────
// Calls SHIPPED fileTree(_:didRequestPathInsert:) on a real SpaceViewController.
// focusedShellHost = h_delegates (only document in documents[]).
h_delegates.foregroundKind = .knownShell(pid: 10, name: "fish")
let c_a6 = BeepCounter()
wcDelegate.space.add(document: h_delegates)
TerminalActionGuard.production.foregroundReader = { _ in h_delegates.foregroundKind }
TerminalActionGuard.production.beepSink = { c_a6.count += 1 }
let url_a6 = spaceRoot.appendingPathComponent("my file.txt")
let expectedQuoted_a6 = "'" + url_a6.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
wcDelegate.space.fileTree(wcDelegate.space.fileTree, didRequestPathInsert: url_a6)
if h_delegates.capturedText == expectedQuoted_a6 + " " { ok("A6 Insert Path .knownShell → quoted path sent") }
else { fail("A6 Insert Path .knownShell → sent='\(h_delegates.capturedText)'") }
if c_a6.count == 0 { ok("A6 Insert Path .knownShell → no beep") }
else { fail("A6 Insert Path .knownShell → beep count=\(c_a6.count)") }

// ── A7. Insert Path: .otherMultiplexer → no bytes, one beep ─────────────────────────
h_delegates.capturedText = ""   // reset; h_delegates is still the only document / focusedShellHost
let c_a7 = BeepCounter()
TerminalActionGuard.production.foregroundReader = { _ in ForegroundKind.otherMultiplexer(name: "screen") }
TerminalActionGuard.production.beepSink = { c_a7.count += 1 }
wcDelegate.space.fileTree(wcDelegate.space.fileTree, didRequestPathInsert: url_a6)
if h_delegates.capturedText.isEmpty { ok("A7 Insert Path .otherMultiplexer → no bytes") }
else { fail("A7 Insert Path .otherMultiplexer → bytes leaked: '\(h_delegates.capturedText)'") }
if c_a7.count == 1 { ok("A7 Insert Path .otherMultiplexer → exactly one beep") }
else { fail("A7 Insert Path .otherMultiplexer → beep count=\(c_a7.count)") }

// ── A8. cd Here: .tmuxClient → cd command sent ───────────────────────────────────────
h_delegates.capturedText = ""
let c_a8 = BeepCounter()
TerminalActionGuard.production.foregroundReader = { _ in ForegroundKind.tmuxClient(pid: 42, tty: "/dev/ttys007") }
TerminalActionGuard.production.beepSink = { c_a8.count += 1 }
let url_a8 = spaceRoot.appendingPathComponent("my project")
try? FileManager.default.createDirectory(at: url_a8, withIntermediateDirectories: true)
let expectedCmd_a8 = ShellDirectory.cdCommand(to: url_a8)
wcDelegate.space.fileTree(wcDelegate.space.fileTree, didRequestChangeDirectory: url_a8)
if h_delegates.capturedText == expectedCmd_a8 { ok("A8 cd Here .tmuxClient → cd command sent") }
else { fail("A8 cd Here .tmuxClient → sent='\(h_delegates.capturedText)' expected='\(expectedCmd_a8)'") }
if c_a8.count == 0 { ok("A8 cd Here .tmuxClient → no beep") }
else { fail("A8 cd Here .tmuxClient → beep count=\(c_a8.count)") }

// ── A9. cd Here: .command → no bytes, one beep ───────────────────────────────────────
h_delegates.capturedText = ""
let c_a9 = BeepCounter()
TerminalActionGuard.production.foregroundReader = { _ in ForegroundKind.command(name: "agent-afk") }
TerminalActionGuard.production.beepSink = { c_a9.count += 1 }
wcDelegate.space.fileTree(wcDelegate.space.fileTree, didRequestChangeDirectory: url_a8)
if h_delegates.capturedText.isEmpty { ok("A9 cd Here .command → no bytes") }
else { fail("A9 cd Here .command → bytes leaked: '\(h_delegates.capturedText)'") }
if c_a9.count == 1 { ok("A9 cd Here .command → exactly one beep") }
else { fail("A9 cd Here .command → beep count=\(c_a9.count)") }

// ── AppDelegate + SpaceWindowController graph for A1-A5, V1, M1 ─────────────────────
// presentForWaitMode: appends to SpaceWindowController.open so focusedSpace resolves;
// opens testFile as a FileViewerPane (satisfies `guard … as? FileViewerPane`);
// sets isTerminating to prevent UserDefaults writes during the test run.
// The FakeShellHost is added afterwards so shellHosts.last returns it;
// selectDocument(at: 0) restores FileViewerPane as activeDocument.
let testFile = spaceRoot.appendingPathComponent("test.py")
try? "print('hello')".write(to: testFile, atomically: true, encoding: .utf8)

let appDelegate = AppDelegate()
app.delegate = appDelegate
appDelegate.buildMenu()   // populates mainMenu so #selector lookups work

let wc = SpaceWindowController(config: cfg, root: spaceRoot)
guard let win = wc.window else { print("ENV  SpaceWindowController produced no window"); exit(2) }
win.setFrame(NSRect(x: -20000, y: -20000, width: 1100, height: 680), display: false)
wc.presentForWaitMode(opening: testFile)   // → open.append(self) + openFile(testFile)

let space = wc.space
let h_app = FakeShellHost()
space.add(document: h_app)          // h_app is now activeDocument; shellHosts.last = h_app
space.selectDocument(at: 0)         // restore FileViewerPane as activeDocument
// focusedShellHost = (activeDoc as? ShellHosting) ?? shellHosts.last = h_app ✓

// ── A1. sendPathToTerminal: .shell → bytes sent, no beep ─────────────────────────────
let c_a1 = BeepCounter()
TerminalActionGuard.production.foregroundReader = { _ in ForegroundKind.shell }
TerminalActionGuard.production.beepSink = { c_a1.count += 1 }
appDelegate.sendPathToTerminal(nil)
let expectedPath = "'" + testFile.path.replacingOccurrences(of: "'", with: "'\\''") + "' "
if h_app.capturedText == expectedPath { ok("A1 sendPathToTerminal .shell → bytes sent") }
else { fail("A1 sendPathToTerminal .shell → sent='\(h_app.capturedText)' expected='\(expectedPath)'") }
if c_a1.count == 0 { ok("A1 sendPathToTerminal .shell → no beep") }
else { fail("A1 sendPathToTerminal .shell → beep count=\(c_a1.count)") }

// ── A2. sendPathToTerminal: .command → no bytes, one beep ────────────────────────────
h_app.capturedText = ""
let c_a2 = BeepCounter()
TerminalActionGuard.production.foregroundReader = { _ in ForegroundKind.command(name: "agent-afk") }
TerminalActionGuard.production.beepSink = { c_a2.count += 1 }
appDelegate.sendPathToTerminal(nil)
if h_app.capturedText.isEmpty { ok("A2 sendPathToTerminal .command → no bytes") }
else { fail("A2 sendPathToTerminal .command → bytes leaked: '\(h_app.capturedText)'") }
if c_a2.count == 1 { ok("A2 sendPathToTerminal .command → exactly one beep") }
else { fail("A2 sendPathToTerminal .command → beep count=\(c_a2.count)") }

// ── A3. sendPathToTerminal: nil → no bytes, one beep (fail-closed) ───────────────────
h_app.capturedText = ""
let c_a3 = BeepCounter()
TerminalActionGuard.production.foregroundReader = { _ in nil }
TerminalActionGuard.production.beepSink = { c_a3.count += 1 }
appDelegate.sendPathToTerminal(nil)
if h_app.capturedText.isEmpty { ok("A3 sendPathToTerminal nil → no bytes (fail-closed)") }
else { fail("A3 sendPathToTerminal nil → bytes leaked: '\(h_app.capturedText)'") }
if c_a3.count == 1 { ok("A3 sendPathToTerminal nil → exactly one beep") }
else { fail("A3 sendPathToTerminal nil → beep count=\(c_a3.count)") }

// ── A4. runInTerminal (.py): .shell → exact "python3 '<path>'\n" ─────────────────────
h_app.capturedText = ""
let c_a4 = BeepCounter()
TerminalActionGuard.production.foregroundReader = { _ in ForegroundKind.shell }
TerminalActionGuard.production.beepSink = { c_a4.count += 1 }
let quotedPy = "'" + testFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
let expectedRun = "python3 \(quotedPy)\n"
appDelegate.runInTerminal(nil)
if h_app.capturedText == expectedRun { ok("A4 runInTerminal .py .shell → exact bytes") }
else { fail("A4 runInTerminal .py .shell → sent='\(h_app.capturedText)' expected='\(expectedRun)'") }
if c_a4.count == 0 { ok("A4 runInTerminal .py .shell → no beep") }
else { fail("A4 runInTerminal .py .shell → beep count=\(c_a4.count)") }

// ── A5. runInTerminal: .remote → no bytes, one beep ─────────────────────────────────
h_app.capturedText = ""
let c_a5 = BeepCounter()
TerminalActionGuard.production.foregroundReader = { _ in ForegroundKind.remote(name: "ssh") }
TerminalActionGuard.production.beepSink = { c_a5.count += 1 }
appDelegate.runInTerminal(nil)
if h_app.capturedText.isEmpty { ok("A5 runInTerminal .remote → no bytes") }
else { fail("A5 runInTerminal .remote → bytes leaked: '\(h_app.capturedText)'") }
if c_a5.count == 1 { ok("A5 runInTerminal .remote → exactly one beep") }
else { fail("A5 runInTerminal .remote → beep count=\(c_a5.count)") }

// ── V1. validateMenuItem: enabled for shell/knownShell/tmuxClient, disabled for rest ─
// Calls the SHIPPED AppDelegate.validateMenuItem with real NSMenuItems.
let sptSel = #selector(AppDelegate.sendPathToTerminal(_:))
let ritSel = #selector(AppDelegate.runInTerminal(_:))
let valAllowed: [(ForegroundKind?, String)] = [
    (.shell, "shell"), (.knownShell(pid: 1, name: "zsh"), "knownShell"),
    (.tmuxClient(pid: 2, tty: "/dev/ttys000"), "tmuxClient"),
]
let valRefused: [(ForegroundKind?, String)] = [
    (.command(name: "vim"), "command"), (.remote(name: "ssh"), "remote"),
    (.otherMultiplexer(name: "zellij"), "otherMultiplexer"), (nil, "nil"),
]
for (kind, name) in valAllowed {
    TerminalActionGuard.production.foregroundReader = { _ in kind }
    TerminalActionGuard.production.beepSink = {}   // validates must never beep
    let i1 = NSMenuItem(); i1.action = sptSel
    let i2 = NSMenuItem(); i2.action = ritSel
    if appDelegate.validateMenuItem(i1) { ok("V1 sendPathToTerminal validateMenuItem(\(name)) == true") }
    else { fail("V1 sendPathToTerminal validateMenuItem(\(name)) returned false") }
    if appDelegate.validateMenuItem(i2) { ok("V1 runInTerminal validateMenuItem(\(name)) == true") }
    else { fail("V1 runInTerminal validateMenuItem(\(name)) returned false") }
}
for (kind, name) in valRefused {
    TerminalActionGuard.production.foregroundReader = { _ in kind }
    TerminalActionGuard.production.beepSink = {}
    let i1 = NSMenuItem(); i1.action = sptSel
    let i2 = NSMenuItem(); i2.action = ritSel
    if !appDelegate.validateMenuItem(i1) { ok("V1 sendPathToTerminal validateMenuItem(\(name)) == false") }
    else { fail("V1 sendPathToTerminal validateMenuItem(\(name)) returned true — should be disabled") }
    if !appDelegate.validateMenuItem(i2) { ok("V1 runInTerminal validateMenuItem(\(name)) == false") }
    else { fail("V1 runInTerminal validateMenuItem(\(name)) returned true — should be disabled") }
}

// ── M1. Safe-at-validation, unsafe-at-execution ──────────────────────────────────────
// validateMenuItem sees .shell → enabled. Foreground switches to .command at click time.
// The execution-time check in sendPathToTerminal must catch the switch.
h_app.capturedText = ""
let c_m1 = BeepCounter()
TerminalActionGuard.production.foregroundReader = { _ in ForegroundKind.shell }
TerminalActionGuard.production.beepSink = { c_m1.count += 1 }
let mitem = NSMenuItem(); mitem.action = sptSel
if appDelegate.validateMenuItem(mitem) { ok("M1 validateMenuItem .shell → enabled") }
else { fail("M1 validateMenuItem .shell returned false") }
// Foreground changes between menu-open (validate) and menu-click (send).
TerminalActionGuard.production.foregroundReader = { _ in ForegroundKind.command(name: "python3") }
appDelegate.sendPathToTerminal(nil)
if h_app.capturedText.isEmpty { ok("M1 no bytes after foreground switch to .command") }
else { fail("M1 bytes leaked after switch: '\(h_app.capturedText)'") }
if c_m1.count == 1 { ok("M1 exactly one beep — execution-time guard caught .command") }
else { fail("M1 beep count=\(c_m1.count), expected 1") }

// ── Summary ───────────────────────────────────────────────────────────────────────────
if bad == 0 {
    print("\nall terminal-action guard cases passed")
    exit(0)
} else {
    print("\n\(bad) terminal-action guard case(s) FAILED")
    exit(1)
}

} // end MainActor.assumeIsolated
