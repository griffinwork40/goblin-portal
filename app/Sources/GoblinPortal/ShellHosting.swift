//
//  ShellHosting.swift
//  A document that hosts a live shell, and the one thing you are allowed to say to it.
//
//  Its own file, holding the protocol *and* `TerminalPane`'s conformance, for two
//  reasons. The first is the ceiling: `TerminalPane.swift` sits at 336/350 lines
//  (AFK.md, "Conventions"), so a concern that merely *plugs into* it belongs beside
//  it rather than inside it — the same call `FileViewerPane+Document.swift` makes for
//  the `SpaceDocument` conformance. The second is that a protocol with exactly one
//  member and one conformer is readable end to end in one screen only while both
//  halves sit together; `SpaceDocument.swift` is the precedent (it declares the
//  protocol and carries `TerminalPane`'s conformance in the same file).
//
//  Why this exists at all: the container needs to answer "which of these documents
//  can I write shell input to?" without naming a concrete pane type. That question
//  used to be answered by a cast to `TerminalPane`
//  (`SpaceViewController.focusedTerminalPane`, pre-change), which blocked a second
//  engine-backed document kind — the whole subject of
//  `.afk/plans/libghostty-swap-sequencing-2026-07-28.md` §2.
//
//  Why it is NOT answered by widening that cast to `SpaceDocument`: a shell-directed
//  action must land in a *shell*. `SpaceDocument` is satisfied by `FileViewerPane`,
//  so widening would let the file tree's "insert path" inject a filesystem path into
//  a text-editor buffer as if the user had typed it there — a silent data-corrupting
//  wrong target, not a cosmetic mistake. §2's "the one cast that must NOT widen to
//  `SpaceDocument`" and `next-sequencing-2026-07-28.md` §1's closing note both land
//  on a *narrower* protocol instead, which is this one.
//

import AppKit
import SwiftTerm

/// A `SpaceDocument` whose content is a live shell you can write input to.
///
/// Refines `SpaceDocument` rather than standing alone as an `AnyObject` protocol so
/// that "hosts a shell" cannot be claimed by something that is not a document in the
/// first place, and so the container can act on one without casting back: the
/// file-tree handler both writes to the host and brings its tab forward
/// (`documentDidBecomeActive()`, a `SpaceDocument` member), and a bare protocol would
/// have forced an `as? SpaceDocument` there — reintroducing a silent-failure branch
/// on the exact path this protocol exists to make total.
///
/// Two members, and the second one arrived for a reason worth stating, because this
/// comment used to say "deliberately one member" and that the value of the seam is
/// inversely proportional to its width. That principle still holds — it is why this is
/// not a general-purpose "terminal" protocol — but it argues for *narrow*, not for
/// *frozen*. `currentDirectory` earns its place because a working directory is not an
/// extra capability bolted onto a shell: it is a property a shell intrinsically HAS and
/// nothing else here does. `SpaceDocument` cannot answer it (a file viewer has a file,
/// not a cwd), and the alternative was for the container to reach past this protocol to
/// a concrete pane's pty — reintroducing exactly the cast this file exists to delete.
///
/// The two members are also inverses, which is the test for whether a member belongs:
/// `currentDirectory` reads where the shell is, `send(text:)` moves it. cwd-follow needs
/// both halves and nothing more. A second conformer would satisfy the whole feature —
/// path-insert, `cd Here`, and sidebar-follows-shell — by answering just these two,
/// reading its cwd from the engine's own pwd delegate instead of from `proc_pidinfo`.
///
/// `FileViewerPane` must still never conform. That was true when this protocol had one
/// member and the second makes it more true, not less: a file viewer asked for a working
/// directory would have to invent one.
///
/// `FileViewerPane` must never conform. That is not enforceable by the compiler, so
/// it is stated here and in the header above: the conformance list *is* the
/// specification of "what counts as a shell".
@MainActor
protocol ShellHosting: SpaceDocument {
    /// Write `text` to the shell's input as if the user had typed it.
    ///
    /// Labelled `text:` and not SwiftTerm's own `txt:` on purpose. This member is the
    /// line the caller stops crossing: `SpaceViewController+Delegates.swift` used to
    /// call `pane.view.send(txt:)` — a SwiftTerm-concrete API reached through a
    /// concrete pane's concrete view — which meant the file-tree feature was coupled
    /// to the emulator, not to the idea of a shell (plan §2, "Note also that
    /// `pane.view.send(txt:)` is a **SwiftTerm-concrete** call"). A second engine-backed
    /// conformer would satisfy this through the engine's own text-write API instead.
    ///
    /// No newline is implied — the caller decides whether the text is submitted or
    /// left on the prompt for editing. The one caller today deliberately leaves it
    /// unsubmitted, because inserting a path is for composing a command, not running
    /// one.
    func send(text: String)

