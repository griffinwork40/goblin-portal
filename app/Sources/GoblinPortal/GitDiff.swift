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
    /// hardcoded path, read-before-wait, `GIT_OPTIONAL_LOCKS=0` (this is read-only).
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
        process.environment = environment

        let out = Pipe()
        process.standardOutput = out
        // Discard stderr: a Pipe whose read end is never drained deadlocks
        // waitUntilExit() when git writes more than the ~64 KB kernel buffer
        // (smudge-filter errors, large binary warnings). nullDevice has no buffer.
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
