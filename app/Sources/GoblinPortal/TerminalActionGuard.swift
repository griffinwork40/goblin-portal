//
//  TerminalActionGuard.swift
//  One rule, one place: may the focused shell host accept a shell-directed action?
//
//  WHY THIS EXISTS. Four UI entry points send text into the focused terminal
//  without checking what program is in front:
//    · Insert Path in Terminal  (⌥-double-click, context menu)
//    · cd Here                  (context menu)
//    · Send Path to Terminal    (⌘⇧C, menu + palette)
//    · Run in Terminal          (⌘⇧R, menu + palette)
//
//  With agent-afk (or vim, ssh, etc.) in front, cd Here runs `cd` on a remote
//  machine or submits `cd` as a REPL prompt; ⌘⇧R submits `python3 '<path>'` as
//  a prompt. The decision is frozen in `ShellContext.swift`:
//  `TerminalInputPolicy.allowsTyping(into:)` is the one rule. This file wires it
//  to every entry point through a single injectable seam so the gate
//  `check-terminal-actions.sh` can drive the REAL action methods with a
//  test-double foreground reader — without depending on lane C's
//  `TerminalPane+DirectoryState.swift`, which replaces the wave-0 scaffold that
//  currently returns `foreground: nil` and would make every guarded action refuse
//  in the real app until C lands.
//
//  CONTRACT. This struct is the ONE allow-list; no other file adds its own copy.
//  The seam is `foregroundReader`: production code calls `guard.check(host:)`;
//  tests inject a reader that returns any `ForegroundKind?` they like.
//
//  Lane-C dependency note. The wave-0 scaffold in ShellHosting.swift returns
//  `foreground: nil` from `shellContext`, so every guarded action WILL be refused
//  in production until lane C lands. That is expected and correct: nil is
//  fail-closed. The gate drives through a test-double host that sets `foreground`
//  to a controlled value, so the guard logic is fully covered independently of C.
//
//  Re-verification needed after lane C merges:
//  · Run check-terminal-actions.sh against a real TerminalPane with a live shell.
//    Expect `.shell` → allowed, no beep.
//  · Open tmux in a pane and run the four actions: expect allowed.
//  · Run ssh into another host and run the four actions: expect refused + beep.
//

import AppKit

// MARK: - TerminalActionGuard

/// Wraps the one allow-list (`TerminalInputPolicy.allowsTyping(into:)`) with a
/// beep seam so the gate can count beeps without audio hardware.
///
/// `beepSink`: called in place of `NSSound.beep()` when an action is refused.
/// In production this is `NSSound.beep`; in the gate harness it increments a counter.
/// The seam is the function value, not a protocol, because the function is stateless
/// and a protocol here would cost a concrete conformer just to count an integer.
@MainActor
struct TerminalActionGuard {
    /// Called when an action is refused. Default: `NSSound.beep`.
    ///
    /// Injectable so the gate can count refusals without audio hardware. Production
    /// code uses the `production` static instance, which calls `NSSound.beep`.
    var beepSink: () -> Void = { NSSound.beep() }

    /// Read the foreground kind from a shell host's context.
    ///
    /// Injectable so the gate can supply a controlled `ForegroundKind?` via a
    /// test-double host, independently of lane C's `TerminalPane+DirectoryState.swift`.
    /// Production reads `host.shellContext.foreground`; the gate replaces this with
    /// a closure that returns whatever kind the test case needs.
    var foregroundReader: (any ShellHosting) -> ForegroundKind? =
        { host in host.shellContext.foreground }

    /// The shared instance used by all production action entry points.
    ///
    /// Single instance so tests that replace `beepSink` or `foregroundReader` do not
    /// reach into production callers — they construct their own `TerminalActionGuard`
    /// with the injected values and call it directly.
    static var production = TerminalActionGuard()

    /// Returns true and emits no side-effects when `TerminalInputPolicy` allows
    /// typing into the host's foreground program. Returns false and calls `beepSink`
    /// when it refuses.
    ///
    /// Called IMMEDIATELY before sending bytes, even when menu validation already
    /// passed: the foreground can change between menu-open and menu-click, and the
    /// command palette does not call validation before firing.
    ///
    /// DIAG line names the action and the foreground kind so "refused" is not silent.
    @discardableResult
    func check(host: any ShellHosting, action: String) -> Bool {
        let foreground = foregroundReader(host)
        let allowed = TerminalInputPolicy.allowsTyping(into: foreground)
        if !allowed {
            // Diagnostics go behind GOBLIN_PORTAL_DIAG per AFK.md Conventions.
            if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
                let kind = foreground.map { "\($0)" } ?? "nil (unknown)"
                fputs("[goblin-portal] action-guard: refused '\(action)' — foreground is \(kind)\n",
                      stderr)
            }
            beepSink()
        }
        return allowed
    }

    /// Validation-time check: returns true iff `TerminalInputPolicy` would allow
    /// typing into the host's current foreground. Does NOT beep — validation is
    /// called frequently (AppKit polls it while a menu is open) and a beep on every
    /// poll would be cacophonous. Beeping is reserved for the execution-time `check`.
    func validates(host: any ShellHosting) -> Bool {
        let foreground = foregroundReader(host)
        return TerminalInputPolicy.allowsTyping(into: foreground)
    }
}
