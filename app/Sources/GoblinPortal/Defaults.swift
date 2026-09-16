//
//  Defaults.swift
//  The three `UserDefaults`-backed stores: font zoom, last Space root, open Space roots.
//
//  Its own file because these share one argument, stated once in `FontZoom` and
//  referred to by the other two: transient UI state belongs in `UserDefaults`,
//  **not** in the hand-edited `config.json` an app that rewrote it would strip the
//  user's comments out of. That makes them one concern, and a concern that is
//  independent of `AppConfig` — nothing here parses the config file or can fail a
//  launch. The `FileManager` extension travels with them because it exists solely
//  to serve `LastSpaceRoot` and `OpenSpaceRoots`' shared check-don't-trust rule.
//
//  `Scripts/check-space-restore.sh` compiles THIS file directly against a
//  throwaway harness to run its 12-case truth table, so the store it verifies is
//  the shipped one. Renaming or moving this file means updating that script.
//
//  No `import SwiftTerm` here on purpose: none of these stores touch the emulator,
//  which is what lets the check above compile without building SwiftTerm first.
//

import AppKit

// MARK: - Font zoom

/// The live ⌘+ / ⌘− zoom level, app-wide and persisted.
///
/// Deliberately **not** written back into `config.json`: that file is
/// hand-edited and carries the user's own comments, so an app that rewrote it
/// would clobber them. `UserDefaults` is the idiomatic home for transient UI
/// state of exactly this kind.
///
/// `nil` means "no zoom — use the configured size", which is what ⌘0 restores.
/// It is app-wide rather than per-pane because the alternative is what v0.1
/// shipped: zooming in one tab left every other tab, every tab opened
/// afterwards, and every subsequent launch back at the configured size.
enum FontZoom {
    private static let key = "GoblinPortal.fontSizeOverride"

