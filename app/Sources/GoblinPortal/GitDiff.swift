//
//  GitDiff.swift
//  Run `git diff` for a single file — the data half of the diff viewer tab.
//
//  Foundation-only and not `@MainActor`, like `GitStatusReader` and `GitOperations`:
//  every call blocks on a subprocess and belongs on a background queue.
//
//  Three diff modes match what VS Code shows when you click a changed file:
//  - Working tree vs HEAD: unstaged changes (the default when clicking a "Changes" row)
//  - Index vs HEAD: staged changes (when clicking a "Staged Changes" row)
//  - Working tree vs index: what `git diff` with no flags shows (less commonly needed)
//

import Foundation

/// Running `git diff` and returning raw unified-diff text.
///
/// A namespace matching `GitStatusReader` and `GitOperations`.
enum GitDiff {
    /// Diff a single file against HEAD.
    ///
    /// - `staged: false` → working tree vs HEAD (`git diff HEAD -- <path>`)
    /// - `staged: true`  → index vs HEAD (`git diff --cached -- <path>`)
    ///
    /// Returns the raw unified diff as a string, or nil if git failed or the file
    /// has no changes. An empty string from git means "no diff" — the file is clean
    /// relative to the comparison target.
    static func diff(
        path: String, staged: Bool, in repository: GitRepository
    ) -> String? {
        var args = ["diff", "--no-color"]
        if staged {
            args.append("--cached")
        } else {
            args.append("HEAD")
        }
        args += ["--", path]
        return run(args, in: repository)
    }

    /// Full diff of all changes (for the source control panel's overview).
    ///
    /// - `staged: false` → all unstaged changes
    /// - `staged: true`  → all staged changes
    static func diffAll(staged: Bool, in repository: GitRepository) -> String? {
        var args = ["diff", "--no-color", "--stat"]
        if staged {
            args.append("--cached")
        } else {
            args.append("HEAD")
        }
        return run(args, in: repository)
    }

    // MARK: - Subprocess

    /// Run git diff and return stdout as a string, or nil on failure.
    ///
    /// Same subprocess shape as `GitStatusReader.run` and `GitOperations.run`:
    /// hardcoded path, `GIT_OPTIONAL_LOCKS=0` (read-only), credential-prompt
    /// suppression, and a 30-second timeout via DispatchSemaphore.
    ///
    /// Drain order matters: stdout must be read BEFORE waiting on the semaphore.
    /// Unlike `GitOperations.run` (which discards stdout into nullDevice), here
    /// stdout is a Pipe whose kernel buffer (~64 KB) can fill and stall the
    /// process before `waitUntilExit` ever returns. Reading first empties the
    /// buffer so the subprocess is never blocked writing; the semaphore then
    /// fires once the process exits naturally.
    private static func run(_ arguments: [String], in repository: GitRepository) -> String? {
        guard FileManager.default.isExecutableFile(atPath: GitStatusReader.gitPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitStatusReader.gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = repository.root

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Suppress interactive credential prompts in two layers (mirrors GitOperations.run F-1):
        //  • GIT_TERMINAL_PROMPT=0 blocks direct /dev/tty writes (git 2.3+).
        //  • GIT_ASKPASS=""  overrides any ambient ASKPASS helper that could open a
        //    GUI dialog or block indefinitely even when GIT_TERMINAL_PROMPT is set.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = ""
        process.environment = environment

        let out = Pipe()
        process.standardOutput = out
        // Discard stderr: a Pipe whose read end is never drained deadlocks
        // waitUntilExit() when git writes more than the ~64 KB kernel buffer
        // (smudge-filter errors, large binary warnings). nullDevice has no buffer.
        process.standardError = FileHandle.nullDevice

        // Wire the termination handler BEFORE run() to avoid a race where git
        // exits before the handler is registered.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        guard (try? process.run()) != nil else { return nil }

        // Read stdout BEFORE waiting for the semaphore. The pipe's kernel buffer is
        // finite (~64 KB); if we wait first, a large diff stalls the subprocess and
        // the semaphore never fires — classic pipe deadlock. Reading first drains the
        // buffer continuously so git never blocks on a write.
        let data = out.fileHandleForReading.readDataToEndOfFile()

        let timedOut = done.wait(timeout: .now() + 30) == .timedOut
        if timedOut {
            process.terminate()
            // SIGTERM may not kill ssh/smudge children; SIGKILL after 2 s guarantees
            // the process exits and the pipe is closed.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                guard pid > 0 else { return }
                kill(pid, SIGKILL)
            }
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
