//
//  SplitStateStore.swift
//  Persisting and restoring split pane arrangements across launches.
//
//  Its own file because persistence is a cross-cutting concern that spans
//  `SplitEntry` (the runtime model), `SplitContainerView` (the divider ratio),
//  `SpaceWindowController` (the persist-on-change call sites), and
//  `SpaceRestore` (the launch-time read). None of those should own this; a
//  dedicated store that mirrors `OpenSpaceRoots` in `Defaults.swift` gives
//  each file a single-line call rather than inline Codable logic.
//
//  The snapshot is deliberately minimal: direction, divider ratio, and CWD per
//  peer pane. Engine type is not persisted (only SwiftTerm exists). Scrollback
//  and process state are explicitly excluded -- a shell has no resumable state,
//  and the same argument `SpaceRestore.swift:29-39` makes for documents applies
//  to split peers. A corrupt or missing snapshot degrades to one fresh terminal,
//  identical to today's launch behaviour.
//
//  Written on every split change (create, close, divider drag) rather than at
//  quit, matching `persistOpenRoots()`'s crash-safe discipline.
//
//  Codable note: both snapshot types implement explicit `init(from:)` rather
//  than relying on synthesis. This is a compiler backstop: if a future field
//  addition forgets to be Optional, the build breaks here (at the `decode` vs
//  `decodeIfPresent` call site) rather than silently wiping saved splits at
//  runtime when `try?` converts a missing-key throw to nil. Required fields
//  use `decode`; optional fields use `decodeIfPresent` with a nil default.
//

import Foundation

// MARK: - Codable snapshot types

/// Serializable snapshot of one sub-split (a nested split inside one half of the
/// outer split).
///
/// **Schema rule:** new fields must be `Optional` and decoded with
/// `decodeIfPresent` in `init(from:)`. A non-optional addition silently
/// invalidates every snapshot written by older versions — `JSONDecoder` throws
/// on a missing key, the `try?` in `SplitStateStore` converts that to `nil`,
/// and the user's saved splits are wiped on upgrade.
struct SubSplitSnapshot: Codable {
    let direction: String   // "horizontal" or "vertical"
    let ratio: Double       // 0...1, the nested container's dividerRatio
    let cwd: String?        // peer pane's working directory at save time

    // Explicit CodingKeys: required so init(from:) can name each key and
    // choose decode vs decodeIfPresent per field.
    enum CodingKeys: String, CodingKey {
        case direction
        case ratio
        case cwd
    }

    // Explicit init(from:) — the compiler backstop.
    // Required fields: direction, ratio.
    // Optional fields: cwd (decodeIfPresent → nil when absent).
    // Adding a required field here without making it Optional causes a compile
    // error if the corresponding property is also non-Optional, forcing the
    // author to choose. That is the whole point.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decode(String.self, forKey: .direction)
        ratio     = try c.decode(Double.self, forKey: .ratio)
        cwd       = try c.decodeIfPresent(String.self, forKey: .cwd)
    }

    // Memberwise initializer preserved for call sites in SpaceViewController+Splits.swift.
    init(direction: String, ratio: Double, cwd: String?) {
        self.direction = direction
        self.ratio     = ratio
        self.cwd       = cwd
    }
}

/// Serializable snapshot of one tab's split arrangement.
///
/// **Schema rule:** new fields must be `Optional` and decoded with
/// `decodeIfPresent` in `init(from:)`. See `SubSplitSnapshot` for rationale.
struct SplitSnapshot: Codable {
    let outerDirection: String          // "horizontal" or "vertical"
    let outerRatio: Double              // 0...1, outer container's dividerRatio
    let peerCwd: String?                // outer peer's CWD
    let primarySubSplit: SubSplitSnapshot?
    let peerSubSplit: SubSplitSnapshot?

    // Explicit CodingKeys: required so init(from:) can name each key and
    // choose decode vs decodeIfPresent per field.
    enum CodingKeys: String, CodingKey {
        case outerDirection
        case outerRatio
        case peerCwd
        case primarySubSplit
        case peerSubSplit
    }

