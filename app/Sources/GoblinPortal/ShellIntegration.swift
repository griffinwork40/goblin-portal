//
//  ShellIntegration.swift
//  OSC 133 parsing and command-lifecycle tracking for the SwiftTerm engine.
//
//  Why it is separate from TerminalPane:
//
//  1. Foundation-only. No AppKit, no SwiftTerm import. That boundary lets
//     `check-shell-integration.sh` compile and gate this file with a plain `swiftc`
//     call, the same trick `CommandOutcome.swift`, `ShellDirectory.swift`, and
//     `Renderer.swift` each use — a pure policy file is a testable policy file.
//
//  2. The `TerminalPane` file sits AT the 350-LOC ceiling (AFK.md, "Conventions")
//     so any new concern must land beside it rather than inside it.
//
//  OSC 133 wire format (FTCS — Final Term Command Sequences):
//    ESC ] 133 ; A ST  — prompt start (precmd, shell about to draw the prompt)
//    ESC ] 133 ; C ST  — command start (preexec, user pressed Return)
//    ESC ] 133 ; D ; <exitcode> ST  — command end, optional exit code
//
//  State machine: idle → commandRunning (on C) → idle (on D).
//  A clears the start-time guard so the first D after sourcing (before any C)
//  does not fabricate a duration.
//
//  The callback signature (exitCode, durationNanos) is kept engine-agnostic so
//  downstream `CommandOutcome.of` logic is shared without modification across
//  any engine path that produces these two values.
//

import Foundation

/// OSC 133 command-lifecycle tracker for the SwiftTerm engine.
///
/// Registers a custom OSC handler via `Terminal.registerOscHandler(code: 133)` —
/// SwiftTerm's public hook at `Terminal.swift:1082` — so zero vendor changes are
/// needed. The parser checks `oscHandlers[code]` BEFORE the built-in switch
/// (`EscapeSequenceParser.swift:513-516`), so the registration is safe and complete.
///
/// This type carries no `@MainActor` annotation and no AppKit import so the gate
/// script compiles it as a standalone module. The caller (`TerminalPane+ShellIntegration`)
/// is `@MainActor`; SwiftTerm invokes all its callbacks on the main thread, so isolation
/// is real at runtime and the annotation is not load-bearing here.
enum ShellIntegration {

    // MARK: - Internal state per registered integration

    /// Mutable state for one pane's OSC 133 session.
    ///
    /// A class so the OSC handler closure captures it by reference — each `register`
    /// call produces an independent `State`, giving each pane its own timeline.
    final class State {
        /// Wall time when the shell last emitted 'C' (command start).
        /// Nil means no command is running — D before any C is a no-op.
        var commandStartTime: Date?

        /// Called with `(exitCode, durationNanos)` when 'D' arrives after a 'C'.
        /// Feeds directly into `CommandOutcome.of`, which is shared across engine paths.
        let callback: (Int?, UInt64) -> Void

        init(callback: @escaping (Int?, UInt64) -> Void) {
            self.callback = callback
        }
    }

    // MARK: - Registration entry point

    /// Wire OSC 133 onto `terminal`, firing `callback(exitCode, durationNanos)` on D.
    ///
    /// - Parameters:
    ///   - terminal: An `OscRegistering` — in production, SwiftTerm's `Terminal`
    ///     (`view.getTerminal()`), conformed in `TerminalPane+ShellIntegration.swift`.
    ///   - callback: Receives `(exitCode: Int?, durationNanos: UInt64)` when a command ends.
    ///
    /// Returns the `State` so `TerminalPane+ShellIntegration` can retain it; the state
    /// must outlive the handler or callbacks arrive into a dead object.
    @discardableResult
    static func register(
        on terminal: OscRegistering,
        callback: @escaping (Int?, UInt64) -> Void
    ) -> State {
        let state = State(callback: callback)
        terminal.registerOscHandler(code: 133) { data in
            ShellIntegration.handle(data: data, state: state)
        }
        return state
    }

    // MARK: - Parser (internal for the gate script)