    static var override: CGFloat? {
        get {
            let stored = UserDefaults.standard.double(forKey: key)
            return stored > 0 ? CGFloat(stored) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Double(newValue), forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

/// The project root of the most recently opened Space, remembered across launches.
///
/// Same argument as `FontZoom`, and the same storage for the same reason: this is
/// transient UI state, not configuration, so it belongs in `UserDefaults` rather
/// than in a `config.json` the user hand-edits and comments.
///
/// `$HOME` remains the genuine first-run default — this only remembers where you
/// went afterwards. It exists because `$HOME` is a bad *steady-state* root even
/// though it is a reasonable first one: 128 top-level entries on this machine, 74
/// of them hidden, and the directories-first sort put 53 tool-cache directories
/// above `Projects/`. Sorting hidden entries last fixed the ordering; this stops
/// you landing there at all once you have opened a real project with ⌘O.
///
/// A raw path is enough because the app is not sandboxed (`make-app-bundle.sh`
/// ad-hoc signs with no entitlements). Under App Sandbox this would have to be a
/// security-scoped bookmark instead — the path alone would not carry access.
enum LastSpaceRoot {
    private static let key = "GoblinPortal.lastSpaceRoot"

    static var url: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
            // Checked, not trusted: a remembered project can be deleted, renamed, or
            // sit on an unmounted volume, and rooting a Space at a path that is gone
            // gives an empty tree with no explanation of why. Fall back to $HOME.
            guard FileManager.default.isUsableSpaceRoot(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.path, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

extension FileManager {
    /// Does a remembered path still name a directory we could root a Space at?
    ///
    /// Extracted rather than duplicated because `OpenSpaceRoots` below has to make
    /// the exact same judgement on every element of a list, and two copies of a
    /// check-don't-trust rule is two places for it to drift — one of which would then
    /// hand `FileTreeViewController` a root that no longer exists.
    ///
    /// `isDirectory` is not incidental: a remembered project directory can be
    /// replaced by a *file* of the same name, and `fileExists(atPath:)` alone would
    /// say yes — then the sidebar tree would enumerate a non-directory and show
    /// nothing, with no hint as to why.
    ///
    /// `access(path, X_OK)` guards against a directory that exists and IS a
    /// directory but lacks execute permission — a `chmod 000` temp dir, or a
    /// volume mounted read-only with no `+x` on the root. `fileExists` says yes;
    /// `chdir` then fails silently inside SwiftTerm's `forkpty` child
    /// (`Pty.swift:103`: `_ = chdir(cCurrentDirectory)`), starting the shell in
    /// the app's own cwd with no diagnostic. Darwin's `access(2)` checks the
    /// *real* UID/GID, not the effective one, which is what we want here: the
    /// shell we are about to fork will run as the real user (#8).
    func isUsableSpaceRoot(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        // X_OK on a directory means "can enter (chdir into) it".
        return path.withCString { access($0, X_OK) == 0 }
    }
}

/// The project root of every open Space, in tab order, remembered across launches.
///
/// `LastSpaceRoot` above answers "where was I working?" with exactly one path, and
/// one path has the same shape of flaw that its own commit (`37262d5`) named for
/// `$HOME`: a fine first answer, a poor steady-state one. Four Spaces open at quit
/// came back as one Space plus three forgotten roots — and unlike a lost window
/// frame, a forgotten root is work the user has to go find again in an open panel.
///
/// Storage, the sandbox caveat, and check-on-read are all deliberately identical to
/// `LastSpaceRoot`: transient UI state belongs in `UserDefaults` and not in a
/// `config.json` the user hand-edits and comments; a raw path is sufficient *only*
/// because the app is not sandboxed (`make-app-bundle.sh` ad-hoc signs with no
/// entitlements — under App Sandbox every entry here would have to be a
/// security-scoped bookmark, because the path alone would not carry access); and a
/// remembered project can be deleted, renamed, or sit on an unmounted volume
/// between launches, so entries are verified on read rather than trusted.
///
/// Nothing here can throw or fail a launch — same fail-soft contract
/// `AppConfig.load()` keeps for the config file, applied to persistence. A missing
/// key, a key someone hand-edited to the wrong type (`stringArray(forKey:)` returns
/// nil rather than trapping), and a list whose every entry has since been deleted
/// all read as `[]`, which `AppDelegate.restoreSpaces()` treats as "open one
/// default Space". The failure mode of this file is a normal first launch.
enum OpenSpaceRoots {
    private static let key = "GoblinPortal.openSpaceRoots"

    /// Restoring is not free: each Space costs a window, a file tree, and a login
    /// shell (`TerminalPane.startProcess`), so a session that had accumulated 40
    /// Spaces would fork 40 shells before the app was usable, and the native tab bar
    /// is unreadable long before that. The cap is applied as `suffix(limit)`, which
    /// keeps the most recently opened Spaces and preserves their relative order — so
    /// overflow drops the leftmost tabs instead of scrambling the group.
    static let limit = 12

    static var urls: [URL] {
        get {
            guard let paths = UserDefaults.standard.stringArray(forKey: key) else { return [] }
            let usable = paths.filter(FileManager.default.isUsableSpaceRoot(atPath:))
            return normalized(usable.map { URL(fileURLWithPath: $0) })
        }
        set {
            let paths = normalized(newValue).map(\.path)
            // Remove rather than store `[]`: an absent key and an empty list mean the
            // same thing to `restoreSpaces()`, and not leaving an empty array behind
            // keeps `defaults read com.griffinlong.goblin-portal` legible while debugging.
            if paths.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(paths, forKey: key)
            }
        }
    }

    /// De-duplicate and cap, preserving tab order.
    ///
    /// Two Spaces *can* legitimately share a root today — ⌘N twice takes
    /// `AppDelegate.defaultSpaceRoot` with no dedupe, unlike ⌘O, which explicitly
    /// refuses because "two Spaces onto one root would give the same project two
    /// file trees and two titles with no way to tell them apart"
    /// (`AppDelegate.openFolder`). Restoring that state would rebuild exactly the
    /// pair of indistinguishable tabs ⌘O declines to create, so the duplicate is
    /// collapsed here instead. Restore is lossy by design; it is not a session
    /// snapshot.
    ///
    /// Compared on `resolvingSymlinksInPath` for the same reason `openFolder`'s
    /// dedupe does — `/tmp` and `/private/tmp`, or any symlinked checkout, must not
    /// read as two roots — while the *stored* string stays the path as chosen, so a
    /// Space keeps the name the user picked in its tab.
    private static func normalized(_ roots: [URL]) -> [URL] {
        var seen: Set<String> = []
        let unique = roots.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
        return Array(unique.suffix(limit))
    }
}