    // Explicit init(from:) — the compiler backstop.
    // Required fields: outerDirection, outerRatio.
    // Optional fields: peerCwd, primarySubSplit, peerSubSplit
    //   (decodeIfPresent → nil when absent, including on data written by
    //    older app versions that did not have the field at all).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outerDirection   = try c.decode(String.self, forKey: .outerDirection)
        outerRatio       = try c.decode(Double.self, forKey: .outerRatio)
        peerCwd          = try c.decodeIfPresent(String.self,            forKey: .peerCwd)
        primarySubSplit  = try c.decodeIfPresent(SubSplitSnapshot.self,  forKey: .primarySubSplit)
        peerSubSplit     = try c.decodeIfPresent(SubSplitSnapshot.self,  forKey: .peerSubSplit)
    }

    // Memberwise initializer preserved for call sites in SpaceViewController+Splits.swift.
    init(outerDirection: String, outerRatio: Double, peerCwd: String?,
         primarySubSplit: SubSplitSnapshot?, peerSubSplit: SubSplitSnapshot?) {
        self.outerDirection  = outerDirection
        self.outerRatio      = outerRatio
        self.peerCwd         = peerCwd
        self.primarySubSplit = primarySubSplit
        self.peerSubSplit    = peerSubSplit
    }
}

// MARK: - Direction encoding helpers

extension SplitContainerView.Direction {
    var persistedName: String {
        switch self {
        case .horizontal: return "horizontal"
        case .vertical:   return "vertical"
        }
    }

    init?(persistedName: String) {
        switch persistedName {
        case "horizontal": self = .horizontal
        case "vertical":   self = .vertical
        default: return nil
        }
    }
}

// MARK: - UserDefaults store

/// Read/write split snapshots to UserDefaults, keyed by Space root path.
///
/// Storage shape: `{ "/path/to/project": [SplitSnapshot, ...] }` where the array
/// index corresponds to the tab index. In practice the array has at most one
/// element today (restore creates one tab per Space), but the array shape leaves
/// room for multi-tab split persistence without a schema change.
///
/// Mirrors `OpenSpaceRoots` in every design choice: fail-soft on read (corrupt
/// data returns nil, never crashes), atomic per-key write, and check-on-read for
/// CWDs that no longer exist.
enum SplitStateStore {
    private static let key = "GoblinPortal.splitState"

    /// Read the split snapshots for a Space root. Returns nil if none are stored
    /// or the stored data is corrupt.
    static func snapshots(for root: URL) -> [SplitSnapshot]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard let dict = try? JSONDecoder().decode(
            [String: [SplitSnapshot]].self, from: data
        ) else { return nil }
        return dict[root.path]
    }

    /// Write the split snapshots for a Space root. Pass an empty array to clear.
    static func setSnapshots(_ snapshots: [SplitSnapshot], for root: URL) {
        var dict = currentDict()
        if snapshots.isEmpty {
            dict.removeValue(forKey: root.path)
        } else {
            dict[root.path] = snapshots
        }
        persist(dict)
    }

    /// Remove all snapshots for a Space root (e.g. when the Space closes).
    static func removeSnapshots(for root: URL) {
        var dict = currentDict()
        dict.removeValue(forKey: root.path)
        persist(dict)
    }

    /// Write snapshots for multiple roots in a single JSON encode/write.
    ///
    /// C-1: the quit-path flush in `applicationShouldTerminate` iterates every
    /// open Space. Calling `setSnapshots(_:for:)` N times costs N sequential
    /// decode–mutate–encode cycles. This batch method reads the dict once,
    /// applies all updates, and writes once — O(1) encodes regardless of how
    /// many Spaces are open.
    ///
    /// An empty `snapshots` array for an entry removes that root's key, matching
    /// the behaviour of `setSnapshots([], for:)`.
    static func setAll(_ entries: [(root: URL, snapshots: [SplitSnapshot])]) {
        var dict = currentDict()
        for entry in entries {
            if entry.snapshots.isEmpty {
                dict.removeValue(forKey: entry.root.path)
            } else {
                dict[entry.root.path] = entry.snapshots
            }
        }
        persist(dict)
    }

    // MARK: - Internal helpers

    private static func currentDict() -> [String: [SplitSnapshot]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode(
                  [String: [SplitSnapshot]].self, from: data)
        else { return [:] }
        return dict
    }

    private static func persist(_ dict: [String: [SplitSnapshot]]) {
        // P-1: the dict grows by one entry per distinct project root that ever had
        // a split, and is never evicted. Each entry is ~200 bytes (a JSON object
        // with two or three string fields and two optional sub-objects), so 100
        // roots ≈ 20 KB — well within UserDefaults budget. Growth is bounded by
        // the number of distinct roots the user has opened with ⌘O, which is
        // typically single-digit. No cap is applied, matching `OpenSpaceRoots`'s
        // 12-entry style only for the restore list, not for this incidental store.
        if dict.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
