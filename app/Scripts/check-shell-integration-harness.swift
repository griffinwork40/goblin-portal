//
//  check-shell-integration-harness.swift
//  All assertion cases for check-shell-integration.sh. Split so the shell script
//  stays under the 350-LOC ceiling (same pattern as check-git-status-harness.swift).
//
//  Compiled by the shell script as main.swift alongside ShellIntegration.swift
//  and Osc7Directory.swift. EXIT 0 = all pass, EXIT 1 = ≥1 failure.
//
import Foundation

var bad = 0
func fail(_ label: String, _ msg: String) { print("  FAIL \(label): \(msg)"); bad += 1 }

func asBytes(_ s: String) -> ArraySlice<UInt8> { ArraySlice(s.utf8) }

// ── parseExitCode ─────────────────────────────────────────────────────────────
if ShellIntegration.parseExitCode(from: asBytes("D")) != nil {
    fail("D-no-semi", "expected nil") }
if ShellIntegration.parseExitCode(from: asBytes("D;")) != nil {
    fail("D-empty-code", "expected nil for empty suffix") }
if ShellIntegration.parseExitCode(from: asBytes("D;0")) != 0 {
    fail("D;0", "expected 0") }
if ShellIntegration.parseExitCode(from: asBytes("D;1")) != 1 {
    fail("D;1", "expected 1") }
if ShellIntegration.parseExitCode(from: asBytes("D;127")) != 127 {
    fail("D;127", "expected 127") }
if ShellIntegration.parseExitCode(from: asBytes("D;-1")) != -1 {
    fail("D;-1", "expected -1") }
if ShellIntegration.parseExitCode(from: asBytes("D;130")) != 130 {
    fail("D;130", "expected 130") }
if ShellIntegration.parseExitCode(from: asBytes("D;0;extra")) != 0 {
    fail("D;0;extra", "expected 0 (trimmed at non-digit)") }
if ShellIntegration.parseExitCode(from: asBytes("D;abc")) != nil {
    fail("D;abc", "expected nil for non-numeric code") }

// ── OSC 133 state machine ─────────────────────────────────────────────────────
var received: [(Int?, UInt64)] = []; var startCount = 0
let state = ShellIntegration.State(callback: { c, n in received.append((c, n)) })
state.onCommandStarted = { startCount += 1 }

ShellIntegration.handle(data: asBytes("D;0"), state: state)   // 1. D before C → ignored
if !received.isEmpty { fail("D-before-C", "D before any C must be ignored") }

state.commandStartTime = Date()                                // 2. A clears start-time
ShellIntegration.handle(data: asBytes("A"), state: state)
if state.commandStartTime != nil { fail("A-clears-start-time", "A must set commandStartTime nil") }
ShellIntegration.handle(data: asBytes("D;0"), state: state)
if !received.isEmpty { fail("D-after-A-no-C", "D after A without C must be ignored") }

ShellIntegration.handle(data: asBytes("C"), state: state)     // 3. C→D delivers callback
Thread.sleep(forTimeInterval: 0.001)
ShellIntegration.handle(data: asBytes("D;0"), state: state)
if received.count != 1 { fail("C-then-D", "expected 1 callback") }
else if received[0].0 != 0 { fail("C-then-D-exitCode", "expected 0") }
else if received[0].1 == 0 { fail("C-then-D-nanos", "expected nanos > 0") }
received.removeAll()

ShellIntegration.handle(data: asBytes("D;1"), state: state)   // 4. D after D → ignored
if !received.isEmpty { fail("D-after-D", "second D without C must be ignored") }

ShellIntegration.handle(data: asBytes("C"), state: state)     // 5. non-zero exit code
ShellIntegration.handle(data: asBytes("D;127"), state: state)
if received.count != 1 { fail("exit-127-count", "expected 1 callback") }
else if received[0].0 != 127 { fail("exit-127-code", "expected 127") }
received.removeAll()

ShellIntegration.handle(data: asBytes("C"), state: state)     // 6. D with no code → nil
ShellIntegration.handle(data: asBytes("D"), state: state)
if received.count != 1 { fail("D-no-code-count", "expected 1 callback") }
else if received[0].0 != nil { fail("D-no-code-exitCode", "expected nil") }
received.removeAll()

