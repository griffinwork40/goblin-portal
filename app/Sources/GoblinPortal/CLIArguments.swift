//
//  CLIArguments.swift
//  Parse the command-line arguments the binary is invoked with.
//
//  Why here, not in `main.swift`: `main.swift` is 19 lines of pure bootstrap;
//  adding argument parsing inline would mix two concerns (arg parsing + NSApp
//  lifecycle) in a file whose whole value is being easy to read start-to-finish.
//  Pulling it here follows the same reasoning as `SpaceRestore.swift` and
//  `StarterConfig.swift` — one thing per file, so the concern is findable.
//
//  Why a struct with a static `shared`, not top-level vars in main.swift: the
//  parsing runs once at the module boundary (struct is file-private, `shared` is
//  the only publicly-named value), and every reader gets the same result without
//  anyone having to thread a parameter through the call chain. The alternative —
//  reading `CommandLine.arguments` again at each call site — would let two
//  divergent parses exist, which is exactly the class of bug a single parse
//  prevents.
//
//  `@MainActor` because every reader lives on the main actor (`AppDelegate`,
//  `FileViewerPane+Document`), and Swift 6 treats cross-actor reads of mutable
//  state as errors even when the state is provably written once.
//

import Foundation

/// The subset of `CommandLine.arguments` that this app acts on at launch.
///
/// Supported invocation:
///
///     GoblinPortal --wait <path>
///
/// `--wait` is the POSIX convention adopted by every `$EDITOR` integration —
/// used by git (`core.editor`), crontab, and `VISUAL` / `EDITOR` — where the
/// editor must block the calling process until the user finishes. See:
/// https://git-scm.com/docs/git-commit#_git_commit
///
/// When `waitFile` is non-nil the app is running in CLI mode. The differences
/// from a normal launch are:
///   1. `restoreSpaces()` is skipped — the caller wants exactly one file, not
///      a reconstruction of whatever the user had open last session.
///   2. The `--wait` file is opened immediately in a fresh `FileViewerPane`.
///   3. When that pane's `documentWillClose()` fires, the app terminates so the
///      calling process (git, etc.) unblocks.
///
/// `waitFile` is nil for every normal launch.
@MainActor
struct CLIArguments {
    /// Singleton. Parsed exactly once at module load; all readers share this.
    static let shared = CLIArguments()

    /// The file the caller wants opened in blocking mode, or nil for a normal launch.
    let waitFile: URL?

    /// Parse `CommandLine.arguments` for `--wait <path>`.
    ///
    /// Fails soft: an unrecognised or incomplete `--wait` invocation leaves
    /// `waitFile` nil and falls through to a normal launch rather than crashing.
    /// The path is resolved relative to the process's working directory, which
    /// is the directory git/crontab is running in — exactly right for
    /// `git commit -m ""` and similar callers that supply relative paths.
    private init() {
        let args = CommandLine.arguments
        // Look for `--wait` anywhere in the argument list, not just at argv[1]:
        // some shells and wrappers may prepend flags before ours.
        if let index = args.firstIndex(of: "--wait"), args.indices.contains(index + 1) {
            let rawPath = args[index + 1]
            // B-1: Guard against a flag being misread as the path. If the next argument
            // starts with "-" the caller omitted the path, so treat `waitFile` as absent
            // rather than resolving `--some-flag` relative to cwd and opening nonsense.
            guard !rawPath.hasPrefix("-") else {
                waitFile = nil
                return
            }
            // Resolve relative to the process's cwd, NOT the app bundle's location.
            // `URL(fileURLWithPath:)` treats a relative path as relative to "/" on
            // macOS; `URL(fileURLWithPath:relativeTo:)` fixes that.
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                          isDirectory: true)
            waitFile = URL(fileURLWithPath: rawPath, relativeTo: cwd)
                .resolvingSymlinksInPath()
        } else {
            waitFile = nil
        }
    }
}
