//
//  TerminalPane.swift
//  One terminal: a SwiftTerm view bound to one login shell.
//

import AppKit
import SwiftTerm

/// A single terminal pane.
///
/// Owns the SwiftTerm view and the shell process, and applies config/theme.
/// Deliberately does NOT know about tabs or windows — that is the window
/// controller's job — so panes stay reusable for splits later.
/// `@preconcurrency` on the SwiftTerm conformance: SwiftTerm predates Swift
/// concurrency annotations, so its delegate protocol is non-isolated even though
/// it is an AppKit view that only ever calls back on the main thread. Without it,
/// Swift 6 rejects a `@MainActor` conformer outright. This keeps the isolation
/// guarantee as a runtime check instead of a compile error, which is the
/// sanctioned migration path for an un-annotated dependency.
@MainActor
final class TerminalPane: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let view: GoblinPortalTerminalView
    private(set) var currentTitle: String = ""
    /// The container, reached through the document-level protocol declared in
    /// `SpaceDocument.swift` rather than a terminal-specific one. Moved there when the
    /// callbacks stopped naming this class, so any document kind can report the same
    /// events without a parallel delegate. Named `documentDelegate` to witness
    /// `SpaceDocumentReporting` — see that protocol for why the generic name was rejected.
    weak var documentDelegate: SpaceDocumentDelegate?

    /// What the tab strip should be saying about this pane.
    ///
    /// All five `DocumentStatus` states are reachable: `.idle` (default), `.attention`
    /// (bell), `.running` (OSC 133 C via `State.onCommandStarted`), `.succeeded`/`.failed`
    /// (OSC 133 D via `applyCommandOutcome`). See `TerminalPane+ShellIntegration.swift`.
    // Internal setter: cross-file extension `TerminalPane+ShellIntegration` sets this.
    var status: DocumentStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            documentDelegate?.documentDidChangeStatus(self)
        }
    }

    // `internal` (not `private`) so `TerminalPane+Typography.swift` can read/write
    // these in the same module across files — Swift `private` is file-scoped, not
    // class-scoped, so a cross-file extension cannot reach a `private` stored property.
    var config: AppConfig
    var fontSize: CGFloat

    /// The directory this terminal's shell starts in — the Space's project root for
    /// ⌘T, a subdirectory of it for the tree's "New Terminal Here"
    /// (`SpaceViewController.addTerminalDocument(start:workingDirectory:)`).
    ///
    /// Stored as a property of the *pane* rather than taken as a `start()` argument
    /// on purpose, and that is the engine-agnostic half of this fix. A second engine-backed
    /// pane would read this same property and hand it to the engine's own surface
    /// configuration (`.afk/plans/emulator-foundation-probe-and-vendor-integrity.md` §6.2).
    /// Keeping the root out of the SwiftTerm-specific call site is what makes that a
    /// one-line swap.
    private let workingDirectory: URL

    /// `workingDirectory` is deliberately **not** defaulted, and deliberately **not**
    /// optional: a terminal that does not know its root is the bug this parameter
    /// exists to fix, so a call site with no opinion should fail to compile rather
    /// than silently inherit the app's own cwd. Optional would have re-opened that
    /// hole at runtime for a caller that passed `nil` to make the compiler quiet —
    /// and there is no such caller to serve, because the primary one resolves
    /// the default itself (`addTerminalDocument` passes
    /// `workingDirectory ?? focusedShellHost?.currentDirectory ?? root`, and `root`
    /// is non-optional — see `SpaceViewController+DocumentConstruction.swift` for the
    /// three-level chain and why each fallback exists). Split construction paths in
    /// `SpaceViewController+Splits.swift` also resolve the directory before calling
    /// init directly.
    init(config: AppConfig, frame: NSRect, workingDirectory: URL) {
        self.config = config
        self.workingDirectory = workingDirectory
        // A zoom set with ⌘+ applies to every pane, including ones opened later
        // and ones opened in a future launch — so a new tab never springs back to
        // the configured size while the tab beside it stays zoomed.
        self.fontSize = FontZoom.override ?? config.font.pointSize
        // LocalProcessTerminalView only exposes init(frame:) — the font-taking
        // initialiser belongs to TerminalView and is not inherited here, so the
        // font is applied via the property in apply(config:) below.
        self.view = GoblinPortalTerminalView(frame: frame)
        super.init()
        view.processDelegate = self
        // Separate from `processDelegate` because the bell is not on
        // `LocalProcessTerminalViewDelegate` at all — see `GoblinPortalTerminalView.bellDelegate`
        // for the four members it does carry and why reaching the bell needs a subclass
        // override rather than a delegate slot.
        view.bellDelegate = self
        view.autoresizingMask = [.width, .height]
        apply(config: config)
    }

    /// Start the user's login shell in `workingDirectory`. `-l` so their real PATH and
    /// rc files load — without it, tools installed via Homebrew or a node version
    /// manager are missing and the terminal is useless for actual work.
    ///
    /// The working directory goes through SwiftTerm's own `currentDirectory:`
    /// parameter, which it has: `MacLocalTerminalView.swift:175` forwards it to
    /// `LocalProcess.startProcess` (`LocalProcess.swift:383`) and on into
    /// `PseudoTerminalHelpers.fork` (`Pty.swift:60`), which `chdir()`s **inside the
    /// forked child, between `forkpty` and `execve`** (`Pty.swift:101-106`). So this
    /// is a real per-process cwd, not a `cd` typed into the shell: nothing is written
    /// to the user's scrollback or shell history, and there is no window where the
    /// prompt shows the wrong directory. The rejected alternatives were feeding
    /// `cd '<path>'\n` (visible, racy against rc-file output, and it would land in
    /// `HISTFILE`) and setting `PWD` in the environment (a lie — `PWD` is a shell
    /// convention, the process cwd would still be wrong, so `$(pwd)` and every
    /// relative path would disagree with the prompt).
    ///
    /// Passing `nil` reproduces the old behaviour exactly — SwiftTerm skips the
    /// `chdir` entirely when the parameter is nil (`Pty.swift:101-104`) — so an
    /// unrooted pane inherits the app process's cwd as before.
    func start() {
        var env = Terminal.getEnvironmentVariables()
        env.append("TERM_PROGRAM=GoblinPortal")
        env.append("TERM_PROGRAM_VERSION=0.1")
        appendShellIntegrationEnv(&env)  // GOBLIN_PORTAL_INTEGRATION — see TerminalPane+ShellIntegration
        view.startProcess(executable: config.shell, args: ["-l"],
            environment: env, currentDirectory: resolvedWorkingDirectory())
        applyCursorStyle(config.cursorStyle)
        registerShellIntegration()       // OSC 133 — see TerminalPane+ShellIntegration
    }

    /// The cwd to hand the shell, or nil to let it inherit the app's.
    ///
    /// Checked rather than passed through blind because SwiftTerm **discards the
    /// `chdir` result** — `Pty.swift:103` is `_ = chdir(cCurrentDirectory)`, in the
    /// forked child where there is no way to report anything back — so a root that
    /// has been deleted or renamed since the Space opened would start the shell in
    /// the app process's cwd with no error anywhere. A persisted root makes that a
    /// live case, not a theoretical one: `LastSpaceRoot` restores a directory across
    /// launches, and directories get moved between them. Failing soft to the same
    /// place, but *saying so* under `GOBLIN_PORTAL_DIAG`, matches `AppConfig.load()`'s
    /// per-field contract: degrade, warn, never throw.
    ///
    /// The predicate itself is `FileManager.isUsableSpaceRoot(atPath:)` rather than an
    /// inlined `fileExists(atPath:isDirectory:)` — a third caller of the rule that
    /// `Defaults.swift:96` already warns about duplicating ("two copies of a
    /// check-don't-trust rule is two places for it to drift"). Same question, one
    /// answer: a remembered root can be replaced by a *file* of the same name, and
    /// that has to read as unusable here exactly as it does for Space restore.
    private func resolvedWorkingDirectory() -> String? {
        // `.path`, not `absoluteString`: `chdir()` takes a filesystem path, and a
        // `file://` URL string with percent-escapes is not one.
        let path = workingDirectory.standardizedFileURL.path
        guard FileManager.default.isUsableSpaceRoot(atPath: path) else {
            if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
                FileHandle.standardError.write(
                    "[diag] pane root not a usable directory, shell will inherit app cwd: \(path)\n"
                        .data(using: .utf8)!)
            }
            return nil
        }
        return path
    }

    // MARK: - Appearance

    func apply(config: AppConfig) {
        self.config = config

        // Keep the historical xterm 6x6x6 cube and greyscale ramp for indices
        // 16–255. SwiftTerm defaults to `.base16Lab`, which *derives* those 240
        // colours by interpolating between this terminal's background and
        // foreground (`Terminal.swift:725` rebuildAnsiPalette), so any
        // 256-colour TUI renders against synthesised approximations rather than
        // the values it was actually designed for — and every other terminal
        // (Ghostty, iTerm2, Terminal.app) shows the standard cube. Set this
        // before any colour below: under `.xterm`, installing colours stops
        // triggering a palette rebuild altogether (`Terminal.swift:523`).
        view.getTerminal().ansi256PaletteStrategy = .xterm

        // A nil theme means "install nothing", leaving SwiftTerm's own defaults
        // in place — which is the default configuration. Setting a background or
        // foreground is not free (see above), so we only pay for it on request.
        if let theme = config.theme {
            view.nativeBackgroundColor = theme.background
            view.nativeForegroundColor = theme.foreground
            view.caretColor = theme.cursor
            // installColors is a no-op unless the array is exactly 16 long; Config
            // guarantees that invariant before we get here.
            view.installColors(theme.ansi.map { $0.asSwiftTermColor })
        }
        // Theme-aware selection (#31). Both bg+fg required: SwiftTerm replaces both
        // unconditionally (AppleTerminalView.swift:751-752). Nil → system pair.
        let sel = config.effectiveSelectionColors()
        view.selectedTextBackgroundColor = sel?.background ?? NSColor.selectedTextBackgroundColor
        view.selectedTextForegroundColor = sel?.foreground ?? NSColor.selectedTextColor
        view.optionAsMetaKey = config.optionAsMeta
        view.allowMouseReporting = config.mouseReporting
        view.smoothScrollEnabled = config.smoothScrolling
        view.changeScrollback(config.scrollback == 0 ? nil : config.scrollback)
        applyRenderer(config.renderer)  // must precede the font — see applyRenderer(_:)
        // Re-resolve rather than reusing `fontSize`, so editing `font.size` and
        // hitting ⌘R actually changes the size. A live ⌘+ zoom still outranks the
        // file — ⌘0 drops it and hands control back to the config.
        setFontSize(FontZoom.override ?? config.font.pointSize, persist: false)
        applyTypography(config)  // lineHeight + fontThicken — must follow setFontSize; see TerminalPane+Typography.swift
        view.configureSmoothScroll()  // cellHeight depends on font size — must follow setFontSize
        // `GOBLIN_PORTAL_DIAG=1` dumps the resolved appearance to stderr — the only
        // observability for a project with no test target. Costs nothing unset.
        if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
            let t = view.getTerminal()
            // Projected thumb once the scrollback is full — the steady state that
            // matters. `view.scrollThumbsize` right now is ~1.0 (empty buffer).
            let projected = max(CGFloat(t.rows) / CGFloat(config.scrollback + t.rows), 0.01)
            FileHandle.standardError.write("""
            [diag] theme=\(config.theme == nil ? "nil(SwiftTerm-defaults)" : "custom") \
            strategy=\(t.ansi256PaletteStrategy) scrollback=\(config.scrollback) \
            rows=\(t.rows) thumbNow=\(String(format: "%.3f", view.scrollThumbsize)) \
            thumbWhenFull=\(String(format: "%.4f", projected)) font=\(view.font.fontName) \
            size=\(view.font.pointSize) configSize=\(config.font.pointSize) \
            zoom=\(FontZoom.override.map { String(describing: $0) } ?? "none") \
            bgLuminance=\(String(format: "%.4f", config.effectiveBackground.relativeLuminance)) \
            chrome=\(config.appearance?.name.rawValue ?? "system") \
            windowChrome=\(view.window?.effectiveAppearance.name.rawValue ?? "unattached")\n
            """.data(using: .utf8)!)
        }
    }

    /// Cursor style is not settable through a public initialiser, so drive it the
    /// way any program would: the DECSCUSR sequence.
    ///
    /// The style→code mapping moved to `CursorStyle.decscusrCode` when the enum stopped
    /// being SwiftTerm's and became this project's own — it is the same table, and it now
    /// lives beside the cases it enumerates rather than in the one pane that happened to
    /// need it first.
    /// Module-qualified deliberately: this file imports SwiftTerm, which exports its own
    /// `public enum CursorStyle` (`vendor/SwiftTerm/Sources/SwiftTerm/TerminalOptions.swift:13`).
    /// Bare `CursorStyle` resolves correctly only by same-module shadowing, and
    /// `check-cursor-style.sh` compiles the enum standalone so it cannot see this collision at
    /// all. Spelling the module is what makes the right one an assertion rather than a default.
    private func applyCursorStyle(_ style: GoblinPortal.CursorStyle) {
        view.feed(text: "\u{1b}[\(style.decscusrCode) q")
    }

    // MARK: - Font sizing and typography — see TerminalPane+Typography.swift

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Intentionally empty. Kept as an explicit no-op rather than omitted so
        // it is obvious this is handled, not forgotten: SwiftTerm issue #494
        // (open) reports duplicate/orphan lines on narrowing reflow, and this is
        // the hook to instrument if that is ever observed here.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        currentTitle = title
        documentDelegate?.document(self, didChangeTitle: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 — forward to the shell-integration extension, which normalises and
        // stores the path so `ShellHosting.currentDirectory` prefers it over the
        // kernel poll. Full chain in `TerminalPane+ShellIntegration.swift`.
        handleOsc7Directory(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Does NOT set `.failed`: this fires when the *shell* exits (pane closing),
        // not when a command inside it fails. `.failed` comes from OSC 133 D.
        documentDelegate?.documentDidTerminate(self)
    }
}

