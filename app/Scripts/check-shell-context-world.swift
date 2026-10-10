// check-shell-context-world.swift
// The pty world layer 2 of check-shell-context.sh drives: a real TerminalPane in an
// offscreen window, a run-loop pump, and the polling/typing helpers the assertions use.
// Compiled beside check-shell-context-harness.swift (copied to main.swift); never run
// directly. Split from the harness only to keep both under the 350-line ceiling.
//
// Every read goes through the SHIPPED entry points (`TerminalPane.shellContext`,
// `currentDirectory`, `send(text:)`); nothing here re-implements the cwd rule. Polling
// reads `shellContext` every 100 ms WITHOUT calling `refreshDirectoryState()` itself,
// so the tmux cases also prove the getter schedules its own refresh when the cache is
// cold or old (the contract in ShellHosting.swift), which is all a reader can rely on.
//
import AppKit
import SwiftTerm
@testable import GoblinPortal

var bad = 0
func ok(_ m: String) { print("  ✓ \(m)") }
func fail(_ m: String) { print("  ✗ \(m)"); bad += 1 }
func expect(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String) {
    cond ? ok(name) : fail("\(name)   [\(detail())]")
}

let env = ProcessInfo.processInfo.environment
let work = URL(fileURLWithPath: env["GATE_WORK"] ?? "/nonexistent")
let tmuxBin = env["GATE_TMUX"] ?? "/opt/homebrew/bin/tmux"

/// Normalise exactly like the app does (ShellDirectory.swift:78) so comparisons are by
/// the same spelling the readers see.
func norm(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

/// A fresh directory under the gate's work dir, normalised.
func makeDir(_ name: String) -> URL {
    let url = work.appendingPathComponent("dirs/\(name)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return norm(url)
}

/// Pump the main run loop until `done()` or the deadline; true when `done()` held.
@MainActor
func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if done() { return true }
    }
    return done()
}

/// Read `shellContext` every 100 ms (the shape of the 750 ms poller, faster) until
/// `match` holds. Returns the last context read and how many reads it took.
@MainActor
func poll(_ pane: TerminalPane, _ seconds: Double,
          _ match: (ShellContext) -> Bool) -> (ShellContext, Int) {
    var last = pane.shellContext
    var reads = 1
    let deadline = Date().addingTimeInterval(seconds)
    while !match(last) && Date() < deadline {
        _ = pump(0.1)
        last = pane.shellContext
        reads += 1
    }
    return (last, reads)
}

func describe(_ c: ShellContext) -> String {
    "fg=\(c.foreground.map { "\($0)" } ?? "nil") dir=\(c.directory?.path ?? "nil") status=\(c.followStatus)"
}

func isCommand(_ k: ForegroundKind?, _ name: String) -> Bool {
    if case .command(let n)? = k { return n == name }
    return false
}
func isTmux(_ k: ForegroundKind?) -> Bool {
    if case .tmuxClient? = k { return true }
    return false
}
func isRemote(_ k: ForegroundKind?) -> Bool {
    if case .remote? = k { return true }
    return false
}

/// A started pane whose login zsh reads `home/.zshrc`. HOME is the one variable SwiftTerm
/// copies from our environment into the shell's (`Terminal.getEnvironmentVariables`,
/// Terminal.swift:5885), so swapping it before `start()` is how each pane gets its own rc
/// file without touching the user's.
@MainActor
func startPane(home: URL, in directory: URL) -> (TerminalPane, NSWindow)? {
    setenv("HOME", home.path, 1)
    var cfg = AppConfig.defaults()
    cfg.shell = "/bin/zsh"
    let pane = TerminalPane(config: cfg, frame: NSRect(x: 0, y: 0, width: 800, height: 400),
                            workingDirectory: directory)
    let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 400),
                       styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView?.addSubview(pane.view)
    pane.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    win.orderBack(nil)
    pane.start()
    let spawned = pump(10) { (pane.view.process?.shellPid ?? 0) > 0 }
    return spawned ? (pane, win) : nil
}

/// The typing guard as production builds it: a FRESH `TerminalActionGuard()` whose
/// `foregroundReader` is left at its shipped default (`host.shellContext.foreground`),
/// with only `beepSink` swapped for a counter. check-terminal-actions.sh replaces the
/// reader in every case, so this is the one place the default line runs against a real
/// pane (review finding B3, 2026-10-09).
@MainActor
final class DefaultReaderGuard {
    var beeps = 0
    private(set) var guardUnderTest = TerminalActionGuard()
    init() { guardUnderTest.beepSink = { [unowned self] in self.beeps += 1 } }
    /// `check(host:action:)` plus the beep delta it caused.
    func check(_ pane: TerminalPane) -> (allowed: Bool, beeped: Int) {
        let before = beeps
        let allowed = guardUnderTest.check(host: pane, action: "gate")
        return (allowed, beeps - before)
    }
}
