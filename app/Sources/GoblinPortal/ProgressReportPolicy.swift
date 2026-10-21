// ProgressReportPolicy.swift
// Foundation-only OSC 9;4 state machine per document + multi-document aggregation
// for the single Dock tile.  Compiled standalone by check-progress-report.sh.
//
// Why a separate file
// -------------------
// The decision logic (per-pane state, staleness, aggregation) must be testable
// headlessly — no AppKit, no SwiftTerm.  The same pattern as DockAttention.swift
// and ShellExitPolicy.swift: a Foundation-only policy type + a thin AppKit wiring
// file beside it.  Splitting the two files keeps the gate cheap and the
// AppKit-side thin.
//
// Design decisions (justified here so the gate can grep them)
// -----------------------------------------------------------
//
// STATE MACHINE (per pane):
//   remove(0)       → .none        (programme cleared progress explicitly)
//   set(1, 0–100)   → .determinate(pct)
//   error(2)        → .error
//   indeterminate(3)→ .indeterminate
//   paused(4)       → .paused(pct)   (last-known pct remembered)
//   shell exit      → .none          (OSC 133 D or TerminalPane.shellDidExit)
//   OSC 133 D       → .none          (command-finished clears — same as WT clears on
//                                     process death; covers the "died without 9;4;0"
//                                     class entirely for shell-integration users)
//   staleness timer → .none after 90s without an update (belt-and-suspenders for
//                     programs that die without shell integration and without 9;4;0;
//                     Windows Terminal uses ~90 s; we match that floor)
//
// AGGREGATION (N panes → one Dock tile):
//   • All .none → hide Dock progress
//   • Any .error → show error (error dominates; draws attention to a failure)
//   • Otherwise, any .indeterminate → show indeterminate (exact pct unknown)
//   • All determinate or paused (at least one determinate) → mean of pct values;
//     state = paused when all non-none are paused, else normal
//   • All paused (no determinate) → show paused at mean pct
//
// TAB RENDERING (see ProgressReportTabDrawing.swift):
//   A 2pt bar along the BOTTOM of the pill, inside the accent-line slot, coloured
//   by state.  Lives below the 2pt accent line — the accent line marks "active tab"
//   horizontally; the progress bar fills a 2pt band proportionally.  Hidden when
//   .none, full-width for indeterminate (animated by the drawing layer with a CA
//   shimmer), full-width red for error, proportional yellow for paused.
//   On the inactive tab the bar is drawn at 0.7 opacity so it reads against the
//   dimmed rail without demanding the eye.  The bar shares the bottom 2pt strip with
//   the accent line on the ACTIVE tab — accent line is the background, bar is drawn
//   on top at its proportional width.  At the 56pt minTabWidth the bar is still
//   legible (proportional width of a 56pt pill at 50% = 28pt).
//   VoiceOver: the tab's AX label gains ", progress N%" (determinate) or
//   ", indeterminate progress" / ", paused N%" / ", error" appended by the
//   accessibility layer in DocumentTabStrip+Accessibility.swift.
//
// DOCK TILE:
//   NSDockTile has a `badgeLabel` for the attention badge (kept) and accepts a
//   custom `contentView` for graphics.  badgeLabel and a custom contentView coexist:
//   Apple's own NSApplicationDockTilePlugin docs show this; in practice the badge
//   is drawn by the system over the tile and the contentView is underneath it.
//   ProgressReportDockTile.swift installs a custom contentView only while progress
//   is active, and restores contentView = nil when all progress is .none, letting
//   the system draw the normal icon again.  The attention badge is managed
//   independently by AppDelegate+DockAttention.swift and is unaffected.
//
import Foundation

// MARK: - Per-pane progress state

/// The progress state a single terminal pane is in, as decoded from OSC 9;4.
///
/// Ordered by how loudly each state should draw the eye in aggregation:
/// .error dominates, then indeterminate (unknown), then determinate/paused, then none.
public enum ProgressState: Equatable {
    case none
    case determinate(Int)   // 0…100
    case indeterminate
    case error
    case paused(Int)        // last-known pct, 0…100
}

// MARK: - Policy

/// Foundation-only state machine for a single pane's OSC 9;4 progress.
///
/// Callers must use the mutating `apply(_:)` entry point and then read `state`.
/// Staleness is enforced by `applyTimeout()` — the AppKit layer must call it
/// after `stalenessInterval` has elapsed since the last `apply` call.
public struct ProgressPanePolicy: Equatable {

