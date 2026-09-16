//
//  SpaceDocument.swift
//  What is allowed to live in a Space's document strip.
//

import AppKit

/// What a document wants the user to know, when the user is not looking at it.
///
/// Goblin Portal exists to host a long-running agent REPL, and the failure mode that matters
/// is three documents open where one is blocked on input, one finished four minutes
/// ago and one failed — with the strip rendering all three identically. This is the
/// model behind fixing that.
///
/// **All five states are now reachable.** `.idle` and `.attention` were wired first
/// (bell via `GoblinPortalTerminalViewDelegate`); `.succeeded` and `.failed` are now wired
/// via OSC 133 (`ShellIntegration.swift` + `TerminalPane+ShellIntegration.swift`),
/// fired when the shell sources `Resources/shell-integration.zsh`. `.running` is
/// modelled for completeness but not yet surfaced in the tab strip — OSC 133 `A`/`C`
/// are parsed and the state machine advances through it, but no UI reads it today.
///
/// Ordered by how loudly each one deserves to interrupt, so the strip can compare.
enum DocumentStatus: Int, Comparable {
    /// Nothing to say. Every document's resting state.
    case idle = 0

    /// Work in progress. OSC 133 `A`/`C` advances through this state internally in
    /// `ShellIntegration.State` but no tab-strip presentation is wired yet — the state
    /// machine tracks it so future UI can read it without re-parsing the sequences.
    case running = 1

    /// Finished cleanly. Wired via OSC 133 `D` → `CommandOutcome.of` → `.succeeded`
    /// (exit 0, ran ≥ 10s) in `TerminalPane+ShellIntegration.swift`. Requires the
    /// user to source `Resources/shell-integration.zsh`.
    case succeeded = 2

    /// Finished badly. Wired via OSC 133 `D` → `CommandOutcome.of` → `.failed`
    /// (any non-zero exit). Requires the user to source `Resources/shell-integration.zsh`.
    case failed = 3

    /// The document is asking for you. Wired today, from the terminal bell: an agent
    /// REPL blocked on a prompt beeps, and `\a` is the one attention signal that
    /// crosses a pty without shell integration. Ranked highest because it is the only
    /// state where the program is *waiting* rather than reporting.
    case attention = 4

    static func < (lhs: DocumentStatus, rhs: DocumentStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Spoken by VoiceOver as part of the tab's label. Nil for `.idle` — appending
    /// "idle" to every tab is noise, and the absence is the information.
    var accessibilityDescription: String? {
        switch self {
        case .idle: return nil
        case .running: return "running"
        case .succeeded: return "finished"
        case .failed: return "failed"
        case .attention: return "needs attention"
        }
    }
}

/// One document inside a Space — what a tab in the in-window strip points at.
///
/// This protocol is the entire point of the (C) restructure (plan §12.3). Terax's
/// tab strip is a flat *heterogeneous* union of eight kinds — terminal, editor,
/// preview, markdown, and four diff/history kinds — all in ONE strip
/// (`terax-ai/src/modules/tabs/lib/useTabs.ts:114-122`). Native macOS window tabs
/// cannot express that, because a window tab **is** an `NSWindow`: an editor tab
/// beside a terminal tab would be a second window with its own `contentView`,
/// hence no shared sidebar and no project-level grouping (plan §12.2). So
/// documents get a custom strip, and this protocol is the seam they plug into.
///
/// `TerminalPane` was the only conformer until `FileViewerPane` landed, and that
/// mattered more than it looked: a protocol with one implementor is a *description*
/// of that implementor, not a proven seam. Extracting the second one found three
/// places where the container had quietly stayed terminal-shaped —
/// `SpaceViewController.apply(config:)` fanned out over `terminalPanes` only, the
/// file-tree handler reached for `activeTerminalPane`, and `AppDelegate`'s zoom
/// anchored on `[TerminalPane]`. All three would have compiled and rendered fine
/// with a second document kind installed, and silently done nothing to it.
///
/// Hence the appearance and zoom members below are **hard requirements with no
/// default implementations**, deliberately. A default no-op would restore exactly
/// the failure mode just removed: a future editor/diff conformer that forgets font
/// zoom would compile, render, and ignore ⌘+ forever. Requiring them
/// turns that into a build error at the moment the conformer is written.
@MainActor
protocol SpaceDocument: AnyObject {
    /// Deliberately *not* named `view`. `TerminalPane.view` is an
    /// `GoblinPortalTerminalView`, and Swift does not permit a subclass type to witness a
    /// get-only property requirement declared as the supertype — so naming this
    /// `view` would force a pointless type-erasing shim on every conformer.
    var documentView: NSView { get }

