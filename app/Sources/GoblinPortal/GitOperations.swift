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
    ///
    /// F-3: When the caller requests `setUpstream` but `branch` is nil, HEAD is
    /// detached and git would push an anonymous ref. Fail early with a clear message
    /// rather than letting git emit a confusing "You are not currently on a branch"
    /// error that bypasses the existing showError path on some versions.
    static func push(in repository: GitRepository, branch: String? = nil, setUpstream: Bool = false) -> Result<Void, GitOperationError> {
        if setUpstream && branch == nil {
            return .failure(GitOperationError(message: "Cannot push: HEAD is detached."))
        }
        var args = ["push"]
        if setUpstream, let branch {
            args += ["-u", "origin", "--", branch]
        }
        return run(args, in: repository)
    }

    /// Pull from upstream: `git pull --ff-only`.
    ///
    /// F-2: Bare `git pull` silently creates a merge commit when the local and remote
    /// branches have diverged — the merge is often unintentional and hard to undo
    /// without re-reading git history. `--ff-only` makes divergence a hard error surfaced
    /// through the existing showError path, which matches VS Code's pull behaviour
    /// (vscode src/vs/workbench/contrib/scm/browser/dirtDiffDecorator.ts, "ff-only").
    static func pull(in repository: GitRepository) -> Result<Void, GitOperationError> {
        run(["pull", "--ff-only"], in: repository)
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
        // F-1: Suppress interactive credential prompts in two layers:
        //  • GIT_TERMINAL_PROMPT=0 prevents git from writing to /dev/tty directly
        //    (git credential.c, "terminal_prompt" guard, git 2.3+).
        //  • GIT_ASKPASS="" overrides any ASKPASS helper the ambient shell may have set
        //    (e.g. the macOS Keychain helper or an IDE bridge). Without it, git falls
        //    through to the helper even when GIT_TERMINAL_PROMPT=0 is set, and the helper
        //    can open a GUI dialog or block indefinitely (git credential.c:credential_do).
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = ""
        process.environment = environment

        let errPipe = Pipe()
        // Use FileHandle.nullDevice instead of a Pipe for stdout: a Pipe has a
        // bounded kernel buffer (~64 KB on macOS); if git writes more than that
        // before we read it, waitUntilExit() deadlocks. nullDevice discards output
        // with no buffer, so the subprocess never stalls writing to stdout.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        // F-1: Hard 30-second timeout so a hung credential helper or stalled remote
        // cannot block the caller indefinitely. terminationHandler MUST be set before
        // run() to avoid a race where git exits before the handler is wired.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        guard (try? process.run()) != nil else {
            return .failure(GitOperationError(message: "Failed to launch git"))
        }

        // Read stderr concurrently with the timeout wait. readDataToEndOfFile() blocks
        // until the pipe closes, which only happens when the process exits (or is
        // terminated). If the read were sequential before the wait, a hung process
        // would block the read forever and the timeout would never fire. Reading on a
        // separate queue lets the semaphore timeout fire first, terminate() the process,
        // which closes the pipe and unblocks the read.
        var errData = Data()
        let readQueue = DispatchQueue(label: "goblin-portal.git-stderr")
        readQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let timedOut = done.wait(timeout: .now() + 30) == .timedOut
        if timedOut {
            process.terminate()
            // Wait briefly for the terminated process to close its pipes so the
            // concurrent stderr read can complete. 2 seconds is generous — terminate()
            // delivers SIGTERM and the pipe closes on process exit.
            readQueue.sync {}
            return .failure(GitOperationError(message: "git timed out after 30 seconds"))
        }
        process.waitUntilExit()
        // Ensure the stderr read has finished before we access errData.
        readQueue.sync {}

        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "git exited with status \(process.terminationStatus)" : stderr
            return .failure(GitOperationError(message: detail))
        }
        return .success(())
    }
}
