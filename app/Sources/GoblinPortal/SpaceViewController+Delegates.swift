//
//  SpaceViewController+Delegates.swift
//  Everything that reaches a Space from somewhere else: the four delegate conformances.
//
//  One concern, not four. Each of these is the same sentence — "the user did
//  something in another view (the file tree, the tab strip, a pane's shell) and the
//  container has to react" — and each one forwards straight into the document API in
//  `SpaceViewController.swift`. Splitting them apart would scatter one story across
//  four files; leaving them in the container buried its actual job under a hundred
//  lines of inbound plumbing.
//
//  Note that nothing here narrows `SpaceDocument` to a concrete kind. The
//  `TerminalPane` and `FileViewerPane` parameters are imposed by *those* panes' own
//  delegate protocols — they are the callback's signature, not a cast in the
//  container — so the document list stays kind-agnostic and a new conformer still
//  costs this file nothing (`SpaceDocument.swift`, plan §12.3).
//

import AppKit

// MARK: - FileViewerPaneDelegate

extension SpaceViewController: FileViewerPaneDelegate {
    func fileViewerDidChangeEditedState(_ pane: FileViewerPane) {
        // Repaint chrome so the unsaved marker appears/disappears as you type — the
        // strip's dot when there is a strip, and the window's own close-button dot
        // always, which is the only indicator a lone unsaved document gets.
        syncDocumentChrome()
    }
}

// MARK: - DocumentTabStripDelegate

extension SpaceViewController: DocumentTabStripDelegate {
    func tabStrip(_ strip: DocumentTabStrip, didSelect index: Int) {
        selectDocument(at: index)
    }

    func tabStrip(_ strip: DocumentTabStrip, didRequestClose index: Int) {
        closeDocument(at: index)
    }

    func tabStripDidRequestNewDocument(_ strip: DocumentTabStrip) {
        addTerminalDocument()
    }
}

// MARK: - SpaceDocumentDelegate

extension SpaceViewController: SpaceDocumentDelegate {
    func documentDidTerminate(_ document: SpaceDocument) {
        // The shell exited — close that document specifically, not the active one:
        // a background tab's shell can exit while you are looking at another.
        if let index = documents.firstIndex(where: { $0 === document }) {
            closeDocument(at: index)
            return
        }
        // The document is a split PEER (not in documents[]). Collapse the split and
        // release the peer. terminateSplitPeer is defined in +Splits.swift, where the
        // splitPeers dictionary writer lives (private(set) setter is file-scoped to
        // SpaceViewController.swift, so removals must go through a method in that
        // extension file that mutates the dictionary indirectly via teardownSplit).
        terminateSplitPeer(document)
    }

    func document(_ document: SpaceDocument, didChangeTitle title: String) {
        syncDocumentChrome()
        guard documents.indices.contains(activeIndex), documents[activeIndex] === document else {
            return
        }
        spaceDelegate?.spaceViewController(self, didChangeDocumentTitle: document.documentTitle)
    }

    /// A background document raised or cleared an attention marker. Only the strip cares
    /// — the window title stays the active document's, because a background tab beeping
    /// must not relabel the window you are working in.
    func documentDidChangeStatus(_ document: SpaceDocument) {
        syncDocumentChrome()
    }
}

// MARK: - FileTreeViewControllerDelegate

extension SpaceViewController: FileTreeViewControllerDelegate {
    /// Double-click opens the file in a document tab — what every Mac user already
    /// means by double-clicking a row in a file tree.
    ///
    /// This used to type the path into the terminal instead, because there was no
    /// document kind to open a file *into*. That was an honest placeholder and a
    /// bad feature: a picker whose only effect is inserting text reads as broken to
    /// anyone who did not write it. `FileViewerPane` gives the tree somewhere to go.
    func fileTree(_ controller: FileTreeViewController, didActivate url: URL) {
        openFile(url: url)
    }

