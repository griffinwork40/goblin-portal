//
//  TerminalPane+Document.swift
//  SpaceDocument conformance for the SwiftTerm terminal pane.
//
//  Parallel to `FileViewerPane+Document.swift`: each document kind carries its own
//  conformance in its own file. Extracted from `SpaceDocument.swift` when that file
//  hit the 350-line ceiling — the protocol and its supporting types stay there;
//  the per-conformer witnesses live here.
//

import AppKit

/// The stored `documentDelegate` property on `TerminalPane` is the whole witness, so this
/// is a declaration of intent rather than code: it is what makes
/// `SpaceViewController.add(document:)`'s conditional wire-up reach this pane.
extension TerminalPane: SpaceDocumentReporting {}

extension TerminalPane: SpaceDocument {
    var documentView: NSView { view }

    /// Falls back rather than rendering an empty tab: `currentTitle` stays empty
    /// until the shell emits OSC 0/2, which does not happen until the first prompt
    /// paints — so a brand-new tab would otherwise be a blank sliver.
    var documentTitle: String { currentTitle.isEmpty ? "Terminal" : currentTitle }

    var documentSymbolName: String { "terminal" }

    var documentStatus: DocumentStatus { status }

    func documentDidBecomeActive() {
        // The pane's own view, not the container: SwiftTerm reads key events on
        // the terminal view itself, and a container in the responder chain would
        // swallow the first keystroke.
        view.window?.makeFirstResponder(view)
        // You are now looking at it, so whatever it was trying to tell you has landed.
        // Here rather than in a focus notification because this is the one call that
        // means "this document is the visible one" — see `clearAttention()`.
        clearAttention()
    }

    /// Hang up the shell, then let SwiftTerm clean up its pty plumbing.
    ///
    /// **SwiftTerm's own `terminate()` does not end an interactive shell, and that is measured
    /// rather than suspected.** `check-pane-teardown.sh` was written expecting `view.terminate()`
    /// to be sufficient; it failed on the first run, and the shell was still alive **25 seconds**
    /// after the call — so this is "never", not "slow". Both halves of `terminate()` come up
    /// short against a login zsh:
    ///
    /// * `kill(shellPid, SIGTERM)` (`LocalProcess.swift:568`) — an interactive shell **ignores
    ///   SIGTERM by design**, which is the entire reason SIGHUP exists as the terminal's hangup
    ///   signal. Measured against `/bin/zsh -l` under a `pty.fork()`: after SIGTERM the shell sat
    ///   in state `Ss+`, alive; after SIGHUP it was gone.
    /// * `io?.close()` on the pty master (`:563`) — the real `close(fd)` is deferred to the
    ///   `DispatchIO` cleanup handler (`:530-534`), and a plain `close()` lets pending operations
    ///   finish first. The read on a live pty is a long-lived streaming read that never finishes,
    ///   so the descriptor is not closed and the shell never sees EOF. (`.stop` is the flag that
    ///   would make it prompt; that is upstream's call, not a local patch's.)
    ///
    /// Hence SIGHUP, explicitly, first. It is also the semantically exact thing to send: closing
    /// a terminal *is* a hangup, which is why `nohup` is named as it is. Sent to `shellPid` alone
    /// rather than the process group, deliberately — zsh HUPs its own jobs on receiving HUP, so
    /// the shell does its own cleanup, and signalling the group directly would take background
    /// jobs with it under a policy this app has never stated.
    ///
    /// `terminate()` still runs after it, for the DispatchIO teardown and the `running` flag; its
    /// comment about avoiding an `EV_VANISHED` crash by ordering the descriptor close correctly
    /// (`:558-561`) is worth keeping rather than reimplementing.
    ///
    /// The `running` guard is load-bearing and NOT defensive bookkeeping. `terminate()` gates its
    /// signal on `shellPid != 0` (`:567`), and `shellPid` is assigned exactly once at spawn
    /// (`:527`) and never cleared — `childStopped()` only sets `running = false` (`:269-277`). So
    /// a second call after the child was reaped (`waitpid`, `:368`) would signal a pid the OS is
    /// free to have reused, and that now applies to the SIGHUP above as much as to SwiftTerm's
    /// SIGTERM. `running` is the property that actually tracks liveness, it is flipped
    /// synchronously by `terminate()`, and guarding on it is what the vendor itself does before
    /// touching the pty (`Mac/MacLocalTerminalView.swift:98`). `check-pane-teardown.sh` case 4
    /// is what keeps this honest.
    func documentWillClose() {
        guard view.process.running else { return }
        kill(view.process.shellPid, SIGHUP)
        view.terminate()
    }
}
