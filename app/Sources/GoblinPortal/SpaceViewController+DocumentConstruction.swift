//
//  SpaceViewController+DocumentConstruction.swift
//  How a Space builds a terminal document.
//
//  Its own file for two reasons, one structural and one arithmetic.
//
//  Structural: `add(document:beforeActivating:)` in `SpaceViewController.swift` is deliberately
//  polymorphic — it installs any `SpaceDocument` and knows nothing about kinds. Deciding WHICH
//  kind to build is a different concern, and it is the concern that has to name `TerminalPane`
//  concretely. Keeping it here means the container proper still contains no pane knowledge at
//  all.
//
//  Arithmetic: `SpaceViewController.swift` was at 346 lines against a hard 350-line ceiling
//  (`Scripts/check-file-size.sh`). The convention when a file reaches the ceiling is to find
//  its seam and move one whole concern out rather than shave comments — this is that seam, and
//  moving `addTerminalDocument` here also bought the room for `closeDocument`'s teardown call.
//

import AppKit

extension SpaceViewController {
    /// Add a terminal document rooted at `workingDirectory`, following a three-level CWD
    /// inheritance chain:
    ///
    /// 1. **Explicit override** — `workingDirectory` when the caller passes one (e.g.
    ///    "New Terminal Here" from the file tree, `fileTree(_:didRequestNewTerminalAt:)`).
    /// 2. **Focused shell's CWD** — `focusedShellHost?.currentDirectory` when no override is
    ///    given. This is the ⌘T case: the new tab opens in the directory the user has already
    ///    navigated to in the active shell, so a `cd ~/Projects/foo` in the current tab is
    ///    still the cwd in the next one. `currentDirectory` prefers an OSC 7 report (exact,
    ///    from the shell itself via `shell-integration.zsh`) and falls back to a kernel poll
    ///    (`proc_pidinfo` on the foreground process group) — see `ShellHosting.swift` for the
    ///    full two-source explanation.
    /// 3. **Space root** — `root` when there is no focused shell (first tab in a Space, or the
    ///    focused document is a file viewer). A Space *is* a project root (plan §12.4 item 1),
    ///    so landing there is always the correct bottom-of-chain answer.
    ///
    /// The root default existed because this function once created the pane without ever
    /// mentioning `root`, so ⌘T in a Space opened on a project landed outside it and the first
    /// thing you typed was `cd`. The focused-shell level is what closes that gap without
    /// touching callers that already pass an explicit directory.
    @discardableResult
    func addTerminalDocument(start: Bool = true, workingDirectory: URL? = nil) -> SpaceDocument {
        // Explicit override → focused shell's CWD → Space root.
        // `focusedShellHost` is nil when no shell document exists yet (first tab); the
        // kernel-poll fallback inside `currentDirectory` is safe to call on the main actor
        // because it is a non-blocking `proc_pidinfo` snapshot, not a wait.
        let directory = workingDirectory ?? focusedShellHost?.currentDirectory ?? root

        let pane = TerminalPane(
            config: config, frame: documentArea.container.bounds, workingDirectory: directory)

        // `beforeActivating`, not after, and this ordering is load-bearing rather than stylistic.
        // `start()` hands the pty its initial `winsize` from the view's *current* geometry
        // (SwiftTerm: `MacLocalTerminalView.swift:204-209` builds it from `terminal.rows`/`cols`),
        // while activation is what makes the tab strip appear at the second document — costing the
        // container ~30pt, i.e. about two rows (`DocumentAreaViewController.viewDidLayout`).
        // Starting after activation would therefore hand a *different* initial row count to every
        // terminal but the first and add a SIGWINCH before the first prompt. Both are reflow
        // inputs, and reflow is the one area of this app with a known upstream defect
        // (SwiftTerm #494, patched locally as `0002`), so the original sequence — append, start,
        // select — is reproduced exactly.
        add(document: pane, beforeActivating: { if start { pane.start() } })
        return pane
    }
}