ShellIntegration.handle(data: asBytes("C"), state: state)     // 7. B silently ignored
ShellIntegration.handle(data: asBytes("B"), state: state)
if !received.isEmpty { fail("unknown-byte", "B should be silently ignored") }
ShellIntegration.handle(data: asBytes("D;0"), state: state); received.removeAll()

let priorStart = startCount                                    // 8. C fires onCommandStart
ShellIntegration.handle(data: asBytes("C"), state: state)
if startCount != priorStart + 1 { fail("C-fires-onCommandStart", "expected increment") }
ShellIntegration.handle(data: asBytes("D;0"), state: state); received.removeAll()

let preA = startCount                                          // 9. A does NOT fire it
ShellIntegration.handle(data: asBytes("A"), state: state)
if startCount != preA { fail("A-no-onCommandStart", "A must not fire onCommandStart") }

ShellIntegration.handle(data: asBytes("C"), state: state)     // 10. D does NOT fire it
let preD = startCount
ShellIntegration.handle(data: asBytes("D;0"), state: state)
if startCount != preD { fail("D-no-onCommandStart", "D must not fire onCommandStart") }
received.removeAll()

let legacyState = ShellIntegration.State { _, _ in }           // 11. default no-op compiles
ShellIntegration.handle(data: asBytes("C"), state: legacyState)
ShellIntegration.handle(data: asBytes("D;0"), state: legacyState)

// ── parseOsc7Directory wrapper ────────────────────────────────────────────────
// The wrapper now rejects remote hosts. Local hosts and bare paths still work.
if ShellIntegration.parseOsc7Directory("file://localhost/Users/test") != "/Users/test" {
    fail("osc7-basic", "expected /Users/test") }
if ShellIntegration.parseOsc7Directory("file://localhost/Users/test/caf%C3%A9") != "/Users/test/café" {
    fail("osc7-percent-encoded", "expected /Users/test/café") }
if ShellIntegration.parseOsc7Directory("file://localhost/Users/test/my%20dir") != "/Users/test/my dir" {
    fail("osc7-spaces", "expected /Users/test/my dir") }
if ShellIntegration.parseOsc7Directory("/Users/test") != "/Users/test" {
    fail("osc7-bare-path", "expected /Users/test") }
if ShellIntegration.parseOsc7Directory("Users/test") != nil {
    fail("osc7-relative-path", "expected nil for relative path") }
if ShellIntegration.parseOsc7Directory("") != nil {
    fail("osc7-empty", "expected nil") }
if ShellIntegration.parseOsc7Directory("file://\u{00}/bad") != nil {
    fail("osc7-invalid", "expected nil for invalid URL") }
// Remote host → wrapper must return nil (regression guard: /tmp exists locally)
if ShellIntegration.parseOsc7Directory("file://other-host/tmp") != nil {
    fail("osc7-remote-host", "file://other-host/tmp must return nil (remote host)") }

// ── Osc7Directory.parse ───────────────────────────────────────────────────────
// localHostnames supplied explicitly so the gate is machine-independent.
let locals: Set<String> = ["", "localhost", "mymac", "mymac.local"]

// O1. exact local host match
if Osc7Directory.parse("file://mymac/Users/test", localHostnames: locals) != .local(path: "/Users/test") {
    fail("O1-local-host", "expected .local(/Users/test)") }
// O2. case-insensitive: MyMac vs mymac
if Osc7Directory.parse("file://MyMac/Users/test", localHostnames: locals) != .local(path: "/Users/test") {
    fail("O2-case-insensitive", "expected .local(/Users/test) for MyMac vs mymac") }
// O3. localhost
if Osc7Directory.parse("file://localhost/tmp", localHostnames: locals) != .local(path: "/tmp") {
    fail("O3-localhost", "expected .local(/tmp)") }
// O4. empty authority (file:///path) — no host means local (RFC 8089 §2)
if Osc7Directory.parse("file:///Users/test", localHostnames: locals) != .local(path: "/Users/test") {
    fail("O4-empty-authority", "expected .local(/Users/test) for file:///path") }
// O5. remote host, path that exists locally — decision is on HOST, not path
if Osc7Directory.parse("file://other-host/tmp", localHostnames: locals) != .remote(host: "other-host") {
    fail("O5-remote-host", "expected .remote(other-host) for file://other-host/tmp") }
