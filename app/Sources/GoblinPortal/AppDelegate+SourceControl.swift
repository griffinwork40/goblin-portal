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
        alert.informativeText = "This will revert all modified files to their last committed state. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Discard all tracked changes, then clean untracked
        guard let repo = panel.repository else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GitOperations.discard(path: ".", in: repo)
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    let errAlert = NSAlert()
                    errAlert.messageText = "Discard failed"
                    errAlert.informativeText = error.message
                    errAlert.runModal()
                }
            }
        }
    }
}