    /// Where this shell currently is, or nil when that cannot be answered.
    ///
    /// Nil is normal and expected, not a failure to report: a pane that has not started
    /// its process yet has no cwd, and neither does one whose shell has exited but whose
    /// tab has not closed. Callers must hold their last good value rather than react to
    /// nil — blanking the sidebar because a shell exited is worse than showing a
    /// directory that is one `exit` stale.
    ///
    /// A *property*, not a `directoryDidChange` callback, because polling is the fallback
    /// rather than the primary path. OSC 7 — the notification-shaped answer, which SwiftTerm
    /// already parses into `hostCurrentDirectoryUpdate` — fires whenever the user sources
    /// `shell-integration.zsh`, which emits `ESC ] 7 ; file://hostname/path BEL` in its
    /// precmd hook. `TerminalPane.handleOsc7Directory` (in `TerminalPane+ShellIntegration.swift`)
    /// fills that body and stores the path in `_reportedDirectory`. Without the script, a stock
    /// zsh under Goblin Portal emits no OSC 7 (macOS's emitter is gated on `TERM_PROGRAM == Apple_Terminal`,
    /// which SwiftTerm does not set — documented at length in `ShellDirectory.swift`'s header),
    /// so the kernel poll remains the honest shape for unintegrated shells. `currentDirectory`
    /// prefers the OSC 7 value and falls back to the kernel poll, and
    /// `SpaceViewController+DirectoryFollow.swift` owns that polling timer.
    var currentDirectory: URL? { get }
}

// MARK: - TerminalPane

extension TerminalPane: ShellHosting {
    /// Forwards to SwiftTerm's `send(txt:)` (`vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift:2259`),
    /// which writes the string to the pty as input — indistinguishable to the shell
    /// from typing, so it lands on the prompt and is subject to normal line editing.
    func send(text: String) {
        view.send(txt: text)
    }

    /// Where this pane's shell currently is.
    ///
    /// **Primary source: OSC 7** (when the user sources `shell-integration.zsh`).
    /// `_reportedDirectory` is populated by `TerminalPane.handleOsc7Directory` every
    /// time the shell emits `ESC ] 7 ; file://… BEL` in its precmd hook. That answer
    /// is exact, instant, and requires no syscalls — it is the path the shell actually
    /// has, not the path the kernel thinks the foreground process has.
    ///
    /// **Fallback: kernel poll** (when OSC 7 is absent — shells that have not sourced
    /// the integration script, or between two consecutive OSC 7 reports while a
    /// command is running). `ShellDirectory.current` asks `tcgetpgrp` + `proc_pidinfo`
    /// for the foreground process group's cwd — the same mechanism that has always
    /// driven `SpaceViewController+DirectoryFollow.swift`'s 750ms timer.
    ///
    /// `view.process` is SwiftTerm's `LocalProcess!`
    /// (`MacLocalTerminalView.swift:69`), nil before `startProcess`, so it is bound
    /// with `guard let` rather than force-unwrapped: a tab that has not started yet
    /// must answer nil rather than trap.
    var currentDirectory: URL? {
        // OSC 7 is primary — prefer an already-normalised shell-reported path.
        if let reported = _reportedDirectory {
            return URL(fileURLWithPath: reported)
        }
        // Kernel fallback — works on any shell regardless of integration script.
        guard let process = view.process else { return nil }
        return ShellDirectory.current(
            foregroundOf: process.childfd, fallbackPid: process.shellPid)
    }
}

// MARK: - Window-level focus events (DECSET 1004)

