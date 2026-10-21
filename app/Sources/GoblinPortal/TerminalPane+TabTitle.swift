//
//  TerminalPane+TabTitle.swift
//  Wires TabTitlePolicy into TerminalPane's documentTitle and refresh triggers.
//
//  WHY A SEPARATE FILE.  `TerminalPane+Document.swift` already owns the
//  `SpaceDocument` conformance and its `documentTitle` witness.  Overriding
//  `documentTitle` there would mix two concerns in one file; placing the
//  tab-title logic here keeps the policy wiring self-contained and auditable.
//  `TerminalPane.swift` is at the 350-LOC ceiling; this extension adds stored
//  state via associated objects (same pattern as ShellIntegration, DirectoryState).
//
//  REFRESH TRIGGERS.  The derived title must update when:
//    a) the directory changes   → already fires syncDocumentChrome() via the
//       750 ms poller's `followDirectory()` → `directoryFollow.tick()` which
//       calls `space.fileTree.updateDirectoryFollowStatus`, NOT syncDocumentChrome.
//       We add a `didSet` hook on `PaneDirectoryState.lastLocalDirectory` via
//       `notifyTitleChanged()` called from `shellContext` (see below).
//    b) a command starts/ends   → OSC 133 C/D already calls
//       `documentDelegate?.documentDidChangeStatus` which calls `syncDocumentChrome`.
//       We piggyback: `applyCommandOutcome` and `onCommandStarted` both call
//       `notifyTitleChanged()`.
//    c) an explicit OSC 0/2 arrives → `setTerminalTitle` already calls
//       `documentDelegate?.document(self, didChangeTitle:)` → `syncDocumentChrome`.
//       We intercept there too.
//    d) OSC 133 A (prompt start) → marks the NEXT OSC 0/2 as `.shellPrompt`.
//
//  The 750 ms poller already calls `shellContext` on every tick (to read the
//  directory).  We hook that path so a `cd` that changes `lastLocalDirectory`
//  triggers a title refresh within one tick — no new timer.
//
//  AVOID REDUNDANT REDRAWS.  `notifyTitleChanged()` computes the new derived
//  title and only fires `document(self, didChangeTitle:)` when it actually changed.
//

import AppKit
import SwiftTerm

// MARK: - Stored state for tab-title tracking

/// Lightweight state added to each pane via an associated object.
@MainActor
final class PaneTabTitleState {
    /// The last derived title we reported.  Guards against redundant redraws.
    var lastReportedTitle: String = ""
    /// Whether the next OSC 0/2 was triggered at the shell prompt.
    /// Set to `true` on OSC 133 A (prompt start), cleared on any other event.
    var nextTitleIsShellPrompt: Bool = false
    /// The explicit title set by the running program, and its kind.
    var explicitTitle: String = ""
    var explicitKind: ExplicitTitleKind = .none
}

// MARK: - TerminalPane tab-title extension

@MainActor
extension TerminalPane {

    // MARK: Associated object

    private static var tabTitleStateKey: UInt8 = 0

    var tabTitleState: PaneTabTitleState {
        if let s = objc_getAssociatedObject(self, &TerminalPane.tabTitleStateKey)
            as? PaneTabTitleState { return s }
        let s = PaneTabTitleState()
        objc_setAssociatedObject(self, &TerminalPane.tabTitleStateKey,
                                 s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    // MARK: - documentTitle override

    /// The derived tab title.  Overrides the `TerminalPane+Document.swift` witness
    /// (`currentTitle.isEmpty ? "Terminal" : currentTitle`) with the policy result.
    ///
    /// This property is called by `syncDocumentChrome()` each time chrome is rebuilt,
    /// so it is the single place the policy is consulted for the strip label AND the
    /// window subtitle (both flow through `documentTitle` in `SpaceViewController`).
    var derivedDocumentTitle: String {
        let context = shellContext        // cheap: reads cached state, no subprocess
        let state = tabTitleState
        let ts = state.explicitTitle
        let tk = state.explicitKind

        // When inside tmux, surface the active pane's title if tmux gave us one.
        // `TmuxPaneState` does not carry a pane title today; fall back to nil so
        // the policy uses its cwd rule.  A future tmux enhancement can fill this in.
        let tmuxTitle: String? = nil

        return TabTitlePolicy.title(
            foreground: context.foreground,
            cwdURL: context.directory,
            homeURL: Self.homeURL,
            explicitTitle: ts,
            explicitKind: tk,
            tmuxTitle: tmuxTitle
        )
    }

    /// Home URL, computed once.
    private static let homeURL: URL = URL(
        fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    // MARK: - Notify helpers

    /// Recompute the derived title and fire the delegate callback only when it changed.
    /// Called from every event that might alter the title: directory change (via the
    /// poller's tick), command start/end, OSC 0/2, OSC 133 A.
    func notifyTitleChanged() {
        let newTitle = derivedDocumentTitle
        let state = tabTitleState
        guard newTitle != state.lastReportedTitle else { return }
        state.lastReportedTitle = newTitle
        documentDelegate?.document(self, didChangeTitle: newTitle)
    }

    // MARK: - OSC 133 A hook (prompt start)

    /// Called when OSC 133 A (prompt start) arrives, marking the shell is at a prompt.
    /// The next OSC 0/2 from the default zsh precmd should be ignored (`.shellPrompt`).
    func handlePromptStart() {
        tabTitleState.nextTitleIsShellPrompt = true
    }

    // MARK: - OSC 0/2 intercept

    /// Intercepts `setTerminalTitle` (called from `TerminalPane.swift`) to classify
    /// the incoming title before storing it.
    ///
    /// If `nextTitleIsShellPrompt` is set, the title is `.shellPrompt` (ignored by
    /// policy).  Otherwise it is `.program` — a TUI or agent REPL set it.
    /// We keep `currentTitle` updated as before (close-confirmation reads it), but
    /// also update `explicitTitle`/`explicitKind` and fire `notifyTitleChanged`.
    func handleExplicitTitle(_ title: String) {
        let ts = tabTitleState
        if ts.nextTitleIsShellPrompt {
            ts.explicitKind = .shellPrompt
            ts.nextTitleIsShellPrompt = false
        } else if ts.explicitKind == .none && title.isEmpty {
            ts.explicitKind = .none
        } else {
            ts.explicitKind = (status == .running) ? .program : .shellPrompt
        }
        ts.explicitTitle = title
        notifyTitleChanged()
    }

    // MARK: - Directory-change hook

    /// Called from the directory-follow poller tick path when the local directory
    /// changes.  Fires a title refresh so a `cd` updates the tab label within one
    /// 750 ms tick without a second timer.
    func notifyDirectoryChanged() {
        notifyTitleChanged()
    }

    // MARK: - Command boundary hooks

    /// Called on OSC 133 C (command started).  Switches to `.program` mode so the
    /// next OSC 0/2 from the running program is honoured.
    func handleCommandStartForTitle() {
        tabTitleState.nextTitleIsShellPrompt = false
        notifyTitleChanged()
    }

    /// Called on OSC 133 D (command ended).  After a command finishes, the shell
    /// will emit OSC 133 A then its precmd OSC 0/2 — mark that next title as a
    /// shell-prompt title so it is suppressed.
    func handleCommandEndForTitle() {
        tabTitleState.nextTitleIsShellPrompt = true
        notifyTitleChanged()
    }
}