// O6. prefix of local name is NOT equal → remote
if Osc7Directory.parse("file://myma/tmp", localHostnames: locals) != .remote(host: "myma") {
    fail("O6-prefix-not-equal", "expected .remote(myma) for prefix 'myma' of 'mymac'") }
// O7. local name as prefix of host (host has extra chars) → remote
if Osc7Directory.parse("file://mymac2/tmp", localHostnames: locals) != .remote(host: "mymac2") {
    fail("O7-suffix-not-equal", "expected .remote(mymac2) for 'mymac2' not in set") }
// O8. userinfo in URL → nil
if Osc7Directory.parse("file://user@mymac/tmp", localHostnames: locals) != nil {
    fail("O8-userinfo", "expected nil for URL with userinfo") }
// O9. port in URL → nil
if Osc7Directory.parse("file://mymac:22/tmp", localHostnames: locals) != nil {
    fail("O9-port", "expected nil for URL with port") }
// O10. %2520 single-decode: %2520 → %20 (one pass); double-decode would give space
if Osc7Directory.parse("file://localhost/%2520dir", localHostnames: locals) != .local(path: "/%20dir") {
    fail("O10-single-decode", "expected /%20dir (one decode of %2520)") }
// O11. Unicode path (unencoded — Foundation accepts it)
if Osc7Directory.parse("file://localhost/Users/test/日本語", localHostnames: locals) != .local(path: "/Users/test/日本語") {
    fail("O11-unicode-path", "expected /Users/test/日本語") }
// O12. bare absolute path → local
if Osc7Directory.parse("/Users/test", localHostnames: locals) != .local(path: "/Users/test") {
    fail("O12-bare-path", "expected .local(/Users/test)") }
// O13. relative path → nil
if Osc7Directory.parse("Users/test", localHostnames: locals) != nil {
    fail("O13-relative-path", "expected nil for relative path") }
// O14. empty → nil
if Osc7Directory.parse("", localHostnames: locals) != nil {
    fail("O14-empty", "expected nil") }
// O15. other scheme → nil
if Osc7Directory.parse("https://mymac/path", localHostnames: locals) != nil {
    fail("O15-other-scheme", "expected nil for https://") }

// ── live compatibility: zsh $HOST ─────────────────────────────────────────────
// shell-integration.zsh emits file://$HOST/path; currentLocalHostnames() must
// include zsh's $HOST so the machine's own shell reports a .local result.
do {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", "print -r -- $HOST"]
    let pipe = Pipe(); task.standardOutput = pipe
    task.standardError = Pipe()
    var zshHost: String? = nil
    do {
        try task.run(); task.waitUntilExit()
        if task.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            zshHost = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
        }
    } catch {}
    if let host = zshHost, !host.isEmpty {
        let liveNames = Osc7Directory.currentLocalHostnames()
        let result = Osc7Directory.parse("file://\(host)/tmp", localHostnames: liveNames)
        if result != .local(path: "/tmp") {
            fail("live-zsh-host", "file://\(host)/tmp with currentLocalHostnames() \(liveNames) → \(String(describing: result))")
        } else {
            print("  ok  live-zsh-host: file://\(host)/tmp → .local(/tmp)")
        }
    } else {
        print("  skip live-zsh-host: zsh not available or returned empty $HOST")
    }
}

// ── falsification pin ─────────────────────────────────────────────────────────
var falseCalled = 0
let falseState2 = ShellIntegration.State(callback: { _, _ in falseCalled += 1 })
ShellIntegration.handle(data: asBytes("D;0"), state: falseState2)
if falseCalled != 0 { fail("falsification-pin", "guard removed? D before C fired the callback") }

// ── summary ───────────────────────────────────────────────────────────────────
if bad == 0 {
    print("  ok  parseExitCode (9 cases)")
    print("  ok  OSC 133 state machine (11 cases)")
    print("  ok  parseOsc7Directory wrapper (8 cases including remote→nil)")
    print("  ok  Osc7Directory.parse O1–O15 (local, case, localhost, empty-auth, remote, prefix, suffix, userinfo, port, %2520, unicode, bare, relative, empty, other-scheme)")
    print("  ok  falsification pin")
    print("\nall shell-integration cases passed")
} else {
    print("\n\(bad) shell-integration case(s) FAILED")
}
exit(bad == 0 ? 0 : 1)