    /// The old behaviour, kept and given a name.
    ///
    /// Inserting a quoted path is genuinely useful — it is what you want while
    /// composing `nvim <path>` or `git add <path>` — it was just bound to the one
    /// gesture that means "open". Now it is ⌥-double-click and a context-menu item,
    /// which also makes it discoverable, which it never was.
    func fileTree(_ controller: FileTreeViewController, didRequestPathInsert url: URL) {
        // A Space with zero shell-hosting tabs (every document is a file viewer) has
        // nowhere for this to land — beep rather than silently doing nothing, so
        // the gesture doesn't read as broken (PR #2 review, finding 5).
        guard let host = focusedShellHost else {
            NSSound.beep()
            return
        }
        // Single-quoted, with any embedded quote closed-escaped-reopened, so spaces,
        // `$`, and quotes in a filename survive the shell verbatim.
        let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Through `ShellHosting.send(text:)` rather than the old `pane.view.send(txt:)`,
        // which reached a SwiftTerm-concrete API through a concrete pane's concrete view
        // and coupled this feature to the emulator (plan §2). Same bytes to the same pty;
        // the indirection is the whole change.
        host.send(text: quoted + " ")
        // Bring the shell forward if a viewer was in front, otherwise the text
        // lands in a tab the user cannot see.
        if let index = documents.firstIndex(where: { $0 === host }), index != activeIndex {
            selectDocument(at: index)
        } else {
            host.documentDidBecomeActive()
        }
    }

    /// "New Terminal Here" — the other half of rooting terminals properly.
    ///
    /// ⌘T uses the Space's root; this uses the directory you clicked, which is what
    /// you want the moment a project is more than one directory deep. `url` is already
    /// resolved to a directory by the tree (`FileTreeViewController.menuNewTerminal`),
    /// so there is deliberately no file/folder branch here.
    ///
    /// A new document every time rather than reusing an existing terminal on that
    /// path, which is the opposite of `openFile(url:)`'s reuse rule — and the
    /// difference is real, not an inconsistency: two viewers of one file show the same
    /// bytes twice, while two shells in one directory are two independent sessions
    /// (one running a server, one running git) and collapsing them would destroy work.
    func fileTree(_ controller: FileTreeViewController, didRequestNewTerminalAt url: URL) {
        addTerminalDocument(workingDirectory: url)
    }

    /// "cd Here" — the UI-to-shell half of cwd-follow.
    ///
    /// Note what this deliberately does NOT do: it never calls
    /// `FileTreeViewController.setRoot(_:)`. It writes a `cd` to the shell and stops, and
    /// the sidebar moves later, only once the poller in
    /// `SpaceViewController+DirectoryFollow.swift` observes that the shell really did
    /// change directory. That is the whole safety argument for this feature. If a click
    /// moved the tree directly there would be two writers of "where are we" — the click
    /// and the shell — and they would disagree the first time a `cd` failed (a directory
    /// deleted between the tree reading it and the shell entering it, or one without `+x`),
    /// leaving the sidebar showing a place the shell is not. Routing every navigation
    /// through the shell makes the shell the single source of truth, so the sidebar cannot
    /// lie, and a `cd` that fails simply leaves the tree where it was. It also cannot loop:
    /// `setRoot(_:)` early-returns on an unchanged path, and `ShellDirectory` normalises
    /// both sides to one spelling so "unchanged" is decidable.
    ///
    /// `url` is already resolved to a directory by the tree
    /// (`FileTreeViewController.menuChangeDirectory`), so there is no file/folder branch
    /// here — same division of labour as `didRequestNewTerminalAt` above.
    func fileTree(_ controller: FileTreeViewController, didRequestChangeDirectory url: URL) {
        // Same beep-rather-than-silence rule as `didRequestPathInsert`: a Space whose every
        // tab is a file viewer has no shell to redirect, and a menu item that quietly does
        // nothing reads as broken (PR #2 review, finding 5).
        guard let host = focusedShellHost else {
            NSSound.beep()
            return
        }
        // Submitted, unlike path-insert, which leaves its text on the prompt. The
        // difference is intent: inserting a path is for composing a command, while "cd
        // Here" IS the command — leaving it unsubmitted would make the menu item look
        // broken until the user also pressed Return. Quoting and the newline both come
        // from `ShellDirectory.cdCommand(to:)` so there is one shell-quoting rule in the
        // app rather than a second copy of the one above.
        host.send(text: ShellDirectory.cdCommand(to: url))
        // Bring the shell forward if a viewer was in front — a `cd` that lands in an
        // invisible tab looks like nothing happened.
        if let index = documents.firstIndex(where: { $0 === host }), index != activeIndex {
            selectDocument(at: index)
        } else {
            host.documentDidBecomeActive()
        }
    }
}