// MARK: - Attention state

/// Everything the attention marker needs from the pane, kept in one extension at the
/// end of the file rather than beside the stored `status` above.
///
/// That placement is deliberate and not stylistic: `origin/afk/ux-space-root` (PR #3)
/// rewrites `init` and the whole doc comment on `start()` to thread a working directory
/// through, so anything added in the span between them collides with it for no reason —
/// two features that share no logic should not share a merge conflict. Verified with
/// `git merge-tree --write-tree HEAD origin/afk/ux-space-root`, which reports clean with
/// these members here and a `TerminalPane.swift` conflict with them above `start()`.
extension TerminalPane {
    /// The user is looking at this pane, so whatever it wanted to tell them has landed.
    ///
    /// Called from `documentDidBecomeActive()` (the `SpaceDocument` conformance), because
    /// becoming the visible document is exactly the moment the signal is consumed, and it
    /// is the same hook that already takes first responder. Also from the Space's
    /// `windowDidBecomeKey()`, which PR #21 review item 1 made reachable — see there.
    func clearAttention() {
        status = .idle
    }

    /// Is this the document the user is actually looking at? Two halves, both required.
    ///
    /// **Superview** — is this the presented document *in its Space*? Read from the view
    /// hierarchy rather than a flag, because the container already maintains that invariant:
    /// `present(documentView:)` removes every other document's view and adds the new one
    /// (`DocumentAreaViewController.present`), so having a superview *is* being presented. A
    /// cached flag would be a second copy of that fact with no "did become inactive" callback.
    ///
    /// **`isKeyWindow`** — is that Space on screen? A background Space's selected tab
    /// stayed true for the superview test alone, silently skipping the OSC 133 mark
    /// (PR #21 review, item 1). Both halves together make it window-aware.
    var isActiveDocument: Bool {
        view.superview != nil && view.window?.isKeyWindow == true
    }
}

// MARK: - GoblinPortalTerminalViewDelegate

extension TerminalPane: GoblinPortalTerminalViewDelegate {
    /// BEL is the one attention signal that crosses a pty with no shell integration at
    /// all, which is why it is the single wired case: an agent REPL blocked on a prompt
    /// beeps, and this app exists to host one.
    func terminalViewDidRingBell(_ view: GoblinPortalTerminalView) {
        // Not raised on the pane the user is already reading. The whole point of the
        // marker is to label a tab you are *not* looking at, and lighting up the front
        // tab would train the eye to ignore it.
        guard !isActiveDocument else { return }
        status = .attention
    }
}
