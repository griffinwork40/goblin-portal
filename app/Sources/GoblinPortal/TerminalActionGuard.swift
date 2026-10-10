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
//  to every entry point through a single injectable seam.
//
//  CONTRACT. This struct is the ONE allow-list; no other file adds its own copy.
//  Production code calls `TerminalActionGuard.production.check(host:)`, whose
//  default `foregroundReader` reads the pane's real `shellContext.foreground`
//  (`TerminalPane+DirectoryState.swift`).
//
//  TWO GATES, because each sees half. `check-terminal-actions.sh` drives the four
//  REAL entry points and menu validation, but replaces `production.foregroundReader`
//  in every case so it can dictate the foreground. The DEFAULT reader is therefore
//  exercised by `check-shell-context.sh` layer 2 instead: a fresh
//  `TerminalActionGuard()` with only `beepSink` swapped, against a real pane running
//  a real zsh — allowed at the idle shell, refused (one beep) with a fake `ssh` in
//  front, allowed again after it exits. Its falsify mutant
//  `guard-default-reader-always-shell` (reader → `{ _ in .shell }`) must turn it red
//  (review finding B3, 2026-10-09).
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
    /// Production reads `host.shellContext.foreground` (gated against a real pane by
    /// `check-shell-context.sh`). Injectable so `check-terminal-actions.sh` can dictate
    /// the kind for each case while driving the real entry points.
    var foregroundReader: (any ShellHosting) -> ForegroundKind? =
        { host in host.shellContext.foreground }

    /// The shared instance used by all production action entry points.
    ///
    /// A `var`, not a `let`: the shipped entry points read this instance, so
    /// `check-terminal-actions.sh` swaps its seams in place to drive those entry points.
    /// `check-shell-context.sh` builds a fresh `TerminalActionGuard()` instead, so the
    /// default reader runs untouched.
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
