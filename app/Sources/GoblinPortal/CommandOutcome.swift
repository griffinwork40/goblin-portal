//
//  CommandOutcome.swift
//  What a finished shell command should do to its tab — the decision, separated from the doing.
//
//  Its own file and Foundation-only, for the reason `Renderer.swift`, `KeyBindings.swift`,
//  `CursorStyle.swift` and `ShellDirectory.swift` are: the interesting part
//  here is a *policy*, policy is a pure function of its inputs, and a pure function can be
//  compiled into a headless check (`check-command-outcome.sh`) while the AppKit half cannot.
//
//  WHY THIS IS NOT `DocumentStatus`. `DocumentStatus` lives in `SpaceDocument.swift`, which
//  declares protocol members typed `NSView` and therefore cannot be compiled without AppKit. A
//  mapping expressed directly in `DocumentStatus` would be untestable for that reason alone. So
//  this enum answers the *question* ("what does this outcome mean?") and the caller does the
//  one-line translation into the *presentation* type. That is the same split
//  `Renderer`/`TerminalPane+Renderer` uses, and the same reason `GitStatus.swift` must stay
//  AppKit-free while `GitStatus+Presentation.swift` holds the colours.
//

import Foundation

/// What to do to a tab when a command inside it finishes.
///
/// Deliberately includes `.ignore` as a first-class case rather than modelling "do nothing" as
/// `nil`. Three of the five branches below are decisions *not* to mark the tab, each for a
/// different reason, and an `Optional` would collapse them into an absence that no check could
/// name.
enum CommandOutcome: Equatable {
    /// The command failed. Mark the tab so a glance finds it.
    case failed
    /// The command succeeded after long enough that the user probably walked away.
    case succeeded
    /// Leave the tab's status exactly as it is.
    case ignore

    /// How long a *successful* command must run before it is worth marking.
    ///
    /// 10 seconds, and the number is doing real work rather than being a round guess. Below it
    /// sits every command whose result the user is still watching for — `ls`, `git status`, `cd`
    /// — and marking those paints a status dot after literally every prompt, which trains the
    /// eye to ignore the dot and takes `.failed` down with it. Above it sits the case the marker
    /// exists for: a build, a test run, an install that finished while attention was elsewhere.
    ///
    /// It is a constant and NOT a config field on purpose. Goblin Portal's config is for decisions a user
    /// must make; this is a default that should be corrected by use, and adding a knob would
    /// freeze a guess into the file format before anyone has lived with it. If daily use says 10s
    /// is wrong, change the constant.
    static let longRunningThreshold: TimeInterval = 10

    /// Decide what a finished command means for its tab.
    ///
    /// - Parameters:
    ///   - exitCode: OSC 133 `D`'s status, or nil when the marker carried none.
    ///   - durationNanos: how long the command ran, in nanoseconds.
    ///   - isActiveDocument: is the user looking at this tab right now?
    static func of(exitCode: Int?, durationNanos: UInt64, isActiveDocument: Bool) -> CommandOutcome {
        // The user is already reading this tab, so they can see the result. A marker here is
        // noise at best and, at worst, teaches the user that the marker means nothing. Same
        // reasoning as the bell guard: the marker's entire job is to label a tab you are NOT
        // looking at.
        if isActiveDocument { return .ignore }

        // No exit code is not evidence of failure. An OSC 133 `D` can arrive without one — a
        // partially-implemented shell integration, or a sequence cut short — and painting a red
        // dot on a tab whose command may well have succeeded is worse than painting nothing.
        guard let exitCode else { return .ignore }

        // Any nonzero exit marks the tab, regardless of how fast it happened. A command that
        // fails in 40ms is precisely the one worth surfacing: it failed before the user could
        // possibly have seen it, and it is often a typo or a missing dependency in a tab they
        // have already looked away from. This asymmetry against the success path is the whole
        // point — failure is rare and interesting, success is constant and mostly boring.
        if exitCode != 0 { return .failed }

        // A fast success is the overwhelmingly common case and says nothing worth interrupting
        // for. A slow one is the "your build finished" signal.
        let seconds = TimeInterval(durationNanos) / 1_000_000_000
        return seconds >= longRunningThreshold ? .succeeded : .ignore
    }
}