    var documentTitle: String { get }

    /// SF Symbol drawn in the tab, so terminal / editor / diff tabs are
    /// distinguishable at a glance once the strip is genuinely mixed.
    var documentSymbolName: String { get }

    /// Called when this document becomes the visible one — the moment to take
    /// first responder, so typing lands in the terminal without a stray click.
    func documentDidBecomeActive()

    /// ⌘R reloaded `~/.config/goblin-portal/config.json`, or the Space handed over a new
    /// one. Every document paints, so every document owns re-reading its theme.
    func apply(config: AppConfig)

    /// The size this document is currently rendering at, so a zoom applied in one
    /// tab can be mirrored into the others (`AppDelegate.zoomAllDocuments`).
    var currentFontSize: CGFloat { get }

    /// `persist: false` is for applying someone else's already-stored zoom (a
    /// reload, or a newly-opened tab) — only a real user gesture should write.
    func setFontSize(_ size: CGFloat, persist: Bool)

    /// ⌘0 — back to the configured size, dropping the stored zoom.
    func resetFontSize()

    /// The Space's window became key. Default no-op: this exists because the thing
    /// mutating these files is an agent running in the terminal beside them, so
    /// "you came back to this window" is almost exactly the moment a document's
    /// content is stale — the same reasoning as `FileTreeViewController.refresh()`.
    /// A terminal is fed by its pty and needs nothing; a file viewer needs to
    /// re-read or it quietly shows you a file that no longer exists on disk.
    func documentWindowDidBecomeKey()

    /// Unsaved changes, drawn as a dot in the tab strip.
    var documentIsEdited: Bool { get }

    /// What this document currently wants the user to know, drawn in the tab strip.
    ///
    /// On the protocol rather than on `TerminalPane` because it is not a terminal
    /// concept: a file viewer whose file was rewritten under it is in exactly the same
    /// position — something happened in a tab you are not looking at. Engine-agnostic
    /// for the same reason the zoom members are (see the note above): a status enum
    /// shaped around any one engine's callbacks would be rewritten if the engine changed.
    var documentStatus: DocumentStatus { get }

    /// Retire whatever `documentStatus` was trying to say — the user is looking now.
    ///
    /// On the protocol so the container can retire a mark without naming a pane type.
    /// PR #21 review item 1 made `isActiveDocument` window-aware: a mark can now be raised
    /// while the whole app is in the background, including on the tab the user returns to,
    /// and `windowDidBecomeKey()` is the only hook that sees that return.
    func clearAttention()

    /// Propagate a window-level focus change to the terminal (DECSET 1004). SwiftTerm
    /// fires `setTerminalFocus` only from first-responder changes; switching macOS
    /// window tabs without cycling first-responder leaves tmux focus-events blind.
    /// Non-terminal documents inherit the default no-op.
    func notifyWindowFocus(_ focused: Bool)

    /// Return false to veto a close (⌘W, the tab's ×, closing the Space, quitting).
    /// Implementors that can hold unsaved work MUST prompt here — every close path
    /// in the app funnels through it, so this is the single choke point between a
    /// dirty buffer and silent data loss.
    func documentShouldClose() -> Bool

    /// The close is committed: release anything ARC will not.
    ///
    /// The pair to `documentShouldClose()` above — that one *asks*, this one *commits*.
    /// Called from `closeDocument(at:)` (⌘W, the tab's ×, a shell that exited) and from
    /// `tearDownAllDocuments()` (⌘⇧W). MUST be idempotent: those two paths do not
    /// overlap today, but the second exists precisely because AppKit will not promise
    /// which of them fires on quit.
    ///
    /// A hard requirement with **no default implementation**, and that is the whole
    /// design. A default no-op would let a future conformer that holds a manually-freed
    /// resource compile, run, and leak — which is exactly what happened: SwiftTerm's
    /// `terminate()` must send SIGHUP explicitly (the shell ignores SIGTERM, and
    /// `io?.close()` defers `close(fd)` to a DispatchIO cleanup handler that waits behind
    /// a never-finishing streaming read), so omitting this call leaked the shell process
    /// until quit. `deinit` cannot substitute: these are `@MainActor` types, and Swift 6
    /// does not let a `deinit` reach MainActor state.
    ///
    /// Requiring it also forces the question to be answered in each conformer's own file,
    /// where the answer belongs — including the two conformers whose honest answer is
    /// "nothing", which is worth one line of *why* rather than silence.
    func documentWillClose()

