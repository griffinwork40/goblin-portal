//
//  DirectoryListing.swift
//  Pure-Foundation seam between the file-tree model and FileManager.
//
//  WHY THIS FILE EXISTS
//  `FileNode.reloadChildren()` (FileNode.swift:63-102) called `FileManager` directly.
//  Extracting that call behind a replaceable static lister lets the step-3 gate harness
//  inject a controlled stub that blocks, stalls, or returns canned entries — without any
//  changes to FileNode's identity-preservation or sorting logic.
//
//  The seam is a single `var lister: (URL) -> [DirectoryEntry]` on the `DirectoryListing`
//  enum.  Replacing it in the harness requires `@testable import GoblinPortal`; the
//  production path never touches it.  No `nonisolated(unsafe)` is needed because the
//  lister is accessed only from `FileNode.reloadChildren()`, which is itself
//  `@MainActor` — all reads and writes happen on the main actor.
//
//  WHAT IT PRESERVES (FileNode.swift:74-81, FileNode.swift:85-102)
//  1. Same FileManager keys: `.isDirectoryKey`, `.isHiddenKey`, no options mask.
//  2. URL re-rooting: every returned URL is expressed as
//     `parent.appendingPathComponent(child.lastPathComponent)` so the /private
//     symlink trap never affects callers.
//  3. `isVisible` filter: `.git` and `.DS_Store` are dropped here, same as before.
//  4. Dot-prefix fallback for `isHidden` when a resource read fails.
//

import Foundation

// MARK: - DirectoryEntry

/// A single filesystem entry returned by `DirectoryListing.list(_:)`.
///
/// Value type: copying one is cheap and lets the harness build stub responses freely.
struct DirectoryEntry {
    let url: URL          // re-rooted under the parent's path prefix
    let isDirectory: Bool
    let isHidden: Bool
}

// MARK: - DirectoryListing

/// Namespace for the listing seam.
///
/// `lister` is the single replaceable point.  Production code never replaces it;
/// test harnesses swap it before driving the controller, then restore the original
/// after each case.
enum DirectoryListing {

    // MARK: Seam

    /// The function that `FileNode.reloadChildren()` calls instead of FileManager directly.
    ///
    /// The var is `@MainActor`-isolated so replacing it from the main-actor harness
    /// requires no additional annotation.  All callers (`reloadChildren`) are already
    /// `@MainActor`.  The closure type is plain `(URL) -> [DirectoryEntry]` — NOT
    /// `@MainActor (URL) -> [DirectoryEntry]` — because Swift 6 does not allow
    /// assigning a `@MainActor @Sendable` function reference to an annotated function
    /// type without an explicit `@Sendable` bridge.  Isolation is enforced by the var's
    /// own `@MainActor` attribute: only main-actor code can read or write it.
    @MainActor
    static var lister: (URL) -> [DirectoryEntry] = { url in DirectoryListing.list(url) }

    // MARK: Production implementation

    /// Read `dir`'s contents and return one `DirectoryEntry` per visible child.
    ///
    /// Mirrors `FileNode.reloadChildren()` exactly:
    ///   - same FileManager keys (FileNode.swift:69-73)
    ///   - URL re-rooted under `dir` to dodge the /private symlink (FileNode.swift:74-81)
    ///   - `isHidden` dot-prefix fallback (FileNode.swift:91-94)
    ///   - `isVisible` filter applied (FileNode.swift:85, FileNode.swift:130-133)
    static func list(_ dir: URL) -> [DirectoryEntry] {
        let raw =
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [])) ?? []

        return raw.compactMap { child -> DirectoryEntry? in
            // Re-root: use the caller's path prefix, not FileManager's resolved path.
            let normURL = dir.appendingPathComponent(child.lastPathComponent)
            guard isVisible(normURL) else { return nil }

            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            let isDir = values?.isDirectory ?? false
            let hidden = values?.isHidden ?? child.lastPathComponent.hasPrefix(".")
            return DirectoryEntry(url: normURL, isDirectory: isDir, isHidden: hidden)
        }
    }

    // MARK: Visibility filter

    /// Drop the two entries nobody wants to browse in a developer tree.
    ///
    /// Dotfiles are **kept** (see FileNode.swift:128-133 for the rationale).
    static func isVisible(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name != ".git" && name != ".DS_Store"
    }
}
