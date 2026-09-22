//
//  AppDelegate+SourceControl.swift
//  `@objc` action methods for the Source Control menu items.
//
//  Routes each menu action to the focused Space's source control panel via
//  `focusedSpace`. Separated from `AppDelegate.swift` (which is at 343/350 LOC)
//  because this is a complete new concern with its own action surface.
//
//  The selectors are named `scStageAll`, `scCommit`, etc. rather than `stageAll`,
//  `commitChanges` to avoid colliding with the `SourceControlViewController`'s own
//  `@objc` methods of the same names — AppKit's responder chain would find the
//  controller first (it is lower in the chain), which is correct for inline buttons,
//  but the menu items use these AppDelegate entry points as the explicit target=nil
//  starting point.
//

import AppKit

extension AppDelegate {
    // MARK: - Source Control menu actions

    @objc func scStageAll(_ sender: Any?) {
        focusedSpace?.sourceControlPanel.stageAll(sender)
    }

    @objc func scUnstageAll(_ sender: Any?) {
        focusedSpace?.sourceControlPanel.unstageAll(sender)
    }

    @objc func scCommit(_ sender: Any?) {
        focusedSpace?.sourceControlPanel.commitChanges(sender)
    }

    @objc func scPush(_ sender: Any?) {
        focusedSpace?.sourceControlPanel.pushChanges(sender)
    }

    @objc func scPull(_ sender: Any?) {
        focusedSpace?.sourceControlPanel.pullChanges(sender)
    }

    @objc func scDiscardAll(_ sender: Any?) {
        guard let panel = focusedSpace?.sourceControlPanel else { return }

        // F-5: Use beginSheetModal rather than runModal so the alert is window-modal
        // (attached as a sheet) instead of application-modal. runModal() blocks ALL
        // windows in the app for the duration — the user cannot switch spaces, look at
        // diffs, or dismiss other sheets. beginSheetModal matches the per-file discard
        // path in SourceControlViewController+Actions.swift (confirmDiscard), making the
        // UX consistent and limiting the modal to the key window only (HIG §Alerts).
        let alert = NSAlert()
        alert.messageText = "Discard all changes?"
        alert.informativeText = "This will revert all modified tracked files and delete all untracked files. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")

        // Target the key window; fall back to runModal when there is none (e.g. during
        // automated testing or when the app is in the background with no visible window).
        guard let window = NSApp.keyWindow else {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            scDiscardAllExecute(panel: panel)
            return
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.scDiscardAllExecute(panel: panel)
        }
    }

    /// The actual git operations for "Discard All", factored out so both the sheet and
    /// the runModal fallback in `scDiscardAll` can call it without duplicating logic.
    ///
    /// Unstage everything first so staged deletions/renames are not left behind,
    /// then revert all tracked changes (`git checkout -- .`) and remove untracked
    /// files and directories (`git clean -fd`) to fully match the per-file
    /// discardFile + discardUntracked behavior in SourceControlViewController+Actions.swift.
    private func scDiscardAllExecute(panel: SourceControlViewController) {
        guard let repo = panel.repository else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let unstageResult = GitOperations.unstageAll(in: repo)
            if case .failure(let unstageErr) = unstageResult {
                DispatchQueue.main.async {
                    let errAlert = NSAlert()
                    errAlert.messageText = "Discard failed"
                    errAlert.informativeText = unstageErr.message
                    if let window = NSApp.keyWindow {
                        errAlert.beginSheetModal(for: window, completionHandler: nil)
                    } else {
                        errAlert.runModal()
                    }
                }
                return
            }
            // Run discard and clean independently so a failure in one does not
            // silently skip the other, and the error message names exactly what
            // succeeded and what did not.
            let discardResult = GitOperations.discard(path: ".", in: repo)
            let cleanResult = GitOperations.cleanAll(in: repo)

            DispatchQueue.main.async {
                var errors: [String] = []
                if case .failure(let e) = discardResult { errors.append("Revert tracked files: \(e.message)") }
                if case .failure(let e) = cleanResult   { errors.append("Remove untracked files: \(e.message)") }

                if !errors.isEmpty {
                    let errAlert = NSAlert()
                    errAlert.messageText = "Discard partially failed"
                    // unstageAll already succeeded at this point — tell the user.
                    errAlert.informativeText = "Staged changes were unstaged. The following steps failed:\n\n"
                        + errors.joined(separator: "\n")
                    errAlert.alertStyle = .warning
                    if let window = NSApp.keyWindow {
                        errAlert.beginSheetModal(for: window, completionHandler: nil)
                    } else {
                        errAlert.runModal()
                    }
                }
                // Trigger a re-poll — even on partial failure the repo state changed
                // (unstageAll succeeded), so the UI must reflect the current state.
                panel.delegate?.sourceControlDidChange(panel)
            }
        }
    }
}
