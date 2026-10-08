//
//  FileOperationPolicy.swift
//  Foundation-only filesystem operations for the file tree.
//
//  No AppKit import — the *decision* layer (name validation, collision naming,
//  case-only rename detection, descendant-cycle checks, filesystem calls) is a
//  pure collection of functions with no UI dependency. Everything here compiles
//  headless with `swiftc -typecheck`, and `check-file-ops.sh` gates it that way.
//
//  All functions are called from `FileTreeViewController+FileOps.swift` on the
//  main actor; none of them need to be `@MainActor` themselves because they are
//  pure (validation) or blocking-synchronous (FileManager ops called on the
//  main actor from AppKit). The caller is responsible for actor isolation.
//
//  WHY AN ENUM. A caseless enum is a Swift idiom for a namespace: it cannot be
//  instantiated (no `FileOperationPolicy()` call), which makes the API surface
//  clear ("these are functions, not a service object") and prevents accidental
//  storage. Every member is `static`, so import is never needed — callers write
//  `FileOperationPolicy.isValidName(x)`.
//

import Foundation

enum FileOperationPolicy {

    // MARK: - Name Validation

    /// Returns `true` if `name` is a valid filesystem entry name.
    ///
    /// Rejects:
    /// - empty string
    /// - a single dot (`.`) — would alias the directory itself
    /// - double dot (`..`) — would escape the directory
    /// - names containing `/` — the path separator
    /// - names containing NUL (`\0`) — POSIX null terminator
    ///
    /// The function does NOT check whether the name already exists at a given
    /// path (use `isNameTaken` for that).
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard name != "." && name != ".." else { return false }
        guard !name.contains("/") else { return false }
        guard !name.contains("\0") else { return false }
        return true
    }

    // MARK: - Volume Case-sensitivity Query

    /// `true` when the volume that hosts `url` distinguishes letter case in
    /// file names — i.e. "Foo" and "foo" can coexist as two entries.
    ///
    /// Default APFS / HFS+ volumes are case-INSENSITIVE; only explicitly
    /// formatted "Case-sensitive APFS" or "Case-sensitive HFS+" volumes
    /// return `true`. When the query fails, `false` is the safe default:
    /// the caller then does case-insensitive matching, which is correct for
    /// the common case and merely over-cautious on a rare CS volume.
    ///
    /// Called from `FileTreeViewController` when walking or revealing a node.
    /// Factored here (Foundation-only) so the gate script (`check-file-ops.sh`)
    /// can exercise it standalone and both call sites share the same
    /// implementation rather than copy-pasting a 9-line closure (R1.2).
    static func caseSensitiveFSAtRoot(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))
            .flatMap(\.volumeSupportsCaseSensitiveNames) ?? false
    }

    // MARK: - Case-only Rename Detection

    /// `true` when `from.lastPathComponent` and `to.lastPathComponent` differ
    /// only by letter case — e.g. "readme.md" → "README.md".
    ///
    /// Case-only renames require a two-step atomic move on APFS (and HFS+) because
    /// the filesystem treats the source and destination as the *same* inode when
    /// both spellings normalise to the same name. A direct `moveItem(at:to:)` call
    /// either no-ops or raises an error depending on the OS version. See `rename(from:to:)`.
    ///
    /// Both URLs must share the same parent directory; this function only inspects
    /// the last path component, not the full path.
    static func isCaseOnlyRename(from: URL, to: URL) -> Bool {
        let a = from.lastPathComponent
        let b = to.lastPathComponent
        // Must differ (otherwise it is not a rename at all) and compare equal
        // case-insensitively (otherwise it is a real name change, not just casing).
        return a != b && a.lowercased() == b.lowercased()
    }

    // MARK: - Collision-safe Naming

    /// `true` when a sibling of `directory` already answers to `name`, compared
    /// case-insensitively (APFS / HFS+ default semantics). `excluding` names the
    /// one entry allowed to match — the item being renamed — so a case-only rename
    /// ("foo" -> "FOO") is not reported as a collision with itself.
    ///
    /// Why a listing and not `fileExists`: on this volume `fileExists("FOO")` is
    /// true when only "foo" exists, so it cannot tell "taken by another item" from
    /// "taken by me under a different case". The listing can.
    static func isNameTaken(_ name: String, in directory: URL, excluding: String? = nil) -> Bool {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let wanted = name.lowercased()
        return existing.contains { $0 != excluding && $0.lowercased() == wanted }
    }

    /// The name a NEW item should take: `base` itself when it is free, otherwise the
    /// first free suffix from `collisionSafeNewName` ("stem copy.ext", "stem copy 2.ext", ...).
    ///
    /// Paste and New File/Folder use this — Finder keeps a pasted file's name when the
    /// destination has no such entry, and only suffixes on a clash. Duplicate does NOT:
    /// it always lands beside its original, so it always needs a suffix.
    static func availableName(base: String, existingNames: [String]) -> String {
        let lower = existingNames.map { $0.lowercased() }
        if !lower.contains(base.lowercased()) { return base }  // FREE-NAME-RULE (check-file-ops.sh mutates this line)
        return collisionSafeNewName(base: base, existingNames: existingNames)
    }

    /// Returns a name derived from `base` that does not appear in `existingNames`
    /// (compared case-insensitively, matching APFS / HFS+ semantics). ALWAYS
    /// suffixes, even when `base` is free — see `availableName` for the
    /// free-or-suffix rule.
    ///
    /// Strategy: append " copy" to the stem (before the extension, if any), then
    /// " copy 2", " copy 3", … until a free slot is found.
    ///
    /// Examples:
    ///   - `base = "foo.txt"`, existing = [] → `"foo copy.txt"`
    ///   - `base = "foo.txt"`, existing = `["foo copy.txt"]` → `"foo copy 2.txt"`
    ///   - `base = "foo.txt"`, existing = `["FOO COPY.TXT"]` → `"foo copy 2.txt"`
    ///     (case-insensitive collision on the first candidate)
    static func collisionSafeNewName(base: String, existingNames: [String]) -> String {
        let lower = existingNames.map { $0.lowercased() }
        let ext  = (base as NSString).pathExtension
        let stem = ext.isEmpty
            ? base
            : (base as NSString).deletingPathExtension

        var candidate = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
        if !lower.contains(candidate.lowercased()) { return candidate }
        var n = 2
        while true {
            candidate = ext.isEmpty ? "\(stem) copy \(n)" : "\(stem) copy \(n).\(ext)"
            if !lower.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    // MARK: - Descendant / Cycle Check

    /// `true` when `url` is `ancestor` itself, or is a path inside `ancestor`.
    ///
    /// Used by drag-and-drop to refuse a move that would make a directory its
    /// own descendant — e.g. dragging `~/Projects/app` into `~/Projects/app/src`.
    ///
    /// Foundation-only: uses standardised paths. The call site is responsible
    /// for resolving symlinks before calling this function; without that,
    /// `/tmp/foo` and `/private/tmp/foo` would compare unequal on macOS even
    /// though they refer to the same inode.
    static func isDescendant(url: URL, of ancestor: URL) -> Bool {
        // Normalise by appending "/" so a path is always a prefix of its own
        // children without accidentally matching a sibling whose name *starts with*
        // the ancestor's name (e.g. "/tmp/foo" is not a child of "/tmp/fo").
        let aPath = ancestor.standardized.path
        let uPath = url.standardized.path
        let aPrefix = aPath.hasSuffix("/") ? aPath : aPath + "/"
        let uNorm   = uPath.hasSuffix("/") ? uPath : uPath + "/"
        return uNorm == aPrefix || uNorm.hasPrefix(aPrefix)
    }

    // MARK: - Filesystem Operations

    /// The one `moveItem` every move/rename here goes through. A seam, not a
    /// convenience: `check-file-ops.sh` swaps it for a mover that fails on a chosen
    /// call, which is the only way to reach `rename`'s case-only rollback branch
    /// on a healthy disk. `nonisolated(unsafe)` because this enum is deliberately
    /// not actor-bound (see the header) and only the main actor or the single-
    /// threaded harness ever writes it.
    nonisolated(unsafe) static var moveItem: (URL, URL) throws -> Void = {
        try FileManager.default.moveItem(at: $0, to: $1)
    }

    /// Create an empty file at `url`.
    ///
    /// Refuses (`.fileWriteFileExists`) when the name is taken: `FileManager.createFile`
    /// silently TRUNCATES an existing file, which would turn a New File whose name
    /// the user edited to match a sibling into data loss.
    static func createFile(at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard !isNameTaken(url.lastPathComponent, in: parent) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let ok = FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: nil)
        if !ok { throw CocoaError(.fileWriteUnknown) }
    }

    /// Create a directory at `url`, including any missing intermediate directories.
    /// Refuses an existing name: with intermediates on, `createDirectory` succeeds
    /// silently over an existing directory, which would report a New Folder that
    /// never happened.
    static func createDirectory(at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard !isNameTaken(url.lastPathComponent, in: parent) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: nil)
    }

    /// Rename `from` to `to` (same parent directory, name change only).
    ///
    /// Refuses (`.fileWriteFileExists`) when ANOTHER sibling already has the new
    /// name in any case. A case-only rename (e.g. "readme.md" → "README.md") goes
    /// through a UUID-named intermediate so it is correct on every volume and OS
    /// version; if the second step fails, the intermediate is moved back to `from`
    /// before rethrowing, so a failure never strands the file under a UUID name.
    static func rename(from: URL, to: URL) throws {
        let parent = from.deletingLastPathComponent()
        guard !isNameTaken(to.lastPathComponent, in: parent, excluding: from.lastPathComponent)
        else { throw CocoaError(.fileWriteFileExists) }
        if isCaseOnlyRename(from: from, to: to) {
            let tmp = parent.appendingPathComponent(UUID().uuidString)
            try moveItem(from, tmp)
            do {
                try moveItem(tmp, to)
            } catch {
                // Best effort: the rollback can fail too, and then the original
                // error is still the one worth reporting.
                try? moveItem(tmp, from)
                throw error
            }
        } else {
            try moveItem(from, to)
        }
    }

    /// Move `from` to `destinationDir / from.lastPathComponent`.
    ///
    /// Throws `CocoaError(.fileWriteFileExists)` when the destination already
    /// contains an item with the same name (case-insensitive). Never overwrites.
    static func move(from: URL, to destinationDir: URL) throws {
        guard !isNameTaken(from.lastPathComponent, in: destinationDir) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try moveItem(from, destinationDir.appendingPathComponent(from.lastPathComponent))
    }

    /// Copy `source` into `destinationDir`. Keeps the source's name when it is free
    /// there (paste), unless `alwaysSuffix` (duplicate), and otherwise takes the
    /// first free " copy" suffix. Never overwrites.
    ///
    /// Returns the URL of the newly created copy.
    @discardableResult
    static func copy(from source: URL, into destinationDir: URL,
                     alwaysSuffix: Bool = false) throws -> URL {
        let existing = (try? FileManager.default.contentsOfDirectory(
            atPath: destinationDir.path)) ?? []
        let base = source.lastPathComponent
        let safeName = alwaysSuffix
            ? collisionSafeNewName(base: base, existingNames: existing)
            : availableName(base: base, existingNames: existing)
        let dest = destinationDir.appendingPathComponent(safeName)
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    /// Move `url` to the system Trash.
    ///
    /// Throws when the item is on a volume that has no Trash (e.g. a read-only
    /// disk image or a network share without a `.Trashes` directory).
    static func trashItem(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
