//
//  AgentActivityPolicy.swift
//  Output-activity heuristic for interactive CLI tabs.
//
//  Pure and view-free — Foundation only — so `check-agent-activity.sh` can compile
//  it alone.
//
//  WHY THIS EXISTS.  An afk REPL session sits in the foreground continuously as
//  ForegroundKind.command("afk").  The existing OSC 133 C/D state machine tracks
//  shell commands — things that run and return to a prompt.  afk has no shell
//  prompt in the FTCS sense; the terminal cannot distinguish "running tools" from
//  "waiting for input" without additional signal.  This policy bridges the gap
//  with a heuristic: output within the last N seconds = working, silence beyond
//  N seconds = idle.
//
//  Works for any long-running interactive CLI (python, node, irb, julia) — not
//  just afk.  Zero coupling to any specific program.
//
//  Gated by check-agent-activity.sh.
//

import Foundation

/// Whether a foreground command is actively producing output.
enum OutputActivity: Equatable {
    /// Output was received within the silence threshold — the command is working.
    case active
    /// No output for longer than the threshold while a command is still in front.
    case silent
    /// Not applicable: foreground is a shell (not a command), or no foreground.
    case notApplicable
}

/// Output-activity heuristic for interactive CLI tabs.
///
/// The policy is a pure function of two inputs: whether the foreground process is
/// a long-running command (not a shell), and how long ago the terminal last drew
/// new content.  It maps to `DocumentStatus` in the caller, never here — this file
/// is Foundation-only.
enum AgentActivityPolicy {

    /// How long a command must be silent before the tab drops its running indicator.
    ///
    /// 3 seconds: afk prints progress during tool calls and goes silent while
    /// waiting for input.  Below 3 s sits normal inter-line output cadence (a build
    /// that emits a line per file at ~1/s); above it sits "the program is waiting
    /// for something external" — user input, a slow network call, a stalled
    /// subprocess.  The value is a constant, not a config field, for the same reason
    /// `CommandOutcome.longRunningThreshold` is: it should be corrected by use, not
    /// frozen into the file format before anyone has lived with it.
    static let silenceThreshold: TimeInterval = 3.0

    /// Derive output-activity state from foreground kind and time since last output.
    ///
    /// - Parameters:
    ///   - isCommand: true when the foreground is `.command` (not `.shell`,
    ///     `.knownShell`, `.tmuxClient`, `.remote`, `.otherMultiplexer`).
    ///   - secondsSinceLastOutput: elapsed seconds since the terminal last drew
    ///     new content, or nil if no output has been observed yet.
    /// - Returns: the derived activity state.
    static func activity(
        isCommand: Bool,
        secondsSinceLastOutput: TimeInterval?
    ) -> OutputActivity {
        guard isCommand else { return .notApplicable }
        guard let elapsed = secondsSinceLastOutput else { return .silent }
        return elapsed <= silenceThreshold ? .active : .silent
    }
}
