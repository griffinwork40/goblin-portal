//
//  SessionHighlightPolicy.swift
//  Pure, view-free session-highlight accumulation logic.
//
//  Foundation-only on purpose — no AppKit, no SwiftTerm — so
//  `Scripts/check-session-highlight.sh` can compile this one file directly with
//  `swiftc` and run a truth table over it, the same trick `AgentActivityPolicy.swift`
//  plays for `check-agent-activity.sh`. The concern: given a stream of git-status
//  snapshots, which repo-relative paths has this session ever seen dirty?
//
//  The store is a value type owned by `SpaceViewController+SessionHighlight.swift`
//  at runtime. This file provides the pure accumulation function the AppKit layer
//  calls, and nothing else — no rendering, no lifecycle, no menu wiring.
//
//  WHY ON SpaceViewController, NOT ON GitStatusFollow. The poller has an explicit,
//  documented invariant: "THE SNAPSHOT IS THE ONLY COPY, AND THAT IS THE DESIGN"
//  (FileTreeViewController+Git.swift:11). Accumulating a Set on the poller is exactly
//  the incremental-cache pattern the design document rejected — a second store derived
//  from the snapshot that has to be invalidated in step with the first. The correct
//  owner is one level up: `SpaceViewController`, which already owns the single-fanout
//  point (`updateSourceControl`) and all session-lifecycle concepts.
//

import Foundation

/// Accumulates the union of dirty paths across git-status snapshots, with
/// pre-session baseline suppression.
///
/// Value type — the owner replaces it on mutation via a reference-typed box.
/// No concurrency concern: all callers are `@MainActor`.
struct SessionHighlightStore {
    /// Every repo-relative path that appeared in any snapshot's `entries.keys` since
    /// tracking began. Grows monotonically; never shrinks except on `reset()`.
    private(set) var accumulatedPaths: Set<String> = []

    /// Paths that were already dirty when tracking started. Subtracted from the
    /// effective set so pre-existing dirt does not read as "this session touched it."
    /// Nil until the first snapshot arrives; captured exactly once per lifetime.
    private(set) var baselinePaths: Set<String>?

    /// Whether at least one snapshot has been accumulated.
    var hasStarted: Bool { baselinePaths != nil }

    /// Accumulate the current snapshot's dirty paths.
    ///
    /// On the first call, captures the baseline — the paths already dirty before this
    /// session began. On every call (including the first), unions the current keys
    /// into the accumulated set. The baseline is the FIRST snapshot's keys, not the
    /// keys at an arbitrary "session start" trigger, because the poller may already
    /// have ticked several times before the user starts working.
    mutating func accumulate(entryKeys: Set<String>) {
        if baselinePaths == nil {
            baselinePaths = entryKeys
        }
        accumulatedPaths.formUnion(entryKeys)
    }

    /// The paths this session touched, excluding the pre-session baseline.
    ///
    /// A file that was dirty before the session started and remains dirty is
    /// suppressed — a false negative, never a false positive. A file that was clean,
    /// became dirty during the session, and was then committed survives in the
    /// accumulated set even though git no longer reports it, which is the whole point
    /// of union accumulation over SHA-based diffing.
    var effectivePaths: Set<String> {
        guard let baseline = baselinePaths else { return [] }
        return accumulatedPaths.subtracting(baseline)
    }

    /// Clear all accumulated state. Called on explicit user action.
    mutating func reset() {
        accumulatedPaths = []
        baselinePaths = nil
    }
}
