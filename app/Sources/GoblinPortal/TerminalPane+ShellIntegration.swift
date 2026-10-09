//
//  TerminalPane+ShellIntegration.swift
//  Wires OSC 7 and OSC 133 into TerminalPane — the AppKit-side counterpart to ShellIntegration.swift.
//
//  Why a separate file:
//  `TerminalPane.swift` sits at exactly 350 lines — the project ceiling (AFK.md,
//  "Conventions"). Adding anything there requires a split; this is it. The seam is
//  the same as `FileViewerPane+Document.swift`: the pane's *engine* lives in the main
//  file, its *protocol wiring* lives beside it.
//
//  Why two separate concerns are together:
//  OSC 7 (directory) and OSC 133 (command boundaries) are both shell-integration
//  signals — emitted by the same zsh script, consumed in the same pane lifecycle
//  moment (`start()`). Splitting them further would produce two ~30-line files for
//  one feature, which costs more seam than it saves.
//
//  OSC 7 callback chain (SwiftTerm already handles parsing):
//    EscapeSequenceParser.dispatchOsc(case 7) [EscapeSequenceParser.swift:530]
//      → Terminal.oscSetCurrentDirectory     [Terminal.swift:1729]
//        → Terminal.hostCurrentDirectory = … [Terminal.swift:1740]
//        → tdel?.hostCurrentDirectoryUpdated [Terminal.swift:1741]
//      → AppleTerminalView.hostCurrentDirectoryUpdated [AppleTerminalView.swift:399]
//        → terminalDelegate?.hostCurrentDirectoryUpdate [AppleTerminalView.swift:401]
//      → TerminalPane.hostCurrentDirectoryUpdate  ← FILLED BELOW (was empty)
//
//  OSC 133 callback chain (SwiftTerm has no built-in parser for code 133):
//    EscapeSequenceParser.dispatchOsc → oscHandlers[133] [EscapeSequenceParser.swift:513-516]
//      → ShellIntegration.handle(data:state:)   ← REGISTERED IN start()
//        → state.callback(exitCode, durationNanos)
//          → CommandOutcome.of(…) → documentDelegate?.documentDidChangeStatus
//

import AppKit
import SwiftTerm

// MARK: - SwiftTerm OscRegistering conformance

/// Makes SwiftTerm's `Terminal` satisfy the `OscRegistering` protocol declared in
/// `ShellIntegration.swift`, so `ShellIntegration.register(on:callback:)` can call
/// `registerOscHandler` without importing SwiftTerm in that Foundation-only file.
///
/// No `@retroactive` needed — both the protocol and this conformance live in the
/// `GoblinPortal` module, so SE-0364 does not apply here.
extension Terminal: OscRegistering {}

// MARK: - TerminalPane shell integration

// MARK: - GOBLIN_PORTAL_DIAG helper

/// Emit a diagnostic line to stderr when `GOBLIN_PORTAL_DIAG` is set in the environment.
/// Scoped to this file — a free function rather than a method so it is available
/// without referencing any pane type. Labels the engine ("swiftterm") so multi-engine
/// diagnostic output is distinguishable.
private func termDiag(_ message: String) {
    guard ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil else { return }
    FileHandle.standardError.write(Data("[diag] swiftterm: \(message)\n".utf8))
}

@MainActor
extension TerminalPane {

