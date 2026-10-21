//
//  TabTitlePolicy.swift
//  Derive a human-readable tab title from what the pane actually knows.
//
//  WHY THIS EXISTS. Every terminal tab used to show whatever the shell emitted via
//  OSC 0/2 — typically "user@host: /long/absolute/path" from a default zsh precmd
//  hook. When running many agent REPLs (afk, claude, …) every tab is labelled
//  identically. This policy replaces that with something useful:
//
//      idle shell          → cwd basename  ("project", "~" for home)
//      command in front    → "command — cwd basename"
//      remote (ssh/mosh)   → host when known, otherwise "ssh"
//      tmux               → active pane title if tmux provided one, else cwd rule
//      other multiplexer   → program name
//      explicit OSC title  → honoured when the foreground is NOT the shell's own
//                            precmd hook (see `ExplicitTitleKind` below)
//
//  THE EXPLICIT-TITLE QUESTION (the hard design call).
//  A full-screen TUI like vim, htop, or an agent REPL often sets its own window
//  title via OSC 0/2.  We want to show that title — it carries real information
//  ("vim: main.swift", "afk: thinking…").  But a default zsh precmd hook ALSO emits
//  OSC 0/2 with "user@host: /path", which is exactly what this feature replaces.
//
//  Resolution: the caller supplies an `ExplicitTitleKind` that describes WHY a title
//  was set.  A `.shellPrompt` title (detected by the OSC 133 A prompt-start marker)
//  is ignored; a `.program` title (set while a command was running) is shown.  When
//  the kind is `.unknown` (no OSC 133 integration) we fall back to the derived title
//  so we do not accidentally display "user@host" for un-integrated shells.
//
//  SURFACES. The derived title feeds:
//    1. The in-window document tab strip label (`documentTitle`, via
//       `TerminalPane+TabTitle.swift` overriding `TerminalPane+Document.swift`).
//    2. The native window/Space subtitle (`SpaceWindowController` already sets
//       `window.subtitle` from `spaceViewController(_:didChangeDocumentTitle:)`).
//  The window *title* stays as the Space root ("~/project") — that is a Space
//  property, not a document property.
//
//  PURE AND FOUNDATION-ONLY so `check-tab-title.sh` can compile this file alone.
//  No AppKit, no SwiftTerm, no TerminalPane — only Foundation.
//
//  Gated by: `app/Scripts/check-tab-title.sh`
//

import Foundation

// MARK: - ExplicitTitleKind

/// Why an OSC 0/2 title was set.  Supplied by the AppKit wiring layer, which has
/// visibility into OSC 133 markers that this pure file does not.
enum ExplicitTitleKind: Equatable {
    /// No OSC 0/2 title has been set yet (pane just opened).
    case none
    /// Title was set at the shell prompt — the default zsh/bash precmd pattern.
    /// Ignored by the policy: this is exactly what we want to replace.
    case shellPrompt
    /// Title was set while a command was running — a TUI or agent REPL that
    /// deliberately branded itself.  Shown as-is.
    case program
    /// OSC 0/2 fired but we have no OSC 133 context to know when.
    /// Treated as shellPrompt to be safe: better to derive than to show "user@host".
    case unknown
}

// MARK: - TabTitlePolicy

/// Pure function from pane state to a tab label string.
///
/// Every input type is Foundation-compatible so the gate can compile this file alone.
enum TabTitlePolicy {

    // MARK: - Constants

    /// Maximum characters before truncation.  Fits comfortably in a narrow tab.
    static let maxLength = 28

    // MARK: - Public entry point

