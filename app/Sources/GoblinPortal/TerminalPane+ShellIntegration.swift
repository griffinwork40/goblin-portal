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
                    self.status = .running
                    self.documentDelegate?.documentDidChangeStatus(self)
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
        // Retain the state for the pane's lifetime. The handler closure already holds
        // a strong reference to `state`, but keeping it here too means the state is
        // reachable for diagnostics and future introspection without traversing the
        // closure's capture list.
        shellIntegrationState = state
    }

    /// Apply `outcome` to this pane's `status`. Extracted so it is legible at the
    /// call site and testable independently of the OSC parsing above.
    ///
    /// Maps `CommandOutcome` → `DocumentStatus` with the same one-line translation the
    /// `CommandOutcome.swift` header describes: the decision (outcome) lives in that
    /// Foundation-only file; the presentation type (`DocumentStatus`) is AppKit-adjacent
    /// and lives here, in the one file that sees both.
    func applyCommandOutcome(_ outcome: CommandOutcome) {
        switch outcome {
        case .failed:    status = .failed
        case .succeeded: status = .succeeded
        case .ignore:
            // Clear `.running` back to idle when the command finishes without earning
            // a status (fast success on the active tab, or missing exit code). Without
            // this, a quick `ls` would leave the running dot stuck on the tab until the
            // next command. Other states (.failed, .succeeded, .attention) are left alone
            // — .ignore means "this command has nothing to say", not "erase prior news".
            if status == .running { status = .idle }
        }
    }

    // MARK: OSC 7 — current directory

    /// Fill the previously-empty `hostCurrentDirectoryUpdate` body.
    ///
    /// SwiftTerm delivers this via the full callback chain described in the file header.
    /// The shell-integration script emits `ESC ] 7 ; file://<host><percent-encoded-path> BEL`
    /// in its precmd hook. SwiftTerm delivers the raw OSC 7 payload (`file://hostname/path`)
    /// without stripping the scheme or percent-decoding — the `parseOsc7Directory` call
    /// below handles both. (An earlier comment claimed SwiftTerm stripped the scheme at
    /// `Terminal.oscSetCurrentDirectory:1730-1742`; that is not what the source does — it
    /// stores `txt` verbatim into `hostCurrentDirectory` and the `hasPrefix` branch here
    /// is what actually strips it.)
    ///
    /// Storing in `_reportedDirectory` gives `ShellHosting.currentDirectory` a fast answer from
    /// the stored value; the 750ms kernel poller (`SpaceViewController+DirectoryFollow.swift`)
    /// reads it through `focusedShellHost`.
    /// The poller remains the single writer of the file-tree root — calling `followDirectory`
    /// here directly would create a second writer and break the one-writer invariant the
    /// `DirectoryFollow` header documents at length.
    ///
    /// With OSC 7 now wired, the kernel poll is the *fallback* — it fires between OSC 7
    /// reports and on panes whose shells do not source the integration script. Its cost
    /// (one `tcgetpgrp` + one `proc_pidinfo` per 750ms) is unchanged; it just becomes
    /// redundant for panes that do source the script.
    func handleOsc7Directory(_ directory: String?) {
        guard let raw = directory,
              // Delegate URL parsing to the Foundation-only `ShellIntegration.parseOsc7Directory`
              // so the logic is gateable headlessly by `check-shell-integration.sh`.
              // That function handles both `file://hostname/path` and bare-path forms,
              // percent-decodes the path component, and returns nil for empty/invalid input.
              let path = ShellIntegration.parseOsc7Directory(raw)
        else { return }
        // Normalise the same way ShellDirectory.current does, so OSC 7 and the kernel
        // path compare equal and the poller's early-return fires correctly.
        let url = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        _reportedDirectory = url.path
        termDiag("OSC 7 pwd -> \(url.path)")
    }

    // Internal storage — cannot add a stored property in an extension, so back it
    // with associated object storage keyed on a second static variable.
    // `fileprivate(set)` restricts writes to this file — only `handleOsc7Directory`
    // (above) is the writer; reads cross file boundaries for `ShellHosting.currentDirectory`.
    fileprivate(set) var _reportedDirectory: String? {
        get { objc_getAssociatedObject(self, &TerminalPane.reportedDirectoryKey) as? String }
        set { objc_setAssociatedObject(
            self, &TerminalPane.reportedDirectoryKey,
            newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
    private static var reportedDirectoryKey: UInt8 = 0
}