extension TerminalPane {
    /// Forward a window-level key notification to SwiftTerm's focus-events machinery.
    ///
    /// SwiftTerm wires `setTerminalFocus` only from `becomeFirstResponder`/
    /// `resignFirstResponder` (`MacTerminalView.swift:1010-1027`). That is correct for
    /// first-responder changes within a window but misses the macOS window-tab case:
    /// switching Spaces fires `windowDidBecomeKey`/`windowDidResignKey` WITHOUT cycling
    /// first responder, so tmux with `focus-events on` never sees the gain or loss, and
    /// vim/neovim's `FocusGained`/`FocusLost` autocommands silently stop working.
    ///
    /// Called for every document in the Space — not just the active one — because the
    /// focused pane is the one currently the first responder and SwiftTerm gates the
    /// actual send on `sendFocus` (DECSET 1004): a pane that has not enabled focus
    /// events is a no-op regardless (`Terminal.swift:578-583`).
    ///
    /// Placed here rather than in `TerminalPane.swift` because that file sits at
    /// 346/350 lines — four lines of headroom, not enough for this block and its
    /// doc comment. `ShellHosting.swift` already carries the `TerminalPane` shell-
    /// capability conformance and is the correct file for a second TerminalPane
    /// concern that would otherwise push the main file past the ceiling.
    func notifyWindowFocus(_ focused: Bool) {
        view.getTerminal().setTerminalFocus(focused)
    }
}

// MARK: - Finding one in a Space

/// The container's shell-host queries, here rather than in `SpaceViewController.swift`
/// for the reason that file's own header gives for `DocumentAreaViewController`: this is
/// one whole concern ("which document can take shell input, and which one should"), and
/// the container was left with 12 lines of headroom under the 350-LOC ceiling by the
/// change that introduced them. Reading the fallback rule beside the protocol it selects
/// on is also simply better — the rule *is* the meaning of `ShellHosting`.
extension SpaceViewController {
    /// Every document that can accept shell input, in strip order.
    ///
    /// Typed by capability (`ShellHosting`) rather than by class (`TerminalPane`), which
    /// is the narrowest type that answers the only question asked of it. `TerminalPane`
    /// is still the sole conformer, so this is a pure retype with no behavioural delta —
    /// `compactMap` selects exactly the same documents in the same order.
    var shellHosts: [ShellHosting] { allDocuments.compactMap { $0 as? ShellHosting } }

    /// The shell a shell-directed action should land in.
    ///
    /// Falls back to the most recent shell in this Space rather than returning
    /// nil when the active document does *not* host one. Without the fallback,
    /// "insert this path into the shell" would do nothing whenever a file viewer
    /// happened to be the front tab — the failure would be invisible, and the
    /// feature would look broken exactly when the file tree is most in use.
    ///
    /// **Split-aware.** In a two-pane split both the primary and the peer are visible
    /// simultaneously; the right shell to target is whichever one holds the first
    /// responder. Walk the window's responder to find it: if it is a descendant of the
    /// peer's view, the peer wins; if it is a descendant of the primary's view (or
    /// neither, which is the non-split case), the existing active-document path applies.
    ///
    /// **Deliberately not widened to `SpaceDocument`.** This is the one cast in the
    /// container that must stay narrow: `FileViewerPane` satisfies `SpaceDocument`, so a
    /// `SpaceDocument?` here would let the file tree inject a filesystem path into a
    /// text-editor buffer as though the user had typed it — silent corruption of a
    /// document the user is editing, not a cosmetic miss. `ShellHosting` keeps the
    /// fallback total over shells only, which is exactly what the feature means
    /// (`libghostty-swap-sequencing-2026-07-28.md` §2; `next-sequencing-2026-07-28.md` §1).
    var focusedShellHost: ShellHosting? {
        // In a split, check whether the first responder lives in any peer's view.
        // Walk all split documents (main peer + any sub-split peers) so that focus
        // inside a nested quarter pane resolves to the right shell.
        if let active = activeDocument {
            let fr = view.window?.firstResponder
            for peer in allSplitDocuments(for: active) {
                if let host = peer as? ShellHosting, isDescendant(fr, of: peer.documentView) {
                    return host
                }
            }
        }
        return (activeDocument as? ShellHosting) ?? shellHosts.last
    }

    /// True when `candidate` is in the view subtree of `parent`.
    ///
    /// Walks the NSResponder chain rather than using isDescendant(of:) directly
    /// because firstResponder may be an NSView or an NSText that lives inside the
    /// terminal view hierarchy. Terminal engines manage their own internal first-responder
    /// views; this handles any of them without naming a specific engine type.
    func isDescendant(_ candidate: NSResponder?, of parent: NSView) -> Bool {
        var r: NSResponder? = candidate
        while let current = r {
            if let v = current as? NSView, v === parent || v.isDescendant(of: parent) {
                return true
            }
            r = current.nextResponder
        }
        return false
    }
}