    /// Derive the tab title.
    ///
    /// - Parameters:
    ///   - foreground:    The classified foreground kind (nil = unreadable).
    ///   - cwdURL:        The shell's current working directory (local, kernel-resolved).
    ///   - homeURL:       The user's home directory for `~` substitution.
    ///   - explicitTitle: An OSC 0/2 title and why it was set.
    ///   - explicitKind:  Context for the explicit title (see `ExplicitTitleKind`).
    ///   - tmuxTitle:     The title tmux reports for its active pane, if any.
    /// - Returns: A short, human-readable label suitable for a narrow tab strip.
    static func title(
        foreground: ForegroundKind?,
        cwdURL: URL?,
        homeURL: URL,
        explicitTitle: String,
        explicitKind: ExplicitTitleKind,
        tmuxTitle: String?
    ) -> String {
        // 1. Honour an explicit program-set title (TUI/agent REPL branded itself).
        //    Shell-prompt titles ("user@host: /path") and unknown-origin titles are
        //    skipped — they are what this policy replaces.
        if explicitKind == .program, !explicitTitle.isEmpty {
            return truncated(explicitTitle)
        }

        switch foreground {

        // 2. Unreadable foreground: fall back to cwd or a generic label.
        case nil:
            if let cwd = cwdURL { return cwdBasename(cwd, home: homeURL) }
            return "Terminal"

        // 3. Idle shell — just the cwd basename.
        case .shell?:
            if let cwd = cwdURL { return cwdBasename(cwd, home: homeURL) }
            return "Terminal"

        // 4. Command in front — "command — cwd".
        //    Covers agent REPLs, editors, builds.  The em-dash separator matches
        //    macOS document windows ("filename — AppName").
        case .command(let name)?:
            let base = cwdURL.map { cwdBasename($0, home: homeURL) } ?? ""
            return base.isEmpty ? truncated(name) : truncated("\(name) \u{2014} \(base)")

        // 5. Nested shell — treat as idle (show that shell's cwd).
        case .knownShell(_, let name)?:
            if let cwd = cwdURL { return cwdBasename(cwd, home: homeURL) }
            return truncated(name)

        // 6. tmux — prefer the title tmux reports (it reflects the active pane's
        //    own OSC 0/2), falling back to cwd if tmux has nothing useful.
        case .tmuxClient?:
            if let t = tmuxTitle, !t.isEmpty { return truncated(t) }
            if let cwd = cwdURL { return cwdBasename(cwd, home: homeURL) }
            return "tmux"

        // 7. Remote session — show the host if we know it, else the program name.
        //    Never show a local path: the user is on another machine.
        case .remote(let name)?:
            // The host comes from OSC 7 or the explicit title if it named one.
            // For now the caller passes any known host as `explicitTitle` with
            // kind `.program` (handled above) or the name is the program basename.
            return truncated(name)

        // 8. Other multiplexer (screen, zellij) — we cannot see inside; show name.
        case .otherMultiplexer(let name)?:
            return truncated(name)
        }
    }

    // MARK: - Helpers

    /// The last path component of `url`, with `~` substituted for home.
    /// Home itself returns `"~"`.
    static func cwdBasename(_ url: URL, home: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path

        if path == homePath { return "~" }

        // Trim home prefix so ~/Projects/foo → "foo" not "/Users/alice/Projects/foo"
        let base = url.lastPathComponent
        return truncated(base.isEmpty ? "~" : base)
    }

    /// Truncate to `maxLength`, appending "…" when clipped.
    static func truncated(_ s: String) -> String {
        guard s.count > maxLength else { return s }
        return String(s.prefix(maxLength - 1)) + "\u{2026}"
    }
}

// MARK: - TabTitleTracker

/// The explicit-title state machine: which OSC 0/2 title, if any, the policy may see.
///
/// Pure and value-typed so `check-tab-title.sh` gates the TRANSITIONS, not only the
/// final mapping. It was AppKit-side state until review found a stuck-title bug the
/// mapping gate could not see: a program title ("vim: main.swift") set while running
/// survived the command's end, and because stock macOS zsh sets NO precmd title,
/// nothing ever replaced it — the tab kept naming vim after vim had exited.
/// `commandEnded()` now drops the program's title (cases T11-T14).
struct TabTitleTracker: Equatable {
    private(set) var explicitTitle: String = ""
    private(set) var explicitKind: ExplicitTitleKind = .none
    /// True between a command's end / prompt start and the next title: that title is
    /// the shell's own precmd `user@host` form and must be suppressed.
    private(set) var nextTitleIsShellPrompt: Bool = false

    /// OSC 133 A, when it is surfaced. The next title is the prompt's.
    mutating func promptStarted() { nextTitleIsShellPrompt = true }

    /// OSC 133 C: a title from here on belongs to the running program.
    mutating func commandStarted() { nextTitleIsShellPrompt = false }

    /// OSC 133 D: the program is gone, so is its title. The shell's next title (if it
    /// sets one at all) is precmd noise.
    mutating func commandEnded() {
        explicitTitle = ""
        explicitKind = .none
        nextTitleIsShellPrompt = true
    }

    /// OSC 0/2 arrived. `running` is whether OSC 133 says a command is in flight;
    /// without shell integration it is never true, so every title is treated as
    /// prompt noise and the derived title wins (never `user@host`).
    mutating func titleSet(_ title: String, running: Bool) {
        if nextTitleIsShellPrompt {
            explicitKind = .shellPrompt
            nextTitleIsShellPrompt = false
        } else {
            explicitKind = running ? .program : .shellPrompt
        }
        explicitTitle = title
    }
}
