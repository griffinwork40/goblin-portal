//
//  FileTreeViewController+Timing.swift
//  GOBLIN_PORTAL_DIAG instrumentation for the file-tree refresh paths.
//
//  Why its own file: `FileTreeViewController.swift` is at the 350-LOC ceiling and
//  a sibling PR (#181 / issue #176) concurrently edits that file and `+Mutation.swift`.
//  Putting the timing helper here avoids merge conflicts on both and keeps the
//  call sites to one-liners. The 350-LOC ceiling applies to this file too.
//
//  What it measures: wall-clock time around `root.reloadChildren()` in the three
//  instrumented reload paths — `refresh()` (window-became-key), `setRoot(_:)`
//  (cwd-follow), and `refreshAfterMutation` (every file operation). The output
//  line names the call site, the expanded-directory count, and the elapsed ms.
//
//  COST WHEN OFF: one `ProcessInfo.processInfo.environment` dictionary lookup,
//  stored in `TreeRefreshTiming.enabled` at first access (static let is lazy).
//  Every timed call pays one `Bool` test, before any clock read. No overhead on
//  production traffic.
//
//  Format (stderr, GOBLIN_PORTAL_DIAG=1):
//    [diag] tree-refresh: site=refresh dirs=12 elapsed=3.4ms
//    [diag] tree-refresh: site=setRoot dirs=0 elapsed=1.1ms
//    [diag] tree-refresh: site=afterMutation dirs=5 elapsed=2.8ms
//    [diag] tree-refresh: site=afterMutation deferred (inline edit active)
//

import Foundation

/// One-liner timing wrapper for `FileTreeViewController`'s reload paths.
///
/// Usage:
///     TreeRefreshTiming.measure(site: "refresh", expandedCount: N) { root.reloadChildren() }
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
}