    /// Dispatch one OSC 133 payload byte-slice.
    ///
    /// `internal` rather than `private` so `check-shell-integration.sh` can call it
    /// directly — the same visibility `ShellDirectory.singleQuoted` uses for its gate.
    static func handle(data: ArraySlice<UInt8>, state: State) {
        guard let first = data.first else { return }

        switch first {
        case UInt8(ascii: "A"):
            // Prompt start. Clear start time so a bare D (before any C) is a no-op.
            // The first precmd after `source shell-integration.zsh` emits A before the
            // user has run any command, and that D must be ignored — there is no
            // command to report.
            state.commandStartTime = nil

        case UInt8(ascii: "C"):
            // Command start — user pressed Return on a non-empty command line.
            state.commandStartTime = Date()

        case UInt8(ascii: "D"):
            // Command end. A D with no preceding C (commandStartTime == nil) is
            // ignored — this guards the first-prompt case described under A above.
            guard let start = state.commandStartTime else { return }
            state.commandStartTime = nil

            let elapsed = Date().timeIntervalSince(start)
            // Duration in nanoseconds. Clamped to 0 — a negative interval
            // cannot be a real duration and would underflow UInt64.
            let nanos = UInt64(max(elapsed, 0) * 1_000_000_000)
            let exitCode = parseExitCode(from: data)
            state.callback(exitCode, nanos)

        default:
            // B (output start) and future codes — silently ignored, not errors.
            break
        }
    }

    /// Extract the integer exit code from a D payload: `D;0` → 0, `D;127` → 127, `D` → nil.
    ///
    /// `internal` for the gate. Non-numeric or missing suffix returns nil — per
    /// `CommandOutcome.swift:65` "no exit code is not evidence of failure".
    static func parseExitCode(from data: ArraySlice<UInt8>) -> Int? {
        guard let semi = data.firstIndex(of: UInt8(ascii: ";")) else { return nil }
        let codeBytes = data[(semi + 1)...]
        guard !codeBytes.isEmpty else { return nil }
        guard let str = String(bytes: codeBytes, encoding: .utf8) else { return nil }
        // Allow a leading '-' for negative exit codes (e.g. signal-killed processes
        // sometimes report -1). Trim trailing junk — OSC 133 D can carry extra fields.
        return Int(str.prefix(while: { $0.isNumber || $0 == "-" }))
    }
}

// MARK: - OSC 7 URL parsing

extension ShellIntegration {

    /// Parse an OSC 7 payload into a normalised POSIX path, or nil for invalid input.
    ///
    /// Accepts two forms:
    ///   • `file://hostname/path` — the wire format emitted by `shell-integration.zsh` and
    ///     returned by SwiftTerm's OSC 7 callback. The hostname component is stripped; only
    ///     the path portion is returned (per RFC 8089 §2, a `file:` URI may carry any host
    ///     for localhost equivalents — the terminal only cares about the path).
    ///   • A bare absolute POSIX path (no scheme) — accepted as a passthrough, so callers
    ///     need not branch on whether SwiftTerm has already decoded the URL. Relative paths
    ///     are rejected (they cannot be valid working directories).
    ///
    /// For `file:` URIs, `.path` returns the already-decoded POSIX path (Foundation
    /// percent-decodes it internally). No second `.removingPercentEncoding` is applied —
    /// that would double-decode directories whose literal names contain `%` sequences.
    /// Empty, nil, and structurally invalid inputs all return nil rather than a partial path.
    ///
    /// Pure Foundation — no AppKit, no SwiftTerm. Compiled by `check-shell-integration.sh`
    /// alongside `ShellIntegration.swift` so the logic is gateable headlessly.
    static func parseOsc7Directory(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }

        let path: String
        if raw.hasPrefix("file://") {
            // `file://hostname/path` — URL(string:) handles the parsing; .path gives
            // the percent-decoded POSIX path. An invalid URL (e.g. stray BEL characters
            // that SwiftTerm has not stripped) returns nil from URL(string:), which we
            // propagate to the caller.
            guard let url = URL(string: raw), !url.path.isEmpty
            else { return nil }
            // .path already percent-decodes (Foundation docs: "the path, unescaped").
            path = url.path
        } else {
            // Bare path (no scheme). Only absolute paths are valid working directories.
            guard raw.hasPrefix("/") else { return nil }
            path = raw
        }

        guard !path.isEmpty else { return nil }
        return path
    }
}

// MARK: - OscRegistering protocol

/// Thin protocol so `ShellIntegration` can call `registerOscHandler` without importing
/// SwiftTerm. Conformed by SwiftTerm's `Terminal` in `TerminalPane+ShellIntegration.swift`.
///
/// Declared here (not in the AppKit extension file) so the protocol name is visible in
/// `ShellIntegration.register(on:callback:)` — the two files form one interface.
/// The gate script exercises `handle` and `parseExitCode` directly and never hits this
/// protocol, so the Foundation-only boundary is maintained end-to-end.
protocol OscRegistering: AnyObject {
    func registerOscHandler(code: Int, handler: @escaping (ArraySlice<UInt8>) -> Void)
}
