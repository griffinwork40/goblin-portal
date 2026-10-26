//
//  TerminalPane+AgentActivity.swift
//  Output-activity heuristic wiring for terminal panes.
//
//  WHY A SEPARATE FILE.  TerminalPane.swift is at the 350-LOC ceiling.
//  This concern — a 1 s timer checking output timestamps against foreground
//  state — is self-contained and parallels `TerminalPane+Progress.swift`.
//
//  HOW IT WORKS.  Every second, the timer reads the foreground process kind
//  from `shellContext` and the last-draw timestamp from the view.  When the
//  foreground is `.command` (an interactive CLI, not a shell) and the view has
//  drawn within `AgentActivityPolicy.silenceThreshold`, status is set to
//  `.running`.  When the silence threshold passes, status returns to `.idle`.
//
//  INTERACTION WITH OSC 133.  The heuristic ONLY promotes from `.idle` to
//  `.running`.  It never downgrades `.attention`, `.succeeded`, or `.failed`,
//  and it never overrides a `.running` set by OSC 133 C.  The
//  `heuristicSetRunning` flag ensures the heuristic only clears a `.running`
//  that it set itself, leaving the OSC 133 path undisturbed.
//
//  ACTIVE-DOCUMENT GUARD.  Same rule as `CommandOutcome`: a dot on the tab
//  the user is already looking at is noise, not signal.  The heuristic skips
//  panes that are the active visible document.
//

import AppKit
import QuartzCore  // CACurrentMediaTime

// MARK: - Stored state via associated object

/// Lightweight state added to each pane via an associated object (same pattern
/// as `PaneTabTitleState`, `ProgressPanePolicy`).
@MainActor
final class AgentActivityState {
    var timer: Timer?
    /// Whether the last transition to `.running` was set by this heuristic
    /// (as opposed to OSC 133 C).  Guards against clearing a `.running`
    /// that the shell integration path owns.
    var heuristicSetRunning: Bool = false
}

// MARK: - TerminalPane agent-activity extension

@MainActor
extension TerminalPane {

    private static var agentActivityKey: UInt8 = 0

    private var agentActivity: AgentActivityState {
        if let s = objc_getAssociatedObject(self, &Self.agentActivityKey)
            as? AgentActivityState { return s }
        let s = AgentActivityState()
        objc_setAssociatedObject(self, &Self.agentActivityKey,
                                 s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    // MARK: Timer lifecycle

    /// Start the 1 s repeating timer that evaluates output activity.
    /// Called from `registerNotifications()` so it fires before the shell
    /// can produce output.
    func startAgentActivityTimer() {
        let state = agentActivity
        state.timer?.invalidate()
        state.timer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateAgentActivity()
            }
        }
    }

    /// Tear down the timer.  Called from `documentWillClose()` (via
    /// `stopAgentActivityTimer`) so the timer does not outlive the pane.
    func stopAgentActivityTimer() {
        let state = agentActivity
        state.timer?.invalidate()
        state.timer = nil
        state.heuristicSetRunning = false
    }

    // MARK: Evaluation

    private func evaluateAgentActivity() {
        // Same guard as CommandOutcome: skip the visible tab.
        guard !isActiveDocument else {
            // If the user switched TO this tab while the heuristic had it
            // marked .running, clear it — they can see the output directly.
            let state = agentActivity
            if state.heuristicSetRunning && status == .running {
                status = .idle
                state.heuristicSetRunning = false
            }
            return
        }

        let context = shellContext
        let isCommand: Bool
        if case .command = context.foreground { isCommand = true }
        else { isCommand = false }

        let now = CACurrentMediaTime()
        let lastDraw = view.lastDrawTimestamp
        let elapsed: TimeInterval? = lastDraw > 0 ? (now - lastDraw) : nil

        let activity = AgentActivityPolicy.activity(
            isCommand: isCommand,
            secondsSinceLastOutput: elapsed
        )

        let state = agentActivity
        switch activity {
        case .active:
            // Only promote from .idle — never downgrade .attention/.succeeded/.failed,
            // and never redundantly re-set a .running that OSC 133 already owns.
            if status == .idle {
                status = .running
                state.heuristicSetRunning = true
            }

        case .silent:
            // Only clear a .running that the heuristic itself set.
            if status == .running, state.heuristicSetRunning {
                status = .idle
                state.heuristicSetRunning = false
            }

        case .notApplicable:
            // Foreground went back to a shell or disappeared.
            if state.heuristicSetRunning {
                if status == .running { status = .idle }
                state.heuristicSetRunning = false
            }
        }
    }
}
