//
//  FileTreeViewController+Timing.swift
//  GOBLIN_PORTAL_DIAG instrumentation for the file-tree refresh paths.
//
//  Why its own file: `FileTreeViewController.swift` is at the 350-LOC ceiling and
//  a sibling PR (#181 / issue #176) concurrently edits that file and `+Mutation.swift`.
//  Putting the timing helper here avoids merge conflicts on both and keeps the
//  call sites to one-liners. The 350-LOC ceiling applies to this file too.
//
//  What it measures — main-thread time unless the site name ends in `-list`:
//    afterMutation        `refreshAfterMutation` (+Mutation.swift), the whole body:
//                         rebase walk, `refreshSynchronously()`, expansion replay,
//                         reveal. dirs= expanded rows before the mutation.
//    refreshSync          `refreshSynchronously()`: re-list on main + reloadData +
//                         restore. dirs= expanded rows. Nested inside afterMutation's span.
//    refreshSync-adopt    `refreshSynchronously()` mid-setRoot: list the new root on
//                         main and adopt it (+Loading.swift `adoptRoot()`). dirs=0.
//    refresh              an async refresh landing (+Loading.swift `land`): issue half
//                         + reconcile + reloadData + restore. dirs= expanded rows restored.
//    setRoot-adopt /      a landing that adopts a new root while the old tree is still on
//    refresh-adopt        screen: issue half + reconcile + one reloadData + queued reveal.
//                         dirs=0. Every setRoot landing takes this form; refresh-adopt is
//                         a refresh issued mid-setRoot. (No bare `setRoot` line any more.)
//    refresh-list /       the OFF-MAIN listing of an async load; never a stall.
//    setRoot-list         dirs= directories listed.
//
//  COST WHEN OFF: one `ProcessInfo.processInfo.environment` dictionary lookup,
//  stored in `TreeRefreshTiming.enabled` at first access (static let is lazy).
//  Every timed call pays one `Bool` test, before any clock read. No overhead on
//  production traffic.
//
//  Format (stderr, GOBLIN_PORTAL_DIAG=1):
//    [diag] tree-refresh: site=refresh-list dirs=12 elapsed=3.1ms
//    [diag] tree-refresh: site=refresh dirs=11 elapsed=1.4ms
//    [diag] tree-refresh: site=setRoot-adopt dirs=0 elapsed=0.9ms
//    [diag] tree-refresh: site=afterMutation dirs=5 elapsed=2.8ms
//    [diag] tree-refresh: site=refresh dropped (stale)
//    [diag] tree-refresh: site=refreshSync deferred (inline edit active)
//

import Foundation

/// One-liner timing wrapper for `FileTreeViewController`'s reload paths.
///
/// Usage:
///     TreeRefreshTiming.measure(site: "refreshSync", expandedCount: N) { … }
///
/// `expandedCount` is passed by the caller because each site already walks the
/// outline's rows to collect expanded items — so the count is free at call time
/// rather than recounted inside this helper.
@MainActor
enum TreeRefreshTiming {
    /// Cached at first access — zero allocation on every subsequent call.
    static let enabled = ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil

    /// Time `body`, print one `[diag]` line to stderr if DIAG is on.
    ///
    /// Pass `deferred: true` when `refresh()` returns early because an inline edit is
    /// active — the elapsed time would be ~0 ms and mislead a reader of the log.
    static func measure(site: String, expandedCount: Int, deferred: Bool = false, body: () -> Void) {
        guard enabled else { body(); return }
        if deferred {
            let line = "[diag] tree-refresh: site=\(site) deferred (inline edit active)\n"
            FileHandle.standardError.write(Data(line.utf8))
            body()
            return
        }
        let t0 = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - t0
        let ms = Double(elapsed.components.seconds) * 1_000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        let line = "[diag] tree-refresh: site=\(site) dirs=\(expandedCount) elapsed=\(String(format: "%.1f", ms))ms\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// The async loaders (`+Loading.swift`) cannot wrap one closure: their main-thread
    /// work is split across an issue and a landing, with the listing off-main between.
    /// They time each part themselves and log it here. `site` is `refresh`/`setRoot`
    /// for main-thread time and `refresh-list`/`setRoot-list` for the off-main listing,
    /// so a log reader never mistakes background time for a main-thread stall.
    static func record(site: String, expandedCount: Int, ms: Double) {
        guard enabled else { return }
        let line = "[diag] tree-refresh: site=\(site) dirs=\(expandedCount) elapsed=\(String(format: "%.1f", ms))ms\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// A landing that did not apply: `dropped (stale)` or `deferred (inline edit active)`.
    static func note(site: String, _ what: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[diag] tree-refresh: site=\(site) \(what)\n".utf8))
    }

    /// Milliseconds since `start`. `nonisolated` because the background listing calls it.
    nonisolated static func ms(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
    }
}
