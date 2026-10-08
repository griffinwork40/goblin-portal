//
//  FileTreeViewController+Timing.swift
//  GOBLIN_PORTAL_DIAG instrumentation for the file-tree refresh paths.
//
//  Why its own file: `FileTreeViewController.swift` is at 341 LOC and a sibling
//  PR (#181 / issue #176) concurrently edits that file and `+Mutation.swift`.
//  Putting the timing helper here avoids merge conflicts on both and keeps the
//  call sites to one-liners. The 350-LOC ceiling applies to this file too.
//
//  What it measures: wall-clock time around every `root.reloadChildren()` call
//  that is visible to a user — `refresh()` (window-became-key), `setRoot(_:)`
//  (cwd-follow), and `refreshAfterMutation` (every file operation). The output
//  line names the call site, the expanded-directory count, and the elapsed ms.
//
//  COST WHEN OFF: one `ProcessInfo.processInfo.environment` dictionary lookup,
//  performed once at module initialisation and stored in `TreeRefreshTiming.enabled`.
//  Every timed call pays one `Bool` test, taken before `Date()` is ever called.
//  No overhead on production traffic.
//
//  Format (stderr, GOBLIN_PORTAL_DIAG=1):
//    [diag] tree-refresh: site=refresh dirs=12 elapsed=3.4ms
//    [diag] tree-refresh: site=setRoot dirs=0 elapsed=1.1ms
//    [diag] tree-refresh: site=afterMutation dirs=5 elapsed=2.8ms
//

import AppKit

/// One-liner timing wrapper for `FileTreeViewController`'s reload paths.
///
/// Usage:
///     TreeRefreshTiming.measure(site: "refresh", expandedCount: N) { root.reloadChildren() }
///
/// `expandedCount` is passed by the caller because each site already walks the
/// outline's rows to collect expanded items — so the count is free at call time
/// rather than recounted inside this helper.
enum TreeRefreshTiming {
    /// Cached once at launch from the environment — zero allocation on every call.
    static let enabled = ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil

    /// Time `body`, print one `[diag]` line to stderr if DIAG is on.
    static func measure(site: String, expandedCount: Int, body: () -> Void) {
        guard enabled else { body(); return }
        let t0 = Date()
        body()
        let ms = Date().timeIntervalSince(t0) * 1000.0
        let line = String(format: "[diag] tree-refresh: site=%@ dirs=%d elapsed=%.1fms\n",
                          site, expandedCount, ms)
        FileHandle.standardError.write(Data(line.utf8))
    }
}
