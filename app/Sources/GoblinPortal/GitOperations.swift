//
//  GitOperations.swift
//  Write-side git commands: stage, unstage, discard, commit, push, pull.
//
//  Deliberately separate from `GitStatusReader.swift`, which is read-only by design
//  (it sets `GIT_OPTIONAL_LOCKS=0` to avoid churning the index). These operations
//  ARE the mutations — they write the index and the object store, and they need locks.
//
//  Foundation-only, like its read-side sibling, so a future `check-git-operations.sh`
//  gate can compile it standalone. Not `@MainActor` because every call blocks on a
//  subprocess and belongs on a background queue.
//
//  Each operation returns a `Result<Void, GitOperationError>` rather than throwing:
//  callers in the UI layer need the error message to show the user, and a thrown error
//  would lose the git stderr that contains it.
//

import Foundation

/// What went wrong, in a shape the UI can show.
struct GitOperationError: Error {
    let message: String
}

/// Write-side git subprocess interface.
///
/// A namespace, not a type: matches `GitStatusReader`'s shape. Each method spawns
/// one `git` subprocess and blocks until it finishes — callers are responsible for
/// dispatching off the main thread.
enum GitOperations {
    /// Stage a single file: `git add -- <path>`.
    static func stage(path: String, in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["add", "--", path], in: repository)
    }

    /// Stage all changes: `git add -A`.
    static func stageAll(in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["add", "-A"], in: repository)
    }

    /// Unstage a single file: `git restore --staged -- <path>`.
    ///
    /// Uses `restore --staged` rather than `reset HEAD` because `restore` is the
    /// recommended modern spelling (git 2.23+), it does not touch the working tree,
    /// and its exit code is cleaner on edge cases (e.g. unstaging in an empty repo).
    static func unstage(path: String, in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["restore", "--staged", "--", path], in: repository)
    }

    /// Unstage all files: `git restore --staged .`.
    static func unstageAll(in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["restore", "--staged", "."], in: repository)
    }

    /// Discard working-tree changes for a single file: `git checkout -- <path>`.
    ///
    /// **This is irreversible** — the caller MUST prompt the user before calling.
    /// Uses `checkout --` rather than `restore` because `checkout` also handles
    /// untracked files when combined with `clean`, but for tracked-file discard
    /// both are equivalent. For untracked files, this is a no-op — the caller
    /// should use `discardUntracked` instead.
    static func discard(path: String, in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["checkout", "--", path], in: repository)
    }

    /// Remove an untracked file or directory: `git clean -fd -- <path>`.
    ///
    /// **This is irreversible** — the file or directory is deleted from disk.
    static func discardUntracked(path: String, in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["clean", "-fd", "--", path], in: repository)
    }

    /// Remove ALL untracked files and directories in the working tree: `git clean -fd`.
    ///
    /// **This is irreversible** — every untracked file and directory is deleted from disk.
    /// Callers MUST confirm with the user before invoking this. Paired with
    /// `discard(path: ".", ...)` to implement a full "discard all" that covers
    /// both tracked and untracked files (matching per-file discard behavior).
    static func cleanAll(in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["clean", "-fd"], in: repository)
    }

    /// Commit staged changes: `git commit -m <message>`.
    ///
    /// Returns an error if nothing is staged, or if git rejects the commit for
    /// any reason (hooks, empty message, etc.).
    static func commit(message: String, in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["commit", "-m", message], in: repository)
    }

    /// Push the current branch: `git push`.
    ///
    /// If no upstream is set, uses `git push -u origin <branch>` to set it up.
    static func push(in repository: GitRepository, branch: String? = nil, setUpstream: Bool = false) -> Result<Void, GitOperationError> {
        var args = ["push"]
        if setUpstream, let branch {
            args += ["-u", "origin", "--", branch]
        }
        return run(args, in: repository)
    }

    /// Pull from upstream: `git pull`.
    static func pull(in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["pull"], in: repository)
    }

    // MARK: - Subprocess

    /// Run a git command and return success or the stderr message.
    ///
    /// Follows `GitStatusReader.run`'s subprocess shape: hardcoded `/usr/bin/git`,
    /// read-before-wait to prevent pipe deadlock, but WITHOUT `GIT_OPTIONAL_LOCKS=0`
    /// because these operations need locks.
    private static func run(_ arguments: [String], in repository: GitRepository) -> Result<Void, GitOperationError> {
        guard FileManager.default.isExecutableFile(atPath: GitStatusReader.gitPath) else {
            return .failure(GitOperationError(message: "git not found at \(GitStatusReader.gitPath)"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitStatusReader.gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = repository.root

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let errPipe = Pipe()
        // Use FileHandle.nullDevice instead of a Pipe for stdout: a Pipe has a
        // bounded kernel buffer (~64 KB on macOS); if git writes more than that
        // before we read it, waitUntilExit() deadlocks. nullDevice discards output
        // with no buffer, so the subprocess never stalls writing to stdout.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        guard (try? process.run()) != nil else {
            return .failure(GitOperationError(message: "Failed to launch git"))
        }

        // Read-before-wait, same as GitStatusReader, to prevent pipe deadlock.
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "git exited with status \(process.terminationStatus)" : stderr
            return .failure(GitOperationError(message: detail))
        }
        return .success(())
    }
}
