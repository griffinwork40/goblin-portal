//
//  GitStatusReader.swift
//  Finding the repository, and asking git what changed.
//
//  The spawning half of the git sidebar, split from `GitStatus.swift` so that the
//  grammar stays a total function over bytes with no process dependency. Both files are
//  `Foundation`-only and neither is `@MainActor`, so `Scripts/check-git-status.sh`
//  compiles **both** directly with `swiftc`: the parser is gated against real bytes, and
//  discovery is gated against real repositories, without linking AppKit or the app.
//
//  WHY DISCOVERY IS A SUBPROCESS AND NOT A `stat`. The obvious implementation —
//  "is there a `.git` directory at this path?" — is wrong on this very checkout. In a
//  git worktree `.git` is an ASCII **file** containing a `gitdir:` pointer, not a
//  directory, so `isDirectory(root + "/.git")` concludes "not a repository" for every
//  `.afk-worktrees/*` checkout including Goblin Portal's own development tree, while passing
//  every manual test anyone would run from an ordinary clone. Verified live here:
//  `test -d .git` is false and `head -c 100 .git` reads
//  `gitdir: .../.git/worktrees/afk-build-pr-17-feature`. Asking git removes the entire
//  class of bug, and it also handles the case the `stat` version gets wrong in the other
//  direction: a subdirectory deep inside a repo, where there is no `.git` at all.
//

import Foundation

/// Where a repository lives, in the three spellings that turn out to differ.
struct GitRepository: Equatable {
    /// The working-tree root, symlink-resolved to match how the rest of the app spells
    /// paths (`ShellDirectory.current`, `AppDelegate.openFolder`, `SpaceRestore`).
    let root: URL
    /// This worktree's private git directory: `HEAD`, `index`, and the `MERGE_HEAD` /
    /// rebase sentinels live here.
    let gitDirectory: URL
    /// The shared git directory: `refs/`, `packed-refs`, `objects/`.
    ///
    /// **In a worktree these two differ**, and a watcher that follows only one is
    /// half-blind — `gitDirectory` alone misses a branch being created or moved from
    /// elsewhere, `commonDirectory` alone misses this worktree's own index changing.
    /// In an ordinary clone they are equal and the watcher dedupes them. Watching the
    /// top-level `.git` *file* instead is useless: it never changes after creation.
    let commonDirectory: URL

    /// `path` relative to the working-tree root, forward-slashed, or nil when `path` is
    /// outside the repository. The spelling git itself uses in porcelain output, which
    /// is what makes a `GitStatusSnapshot` lookup succeed.
    func relativePath(for url: URL) -> String? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.path
        if resolved == base { return "" }
        guard resolved.hasPrefix(base + "/") else { return nil }
        return String(resolved.dropFirst(base.count + 1))
    }
}

/// Running git and handing its bytes to `GitStatus`.
///
/// A namespace, not a type: there is no state to hold. Deliberately not `@MainActor` for
/// the same reason `ShellDirectory` opts out — every call here blocks on a subprocess and
/// belongs on a background queue, and annotating it would pull that work onto the main
/// thread where a 92ms `git status` on a large repo becomes a dropped frame.
enum GitStatusReader {
    /// Where git lives. Hardcoded rather than PATH-resolved, deliberately: an app
    /// launched from the Dock inherits a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`)
    /// that would find exactly this binary anyway, so a lookup would add a failure mode
    /// and buy nothing. On macOS this is the Command Line Tools shim and is present on
    /// any machine that can build this project.
    static let gitPath = "/usr/bin/git"

    /// The repository containing `directory`, or nil if there is none.
    ///
    /// Nil is a normal answer, not an error: a Space can be opened on `~/Documents`, and
    /// the sidebar simply draws no decorations there. One spawn answers all three paths
    /// — `rev-parse` accepts multiple flags and prints one line each, in argument order.
    static func discoverRepository(at directory: URL) -> GitRepository? {
        guard let output = run(
            ["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"],
            in: directory)
        else { return nil }

        let lines = String(decoding: output, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return nil }

        // `--git-dir` and `--git-common-dir` come back RELATIVE when the cwd is the
        // repo root (plain `.git`), and absolute from a subdirectory. Resolving against
        // `directory` normalises both, and is why this is not just `URL(fileURLWithPath:)`.
        let root = URL(fileURLWithPath: lines[0]).standardizedFileURL.resolvingSymlinksInPath()
        return GitRepository(
            root: root,
            gitDirectory: absolute(lines[1], relativeTo: directory),
            commonDirectory: absolute(lines[2], relativeTo: directory))
    }

    /// A fresh snapshot of `repository`, or nil if git could not be asked.
    ///
    /// Rebuilt whole every time rather than diffed against the previous answer. See
    /// `GitStatus.rollUp` for why incremental invalidation is refused.
    static func snapshot(of repository: GitRepository) -> GitStatusSnapshot? {
        guard let output = run(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            in: repository.root)
        else { return nil }
        return GitStatus.parse(porcelain: output)
    }

    // MARK: - The subprocess

    /// Run git, or nil on any failure — a missing binary, a non-zero exit, a directory
    /// that is not a repository (`rev-parse` exits 128), or a git too old to know
    /// `--porcelain=v2`. All of them mean the same thing to a caller: draw nothing.
    private static func run(_ arguments: [String], in directory: URL) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: gitPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        // NOT about avoiding lock errors — `git status` does not fail on a stale
        // `index.lock`. It is about not *creating* one: status opportunistically writes
        // a refreshed index, and a poller doing that every couple of seconds churns
        // `index.lock` create/delete events into every other FSEvents watcher on the
        // repo, including this app's own. Read-only is the honest posture for a
        // decoration.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()  // swallowed: a diagnostic here would be noise

        guard (try? process.run()) != nil else { return nil }

        // READ BEFORE WAIT, and the order is load-bearing. A pipe holds ~64KB; `git
        // status --untracked-files=all` on a repo with a large untracked tree exceeds
        // that easily. Calling `waitUntilExit()` first would block this thread waiting
        // for a child that is itself blocked writing into a full pipe nobody is
        // draining — a deadlock that appears only on big repositories, i.e. never during
        // development and always on a user's monorepo.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    /// git prints these relative to the cwd it was given, or absolute; normalise both.
    private static func absolute(_ path: String, relativeTo directory: URL) -> URL {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : directory.appendingPathComponent(path)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
