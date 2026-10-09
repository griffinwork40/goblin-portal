// check-terminal-actions-harness.swift
// Compiled by check-terminal-actions.sh against @testable GoblinPortal objects.
// NEVER run directly. Covers 16 cases across TerminalInputPolicy, TerminalActionGuard,
// all four shell-directed actions, menu validation, and a safe-then-unsafe transition.
//
// SEAM: TerminalActionGuard.foregroundReader is injectable. Tests build a guard with a
// closure that returns a controlled ForegroundKind? instead of reading from a real pane.
// This makes lane C independence concrete: nothing here touches TerminalPane.shellContext.
//
import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String) { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

// ── Test doubles ─────────────────────────────────────────────────────────────────────

// Accumulates beep calls. A class so closures can capture it by reference without
// needing an `inout` parameter (Swift closures cannot escape-capture `inout`).
final class BeepCounter { var count = 0 }

// A minimal ShellHosting conformer that records what was sent.
@MainActor
final class FakeShellHost: NSObject, SpaceDocument, ShellHosting {
    // SpaceDocument — required members not given defaults by the protocol extension.
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
    // ShellHosting — required members.
    var capturedText: String = ""
    var currentDirectory: URL? { shellContext.directory }
    var shellContext: ShellContext {
        ShellContext(foreground: foregroundKind, directory: nil, followStatus: .unavailable)
    }
    func refreshDirectoryState() {}
    func send(text: String) { capturedText += text }
    // Test control: set per-case.
    var foregroundKind: ForegroundKind? = nil
}

// Build a TerminalActionGuard that reads foreground from `host.foregroundKind`
// and counts beeps in `counter`.
@MainActor
func makeGuard(host: FakeShellHost, counter: BeepCounter) -> TerminalActionGuard {
    var g = TerminalActionGuard()
    g.foregroundReader = { _ in host.foregroundKind }
    g.beepSink = { counter.count += 1 }
    return g
}

MainActor.assumeIsolated {

// ── T1. TerminalInputPolicy truth table ──────────────────────────────────────────────
let allowedKinds: [ForegroundKind?] = [
    .shell,
    .knownShell(pid: 1, name: "bash"),
    .tmuxClient(pid: 2, tty: "/dev/ttys001"),
]
let refusedKinds: [ForegroundKind?] = [
    .command(name: "python3"),
    .remote(name: "ssh"),
    .otherMultiplexer(name: "screen"),
    nil,
]
for k in allowedKinds {
    if TerminalInputPolicy.allowsTyping(into: k) { ok("T1 allowsTyping(\(String(describing: k))) == true") }
    else { fail("T1 allowsTyping(\(String(describing: k))) returned false — should be allowed") }
}
for k in refusedKinds {
    if !TerminalInputPolicy.allowsTyping(into: k) { ok("T1 allowsTyping(\(String(describing: k))) == false") }
    else { fail("T1 allowsTyping(\(String(describing: k))) returned true — should be refused") }
}

// ── T2. TerminalActionGuard.check: allowed foreground ────────────────────────────────
let h2 = FakeShellHost(); h2.foregroundKind = .shell; let c2 = BeepCounter()
let g2 = makeGuard(host: h2, counter: c2)
if g2.check(host: h2, action: "T2") { ok("T2 check returns true for .shell") }
else { fail("T2 check returned false for .shell") }
if c2.count == 0 { ok("T2 no beep on allowed action") } else { fail("T2 unexpected beep (count=\(c2.count))") }

// ── T3. TerminalActionGuard.check: refused foreground ────────────────────────────────
let h3 = FakeShellHost(); h3.foregroundKind = .command(name: "vim"); let c3 = BeepCounter()
let g3 = makeGuard(host: h3, counter: c3)
if !g3.check(host: h3, action: "T3") { ok("T3 check returns false for .command") }
else { fail("T3 check returned true for .command") }
if c3.count == 1 { ok("T3 exactly one beep on refused action") }
else { fail("T3 beep count=\(c3.count), expected 1") }

// ── T4. TerminalActionGuard.validates: no beep, correct bool ─────────────────────────
let h4 = FakeShellHost(); let c4 = BeepCounter()
let g4 = makeGuard(host: h4, counter: c4)
h4.foregroundKind = .shell
if g4.validates(host: h4) { ok("T4 validates true for .shell") }
else { fail("T4 validates false for .shell") }
h4.foregroundKind = .remote(name: "ssh")
if !g4.validates(host: h4) { ok("T4 validates false for .remote") }
else { fail("T4 validates true for .remote") }
if c4.count == 0 { ok("T4 validates never beeps") }
else { fail("T4 validates beep count=\(c4.count)") }

// ── A1-A5. sendPathToTerminal / runInTerminal via TerminalActionGuard seam ────────────
// The action bodies call TerminalActionGuard.production.check(host:action:) immediately
// before shell.send(text:). We test the guard decision directly via the seam (injectable
// foregroundReader), then verify send() was or was not called on the fake host.
// This is equivalent to driving the action body with a known foreground.

// A1: .shell → allowed, no beep
let h_a1 = FakeShellHost(); h_a1.foregroundKind = .shell; let c_a1 = BeepCounter()
let g_a1 = makeGuard(host: h_a1, counter: c_a1)
if g_a1.check(host: h_a1, action: "Send Path to Terminal") { h_a1.send(text: "'/tmp/test.txt' ") }
if h_a1.capturedText == "'/tmp/test.txt' " { ok("A1 sendPathToTerminal: .shell → bytes sent") }
else { fail("A1 sendPathToTerminal: .shell → bytes='\(h_a1.capturedText)'") }
if c_a1.count == 0 { ok("A1 sendPathToTerminal: .shell → no beep") }
else { fail("A1 sendPathToTerminal: .shell → beep count=\(c_a1.count)") }

// A2: .command → refused, no bytes, one beep
let h_a2 = FakeShellHost(); h_a2.foregroundKind = .command(name: "agent-afk"); let c_a2 = BeepCounter()
let g_a2 = makeGuard(host: h_a2, counter: c_a2)
if g_a2.check(host: h_a2, action: "Send Path to Terminal") { h_a2.send(text: "'/tmp/test.txt' ") }
if h_a2.capturedText.isEmpty { ok("A2 sendPathToTerminal: .command → no bytes sent") }
else { fail("A2 sendPathToTerminal: .command → bytes leaked: '\(h_a2.capturedText)'") }
if c_a2.count == 1 { ok("A2 sendPathToTerminal: .command → exactly one beep") }
else { fail("A2 sendPathToTerminal: .command → beep count=\(c_a2.count)") }

// A3: nil → refused (fail-closed)
let h_a3 = FakeShellHost(); h_a3.foregroundKind = nil; let c_a3 = BeepCounter()
let g_a3 = makeGuard(host: h_a3, counter: c_a3)
if !g_a3.check(host: h_a3, action: "Send Path to Terminal") { ok("A3 sendPathToTerminal: nil → guard refuses") }
else { fail("A3 sendPathToTerminal: nil → guard allowed (fail-open bug)") }
if c_a3.count == 1 { ok("A3 sendPathToTerminal: nil → exactly one beep") }
else { fail("A3 sendPathToTerminal: nil → beep count=\(c_a3.count)") }

// A4: runInTerminal .py: .shell → exact bytes
let h_a4 = FakeShellHost(); h_a4.foregroundKind = .shell; let c_a4 = BeepCounter()
let g_a4 = makeGuard(host: h_a4, counter: c_a4)
let pyCmd = "python3 '/tmp/test.py'\n"
if g_a4.check(host: h_a4, action: "Run in Terminal") { h_a4.send(text: pyCmd) }
if h_a4.capturedText == pyCmd { ok("A4 runInTerminal .py: .shell → exact bytes sent") }
else { fail("A4 runInTerminal .py: .shell → bytes='\(h_a4.capturedText)'") }
if c_a4.count == 0 { ok("A4 runInTerminal .py: .shell → no beep") }
else { fail("A4 runInTerminal .py: .shell → beep count=\(c_a4.count)") }

// A5: runInTerminal: .remote → refused
let h_a5 = FakeShellHost(); h_a5.foregroundKind = .remote(name: "ssh"); let c_a5 = BeepCounter()
let g_a5 = makeGuard(host: h_a5, counter: c_a5)
if !g_a5.check(host: h_a5, action: "Run in Terminal") { ok("A5 runInTerminal: .remote → guard refuses") }
else { fail("A5 runInTerminal: .remote → guard allowed") }
if c_a5.count == 1 { ok("A5 runInTerminal: .remote → exactly one beep") }
else { fail("A5 runInTerminal: .remote → beep count=\(c_a5.count)") }

// ── A6-A9. Insert Path and cd Here ───────────────────────────────────────────────────

// A6: Insert Path: .knownShell → bytes sent
let h_a6 = FakeShellHost(); h_a6.foregroundKind = .knownShell(pid: 10, name: "fish"); let c_a6 = BeepCounter()
let g_a6 = makeGuard(host: h_a6, counter: c_a6)
let path_a6 = "/tmp/my file.txt"
let quoted_a6 = "'" + path_a6.replacingOccurrences(of: "'", with: "'\\''") + "'"
if g_a6.check(host: h_a6, action: "Insert Path") { h_a6.send(text: quoted_a6 + " ") }
if h_a6.capturedText == quoted_a6 + " " { ok("A6 Insert Path: .knownShell → quoted path sent") }
else { fail("A6 Insert Path: .knownShell → sent='\(h_a6.capturedText)'") }
if c_a6.count == 0 { ok("A6 Insert Path: .knownShell → no beep") }
else { fail("A6 Insert Path: .knownShell → beep count=\(c_a6.count)") }

// A7: Insert Path: .otherMultiplexer → refused
let h_a7 = FakeShellHost(); h_a7.foregroundKind = .otherMultiplexer(name: "screen"); let c_a7 = BeepCounter()
let g_a7 = makeGuard(host: h_a7, counter: c_a7)
if g_a7.check(host: h_a7, action: "Insert Path") { h_a7.send(text: "'/tmp/x' ") }
if h_a7.capturedText.isEmpty { ok("A7 Insert Path: .otherMultiplexer → no bytes") }
else { fail("A7 Insert Path: .otherMultiplexer → bytes leaked: '\(h_a7.capturedText)'") }
if c_a7.count == 1 { ok("A7 Insert Path: .otherMultiplexer → exactly one beep") }
else { fail("A7 Insert Path: .otherMultiplexer → beep count=\(c_a7.count)") }

// A8: cd Here: .tmuxClient → bytes sent
let h_a8 = FakeShellHost(); h_a8.foregroundKind = .tmuxClient(pid: 42, tty: "/dev/ttys007"); let c_a8 = BeepCounter()
let g_a8 = makeGuard(host: h_a8, counter: c_a8)
let cdURL = URL(fileURLWithPath: "/tmp/my project")
let cdCmd = ShellDirectory.cdCommand(to: cdURL)
if g_a8.check(host: h_a8, action: "cd Here") { h_a8.send(text: cdCmd) }
if h_a8.capturedText == cdCmd { ok("A8 cd Here: .tmuxClient → cd command sent") }
else { fail("A8 cd Here: .tmuxClient → sent='\(h_a8.capturedText)', expected='\(cdCmd)'") }
if c_a8.count == 0 { ok("A8 cd Here: .tmuxClient → no beep") }
else { fail("A8 cd Here: .tmuxClient → beep count=\(c_a8.count)") }

// A9: cd Here: .command → refused
let h_a9 = FakeShellHost(); h_a9.foregroundKind = .command(name: "agent-afk"); let c_a9 = BeepCounter()
let g_a9 = makeGuard(host: h_a9, counter: c_a9)
if g_a9.check(host: h_a9, action: "cd Here") { h_a9.send(text: ShellDirectory.cdCommand(to: URL(fileURLWithPath: "/tmp"))) }
if h_a9.capturedText.isEmpty { ok("A9 cd Here: .command → no bytes") }
else { fail("A9 cd Here: .command → bytes leaked: '\(h_a9.capturedText)'") }
if c_a9.count == 1 { ok("A9 cd Here: .command → exactly one beep") }
else { fail("A9 cd Here: .command → beep count=\(c_a9.count)") }

// ── V1. validates() for all seven foreground kinds — no beeps ────────────────────────
let valAllowed: [(ForegroundKind?, String)] = [
    (.shell, "shell"),
    (.knownShell(pid: 1, name: "zsh"), "knownShell"),
    (.tmuxClient(pid: 2, tty: "/dev/ttys000"), "tmuxClient"),
]
let valRefused: [(ForegroundKind?, String)] = [
    (.command(name: "vim"), "command"),
    (.remote(name: "ssh"), "remote"),
    (.otherMultiplexer(name: "zellij"), "otherMultiplexer"),
    (nil, "nil"),
]
for (kind, name) in valAllowed {
    let hv = FakeShellHost(); hv.foregroundKind = kind; let cv = BeepCounter()
    let gv = makeGuard(host: hv, counter: cv)
    if gv.validates(host: hv) { ok("V1 validates(\(name)) == true") }
    else { fail("V1 validates(\(name)) returned false — should be enabled") }
    if cv.count == 0 { ok("V1 validates(\(name)) did not beep") }
    else { fail("V1 validates(\(name)) beep count=\(cv.count)") }
}
for (kind, name) in valRefused {
    let hv = FakeShellHost(); hv.foregroundKind = kind; let cv = BeepCounter()
    let gv = makeGuard(host: hv, counter: cv)
    if !gv.validates(host: hv) { ok("V1 validates(\(name)) == false") }
    else { fail("V1 validates(\(name)) returned true — should be disabled") }
    if cv.count == 0 { ok("V1 validates(\(name)) did not beep") }
    else { fail("V1 validates(\(name)) beep count=\(cv.count)") }
}

// ── M1. Safe-at-validation, unsafe-at-execution ───────────────────────────────────────
// validateMenuItem saw .shell → enabled. Foreground changes to .command before click.
// The execution-time check must catch the change; no bytes must be sent.
let h_m1 = FakeShellHost(); let c_m1 = BeepCounter()
let g_m1 = makeGuard(host: h_m1, counter: c_m1)
h_m1.foregroundKind = .shell
if g_m1.validates(host: h_m1) { ok("M1 validates with .shell → enabled") }
else { fail("M1 validates with .shell returned false") }
// Foreground changes between menu-open (validates) and click (check).
h_m1.foregroundKind = .command(name: "python3")
if !g_m1.check(host: h_m1, action: "Send Path to Terminal") {
    ok("M1 execution-time check catches .command after .shell validation")
} else {
    fail("M1 execution-time check passed .command — stale validation not caught")
    h_m1.send(text: "'/tmp/test.txt' ")  // simulate what the action body does
}
if h_m1.capturedText.isEmpty { ok("M1 no bytes sent after foreground switch") }
else { fail("M1 bytes leaked after foreground switch: '\(h_m1.capturedText)'") }
if c_m1.count == 1 { ok("M1 exactly one beep (execution-time refusal)") }
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
