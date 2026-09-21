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
        // Safety: confirm before discarding all changes
        let alert = NSAlert()
        alert.messageText = "Discard all changes?"
        alert.informativeText = "This will revert all modified tracked files and delete all untracked files. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Unstage everything first so staged deletions/renames are not left behind,
        // then revert all tracked changes (`git checkout -- .`) and remove untracked
        // files and directories (`git clean -fd`) to fully match the per-file
        // discardFile + discardUntracked behavior in SourceControlViewController+Actions.swift.
        guard let repo = panel.repository else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let unstageResult = GitOperations.unstageAll(in: repo)
            if case .failure(let unstageErr) = unstageResult {
                DispatchQueue.main.async {
                    let errAlert = NSAlert()
                    errAlert.messageText = "Discard failed"
                    errAlert.informativeText = unstageErr.message
                    errAlert.runModal()
                }
                return
            }
            let discardResult = GitOperations.discard(path: ".", in: repo)
            let cleanResult: Result<Void, GitOperationError>
            if case .failure = discardResult {
                cleanResult = discardResult  // skip clean if discard failed
            } else {
                cleanResult = GitOperations.cleanAll(in: repo)
            }
            DispatchQueue.main.async {
                switch cleanResult {
                case .failure(let error):
                    let errAlert = NSAlert()
                    errAlert.messageText = "Discard failed"
                    errAlert.informativeText = error.message
                    errAlert.runModal()
                case .success:
                    // Trigger a re-poll — every other write path calls this so the
                    // file tree and source control panel reflect the new state.
                    panel.delegate?.sourceControlDidChange(panel)
                }
            }
        }
    }
}