    /// After this many seconds with no OSC 9;4 update, progress is cleared.
    /// Matches Windows Terminal's ~90 s implicit staleness window.
    public static let stalenessInterval: TimeInterval = 90

    public private(set) var state: ProgressState = .none
    /// Monotonic timestamp of the last `apply` that set a non-.none state.
    public private(set) var lastUpdateDate: Date? = nil

    public init() {}

    // MARK: OSC 9;4 input

    /// Apply an OSC 9;4 payload.  `stateCode` and `progress` are the two numeric
    /// fields decoded by the caller from `4;<state>;<pct>` (pct absent → 0).
    ///
    /// - Parameter stateCode: 0=remove, 1=set, 2=error, 3=indeterminate, 4=paused
    /// - Parameter progress: 0…100 (clamped); only meaningful for codes 1 and 4
    @discardableResult
    public mutating func apply(stateCode: Int, progress: Int) -> ProgressState {
        let pct = min(max(progress, 0), 100)
        switch stateCode {
        case 0:
            state = .none
            lastUpdateDate = nil
        case 1:
            state = .determinate(pct)
            lastUpdateDate = Date()
        case 2:
            state = .error
            lastUpdateDate = Date()
        case 3:
            state = .indeterminate
            lastUpdateDate = Date()
        case 4:
            state = .paused(pct)
            lastUpdateDate = Date()
        default:
            // Unknown code: treat as remove (conservative).
            state = .none
            lastUpdateDate = nil
        }
        return state
    }

    /// OSC 133 D fired (command finished) or shell exited — clear progress.
    /// This is the primary staleness defence for shell-integration users:
    /// a command that dies without sending 9;4;0 is cleared at the next prompt.
    public mutating func commandFinished() {
        state = .none
        lastUpdateDate = nil
    }

    /// Called by the AppKit layer after `stalenessInterval` has elapsed without
    /// an update — belt-and-suspenders for programs without shell integration.
    public mutating func applyTimeout() {
        state = .none
        lastUpdateDate = nil
    }

    // MARK: Aggregation helper

    /// Whether this pane has non-idle progress that should contribute to the
    /// Dock tile.
    public var isActive: Bool { state != .none }
}

// MARK: - Aggregation

/// Aggregate N pane states into a single representation for the Dock tile.
///
/// Rules (see "AGGREGATION" in the file header):
///   1. All none → hide
///   2. Any error → error
///   3. Any indeterminate → indeterminate
///   4. All determinate/paused → mean pct; paused iff all non-none are paused
public enum ProgressAggregation: Equatable {
    case hidden
    case determinate(Int)   // 0…100 mean
    case indeterminate
    case error
    case paused(Int)        // mean pct

    /// Compute the aggregate for a collection of per-pane states.
    public static func of(_ states: [ProgressState]) -> ProgressAggregation {
        let active = states.filter { $0 != .none }
        guard !active.isEmpty else { return .hidden }

        // Error dominates.
        if active.contains(.error) { return .error }

        // Indeterminate next: we don't know the true pct.
        if active.contains(.indeterminate) { return .indeterminate }

        // All remaining are .determinate or .paused.
        var pcts: [Int] = []
        var allPaused = true
        for s in active {
            switch s {
            case .determinate(let p):
                pcts.append(p)
                allPaused = false
            case .paused(let p):
                pcts.append(p)
            default:
                break
            }
        }
        guard !pcts.isEmpty else { return .hidden }
        let mean = pcts.reduce(0, +) / pcts.count
        return allPaused ? .paused(mean) : .determinate(mean)
    }
}

// MARK: - OSC 9;4 payload parser (Foundation-only)

/// Parse the bytes after `9;4` in an OSC 9;4 sequence.
/// Input: the raw OSC data slice (everything after the leading `4;`).
/// Returns `(stateCode, progress)` or nil for malformed input.
public enum ProgressPayload {
    public static func parse(_ data: ArraySlice<UInt8>) -> (stateCode: Int, progress: Int)? {
        // Format: <state>[;<pct>]
        // Both fields are ASCII decimal integers; pct is optional (absent = 0).
        guard let str = String(bytes: data, encoding: .utf8) else { return nil }
        let parts = str.split(separator: ";", maxSplits: 1)
        guard let stateCode = parts.first.flatMap({ Int($0) }) else { return nil }
        let pct = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return (stateCode, pct)
    }
}