    /// The retained OSC 133 state for this pane.
    ///
    /// Stored via `objc_setAssociatedObject` because Swift extensions cannot add stored
    /// properties. The association policy is `.OBJC_ASSOCIATION_RETAIN_NONATOMIC` —
    /// `State` is a class, and association takes an AnyObject, so this is a strong
    /// reference scoped to the pane's lifetime. Cleared automatically when the pane is
    /// deallocated, which is the same moment SwiftTerm releases the handler closure.
    private var shellIntegrationState: ShellIntegration.State? {
        get {
            objc_getAssociatedObject(self, &TerminalPane.shellIntegrationKey)
                as? ShellIntegration.State
        }
        set {
            objc_setAssociatedObject(
                self, &TerminalPane.shellIntegrationKey,
                newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    private static var shellIntegrationKey: UInt8 = 0

    // MARK: Environment

    /// Append `GOBLIN_PORTAL_INTEGRATION=<path>` to `env` when the bundled script is locatable.
    ///
    /// Called from `TerminalPane.start()` before `startProcess` so the shell can read
    /// the variable during rc-file evaluation. Set unconditionally — the zsh script
    /// guards on `TERM_PROGRAM==GoblinPortal`, so sourcing it in another terminal is a no-op.
    /// `Bundle.main` is empty during the gate script run (no app bundle), so this is
    /// silent when the script is absent rather than crashing.
    ///
    /// `UMBER_INTEGRATION` is set to the same path as a backward-compatibility alias.
    /// Users with `[[ -n "$UMBER_INTEGRATION" ]] && source "$UMBER_INTEGRATION"` in their
    /// .zshrc continue to get shell integration after the rename. Remove after one release.
    func appendShellIntegrationEnv(_ env: inout [String]) {
        guard let path = Bundle.main.path(forResource: "shell-integration", ofType: "zsh")
        else { return }
        env.append("GOBLIN_PORTAL_INTEGRATION=\(path)")
        env.append("UMBER_INTEGRATION=\(path)")  // backward-compat alias -- remove after one release
    }

    // MARK: OSC 133 setup

    /// Register OSC 133 handlers on `terminal`. Called from `start()` after the process
    /// has been kicked off — `getTerminal()` is valid at that point.
    ///
    /// The callback routes through `CommandOutcome.of` — a pure-function policy layer
    /// shared across engine paths — so any engine produces identical status dots from
    /// identical inputs.
    func registerShellIntegration() {
        let terminal = view.getTerminal()
        let state = ShellIntegration.register(
            on: terminal,
            onCommandStart: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.status == .idle else { return }
                    self.status = .running
                    termDiag("OSC 133 C -> .running")
                }
            }
        ) { [weak self] exitCode, nanos in
            // This closure is called by SwiftTerm on the main thread (all SwiftTerm
            // callbacks are main-thread). `MainActor.assumeIsolated` asserts that
            // rather than hopping through a `Task`, keeping it synchronous and ordered
            // relative to other main-thread work.
            MainActor.assumeIsolated {
                guard let self else { return }
                let outcome = CommandOutcome.of(
                    exitCode: exitCode,
                    durationNanos: nanos,
                    isActiveDocument: self.isActiveDocument
                )
                self.applyCommandOutcome(outcome)
                // Fire a desktop notification for long commands that finish in the
                // background. `postIfNeeded` applies its own guards (background tab,
                // minimum duration) so the call is unconditional here — the policy
                // lives in CommandNotification, not scattered across call sites.
                CommandNotification.postIfNeeded(
                    exitCode: exitCode,
                    durationNanos: nanos,
                    title: self.currentTitle,
                    isActiveDocument: self.isActiveDocument
                )
                // Emit a diag line so OSC 133 completions are observable under GOBLIN_PORTAL_DIAG=1.
                termDiag("""
                    OSC 133 command finished: exit=\(exitCode.map(String.init) ?? "nil") \
                    in \(String(format: "%.1f", Double(nanos) / 1_000_000))ms \
                    -> \(outcome)
                    """)
            }
        }
        // Wire the command-start callback so the tab shows the .running dot while a
        // command is in flight. OSC 133 C fires when the user presses Return on a
        // non-empty command line; D clears it via applyCommandOutcome. The idle/attention
        // states are NOT set here — only the state machine advances through .running.
        state.onCommandStarted = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = .running
                termDiag("OSC 133 C — command started, status = .running")
            }
        }
        // Retain the state for the pane's lifetime. The handler closure already holds
        // a strong reference to `state`, but keeping it here too means the state is
        // reachable for diagnostics and future introspection without traversing the
        // closure's capture list.
        shellIntegrationState = state
    }

    /// Apply `outcome` to this pane's `status`. Delegates to the pure
    /// `CommandOutcome.statusUpdate(currentIsRunning:)` for the transition logic so the
    /// policy is testable headlessly in `check-command-outcome.sh`. This function is the
    /// single AppKit-side translator: Foundation decision → `DocumentStatus` write.
    ///
    /// The key invariant preserved by `statusUpdate`: `.ignore` only clears `.running`
    /// back to idle — it never erases `.attention` or other prior news. A bell that fires
    /// between OSC 133 C and D (C → bell → D with .ignore) therefore survives the D.
    func applyCommandOutcome(_ outcome: CommandOutcome) {
        switch outcome.statusUpdate(currentIsRunning: status == .running) {
        case .setFailed:
            status = .failed
        case .setSucceeded:
            status = .succeeded
        case .setIdle:
            status = .idle
            termDiag("OSC 133 D -> .ignore (running cleared to idle)")
        case .noChange:
            break
        }
    }

    // MARK: OSC 7 — current directory

    /// Fill the previously-empty `hostCurrentDirectoryUpdate` body.
    ///
    /// SwiftTerm delivers this via the full callback chain described in the file header.
    /// The shell-integration script emits `ESC ] 7 ; file://<host><percent-encoded-path> BEL`
    /// in its precmd hook. SwiftTerm delivers the raw OSC 7 payload (`file://hostname/path`)
    /// without stripping the scheme or percent-decoding — the `Osc7Directory.parse` call
    /// below handles both. (An earlier comment claimed SwiftTerm stripped the scheme at
    /// `Terminal.oscSetCurrentDirectory:1730-1742`; that is not what the source does — it
    /// stores `txt` verbatim into `hostCurrentDirectory`, and the parser strips it.)
    ///
    /// The report is parsed WITH its host (`Osc7Directory.parse`) and stored in the pane's
    /// `PaneDirectoryState` (`TerminalPane+DirectoryState.swift`): a local path as the
    /// shell's report, a remote host as display-only status scoped to the process group in
    /// front when it arrived. A remote report never becomes a path — the old parser
    /// dropped the host, so an ssh session reporting `/tmp` re-rooted the local sidebar.
    /// `ShellHosting.shellContext` decides which stored input answers for what is in front.
    /// The 750 ms poller (`SpaceViewController+DirectoryFollow.swift`) remains the single
    /// writer of the file-tree root — calling `followDirectory` here directly would create
    /// a second writer and break the one-writer invariant its header documents.
    func handleOsc7Directory(_ directory: String?) {
        guard let raw = directory,
              // Foundation-only and gated headlessly by `check-shell-integration.sh`:
              // handles `file://host/path` and bare paths, percent-decodes once, and
              // returns nil for empty/invalid input.
              let report = Osc7Directory.parse(raw, localHostnames: Self.localHostnames)
        else { return }
        let state = directoryState
        switch report {
        case .local(let path):
            // Normalise the same way ShellDirectory.workingDirectory does, so OSC 7 and
            // the kernel path compare equal and the poller's early-return fires correctly.
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            state.localReport = url.path
            termDiag("OSC 7 pwd -> \(url.path)")
        case .remote(let host):
            // Scoped to the foreground group in front NOW, so a later session (another
            // ssh, or a local shell after `exit`) can never inherit this host.
            let group = view.process.map { tcgetpgrp($0.childfd) } ?? -1
            state.remoteReport = RemoteOsc7Report(host: host, foregroundGroup: group)
            termDiag("OSC 7 remote host -> \(host) (foreground group \(group))")
        }
    }

    /// The host names that mean "this machine", computed once per process: `gethostname`
    /// is cheap but OSC 7 fires on every prompt, and the hostname does not change under a
    /// running shell in any way that zsh's `$HOST` would follow either.
    private static let localHostnames: Set<String> = Osc7Directory.currentLocalHostnames()
}