    /// ⌘S. Returns false if the save failed or the user cancelled.
    func saveDocument() -> Bool
}

/// What a document tells its Space when something happened to it that the container
/// has to react to.
///
/// Declared here, beside `SpaceDocument`, because these are document-level events, not
/// terminal-level ones — the container's reaction to each is already kind-agnostic
/// (`syncDocumentChrome()`, `closeDocument(at:)`). This was `TerminalPaneDelegate` in
/// `TerminalPane.swift` and typed all three callbacks to the concrete class, which gave
/// a second document kind *no route to the container at all* for shell-exit and
/// title-change — and title changes drive both the strip and the window subtitle.
/// Widening it and moving it here is what makes those signals reachable from any
/// document kind, not just TerminalPane.
///
/// The parameter type is `SpaceDocument` rather than `ShellHosting` even though only a
/// shell-backed pane emits these today: "my title changed" and "I am finished" are not
/// shell concepts. A file viewer that grew a background reload would report through
/// exactly these callbacks, and narrowing the parameter now would be a second migration
/// later for no gain — the reverse of the `focusedShellHost` decision below, where the
/// *action* genuinely requires a shell.
///
/// Deliberately unrelated to `FileViewerPaneDelegate`, which is repaint-only and stays
/// where it is: merging them would make every conformer answer callbacks for a concern
/// it does not have. Two narrow inbound protocols is the correct shape while their
/// event sets are disjoint.
@MainActor
protocol SpaceDocumentDelegate: AnyObject {
    /// The document's work is over and it should be closed — a shell exited. Named for
    /// the document rather than the pane because the container closes *a tab*, and it
    /// looks the document up by identity rather than trusting an index
    /// (`SpaceViewController+Delegates.swift`).
    func documentDidTerminate(_ document: SpaceDocument)

    /// The document reported a new title (OSC 0/2 for a shell). Drives the tab strip
    /// and, when this is the active document, the window subtitle.
    func document(_ document: SpaceDocument, didChangeTitle title: String)

    /// `documentStatus` changed — the tab strip needs to repaint.
    func documentDidChangeStatus(_ document: SpaceDocument)
}

/// A document that reports the events above, exposing the slot its Space writes itself
/// into.
///
/// Exists so `SpaceViewController.add(document:)` can wire the delegate on any reporting
/// conformer without naming one: the alternative it replaced was
/// `(document as? TerminalPane)?.delegate = self`, which compiles and then silently
/// leaves a second engine-backed pane's delegate nil — a tab that renders and never
/// retitles, which is precisely the "silently inert rather than loudly broken" class
/// `emulator-foundation-probe-and-vendor-integrity.md` §8.2 catalogues. Any future
/// conformer is wired by that same line, at no cost to the container.
///
/// Separate from `SpaceDocument` rather than a member of it because it is genuinely
/// optional: `FileViewerPane` reports edited-state through its own repaint-only
/// `FileViewerPaneDelegate` and has no use for these three callbacks, and a required
/// slot it left nil would be a member that lies. This is the same reasoning the zoom
/// members get in reverse — they are required because a conformer that skips them is
/// *broken*, while a conformer that skips this one is merely quiet.
@MainActor
protocol SpaceDocumentReporting: SpaceDocument {
    /// Named `documentDelegate`, not `delegate`, because conformers are AppKit-adjacent
    /// types that may already own a `delegate` meaning something else entirely — and a
    /// protocol requirement silently witnessed by an unrelated inherited property is a
    /// bug with no compiler error attached.
    var documentDelegate: SpaceDocumentDelegate? { get set }
}

extension SpaceDocument {
    /// The four defaults below are all *correct* for a live document rather than
    /// merely convenient, which is what separates them from the zoom members above:
    /// a terminal has nothing to re-read, no buffer to lose, and nothing to write.
    /// A conformer that ignores them is right by default, not broken by default.
    func documentWindowDidBecomeKey() {}
    var documentIsEdited: Bool { false }
    func documentShouldClose() -> Bool { true }
    func saveDocument() -> Bool { true }

    /// `.idle` is the honest answer for a document that cannot produce a status, which
    /// is why this one gets a default while the zoom members do not: a conformer that
    /// never has anything urgent to say is correctly silent, not silently broken.
    var documentStatus: DocumentStatus { .idle }

    /// Paired with that default: a document with nothing to say has nothing to retire.
    /// `TerminalPane` overrides with `status = .idle`; non-terminal documents inherit this.
    func clearAttention() {}
    /// No-op for non-terminal documents; terminal panes override to forward focus events.
    func notifyWindowFocus(_ focused: Bool) {}
}
