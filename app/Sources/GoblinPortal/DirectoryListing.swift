//
//  DirectoryListing.swift
//  Pure-Foundation seam between the file-tree model and FileManager.
//
//  WHY THIS FILE EXISTS
//  `FileNode.reloadChildren()` called `FileManager` directly.
//  Extracting that call behind a replaceable static lister lets the step-3 gate harness
//  inject a controlled stub that blocks, stalls, or returns canned entries — without any
//  changes to FileNode's identity-preservation or sorting logic.
//
//  The seam is a single `var lister: @Sendable (URL) -> [DirectoryEntry]` on the
//  `DirectoryListing` enum.  Replacing it in the harness requires `@testable import
//  GoblinPortal`; the production path never touches it.  The var is read only on the
//  main actor; the closure it holds may be *called* off main (see `lister` below).
//
//  WHAT IT PRESERVES (from the pre-seam `FileNode.reloadChildren()`)
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
/// `URL` + two `Bool`s, so Swift infers `Sendable` and a background listing can hand
/// an array of these back to the main actor with no annotation.
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

    /// The function every directory read goes through instead of FileManager directly.
    ///
    /// The *var* is `@MainActor`: the harness swaps it from the main actor, and every
    /// reader is main-actor code. The *closure value* is `@Sendable` because the async
    /// loaders (`FileTreeViewController+Loading.swift`) read it on main and then CALL it
    /// on a background queue — Swift 6 strict concurrency only lets a closure cross into
    /// `DispatchQueue.global().async` if its type is `@Sendable` (the one exception to
    /// AFK.md's "no Sendable annotations"; it is a compiler requirement, not decoration).
    /// Reading on main and passing the value keeps the seam swappable without making the
    /// var itself `nonisolated(unsafe)`: a listing already in flight keeps the lister it
    /// was issued with, which is what lets a gate stall one call and not the next.
    @MainActor
    static var lister: @Sendable (URL) -> [DirectoryEntry] = { url in DirectoryListing.list(url) }

    // MARK: Production implementation

    /// Read `dir`'s contents and return one `DirectoryEntry` per visible child.
    ///
    /// Does exactly what the pre-seam `FileNode.reloadChildren()` did inline:
    ///   - same FileManager keys (`.isDirectoryKey`, `.isHiddenKey`, no options)
    ///   - URL re-rooted under `dir` to dodge the /private symlink
    ///   - `isHidden` dot-prefix fallback when the resource read fails
    ///   - `isVisible(_:)` filter applied
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
    /// Dotfiles are **kept** (rationale beside the `FileNode.reconcile` sort and the
    /// note at the end of `FileNode`).
    static func isVisible(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name != ".git" && name != ".DS_Store"
    }
}
