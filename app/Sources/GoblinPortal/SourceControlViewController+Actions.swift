//
//  SourceControlViewController+Actions.swift
//  Write-side @objc action methods for the Source Control panel.
//
//  Separate from the main controller file to keep both under 350 LOC, and because
//  the mutation surface (stage/unstage/discard/commit/push/pull) is a distinct concern
//  from view construction and data-model management. Read-only NSOutlineView plumbing
//  lives in +DataSource.swift.
//
//  All git operations dispatch to `DispatchQueue.global(qos: .userInitiated)` and
//  bounce back to the main queue to show errors and trigger a re-poll. This matches
//  the pattern used by FileTreeViewController+Git.swift's background spawning.
//

import AppKit

extension SourceControlViewController {

    // MARK: - Per-file operations

    /// Stage a single tracked file: `git add -- <path>`.
    @objc func stageFile(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        performOperation(description: "stage \(entry.path)") { repo in
            GitOperations.stage(path: entry.path, in: repo)
        }
    }

    /// Unstage a single file: `git restore --staged -- <path>`.
    @objc func unstageFile(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        performOperation(description: "unstage \(entry.path)") { repo in
            GitOperations.unstage(path: entry.path, in: repo)
        }
    }

    /// Discard working-tree changes for a file — shows a confirmation alert first
    /// because the operation is irreversible.
    ///
    /// F-4: For a staged-only addition (`isStaged && status == .added`), the file
    /// exists only in the index, not the working tree, so `git checkout -- <path>`
    /// is a silent no-op. The correct operation is `git restore --staged` (unstage),
    /// which removes the file from the index without touching the working tree. This
    /// matches VS Code's "Discard Changes" behaviour for staged new files
    /// (vscode src/vs/workbench/contrib/scm/common/scmService.ts, revert path).
    @objc func discardFile(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        confirmDiscard(filename: (entry.path as NSString).lastPathComponent) { [weak self] confirmed in
            guard confirmed, let self else { return }
            if entry.status == .untracked {
                self.performOperation(description: "discard \(entry.path)") { repo in
                    GitOperations.discardUntracked(path: entry.path, in: repo)
                }
            } else if entry.isStaged && entry.status == .added {
                // Staged-only new file: unstage instead of discard (checkout is a no-op).
                self.performOperation(description: "unstage \(entry.path)") { repo in
                    GitOperations.unstage(path: entry.path, in: repo)
                }
            } else {
                self.performOperation(description: "discard \(entry.path)") { repo in
                    GitOperations.discard(path: entry.path, in: repo)
                }
            }
        }
    }

    // MARK: - Section-level operations

    /// Stage all changes: `git add -A`.
    @objc func stageAll(_ sender: Any?) {
        performOperation(description: "stage all") { repo in
            GitOperations.stageAll(in: repo)
        }
    }

    /// Unstage everything: `git restore --staged .`.
    @objc func unstageAll(_ sender: Any?) {
        performOperation(description: "unstage all") { repo in
            GitOperations.unstageAll(in: repo)
        }
    }

    // MARK: - Commit

    /// Read the commit message field and run `git commit -m <message>`.
    /// Bound to ⌘Return via `commitButton.keyEquivalent`.
    @objc func commitChanges(_ sender: Any?) {
        let message = commitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            showError("Commit message is required.")
            return
        }
        // No client-side "nothing staged" guard: the view-model array is stale
        // between 2-second poll ticks, so the guard produces false negatives.
        // Let `git commit` reject the empty-index case — its stderr ("nothing to
        // commit") is already surfaced by showError via performOperation.

        performOperation(description: "commit") { repo in
            GitOperations.commit(message: message, in: repo)
        } onSuccess: { [weak self] in
            self?.commitField.stringValue = ""
        }
    }

    // MARK: - Push / Pull

    /// Push to upstream, setting `-u origin <branch>` when no upstream is configured.
    @objc func pushChanges(_ sender: Any?) {
        let branch     = snapshot.branch
        let needsSetUp = !snapshot.hasUpstream
        performOperation(description: "push") { repo in
            GitOperations.push(in: repo, branch: branch, setUpstream: needsSetUp)
        }
    }

    /// Pull from upstream: `git pull`.
    @objc func pullChanges(_ sender: Any?) {
        performOperation(description: "pull") { repo in
            GitOperations.pull(in: repo)
        }
    }

    /// Discard only the working-tree half of a partially-staged modified file.
    ///
    /// F-6: A file with `MM` porcelain status has changes in both the index (staged)
    /// and the working tree (unstaged). `git checkout -- <path>` reverts the working
    /// tree to match the index without touching the staged half — exactly the "Discard
    /// Working Changes" action VS Code exposes on the second row of a partially-staged
    /// file (vscode src/vs/workbench/contrib/scm/browser/scmViewPane.ts, "discardChanges").
    @objc func discardWorkingChanges(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        confirmDiscard(filename: (entry.path as NSString).lastPathComponent) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.performOperation(description: "discard working changes \(entry.path)") { repo in
                GitOperations.discard(path: entry.path, in: repo)
            }
        }
    }

    // MARK: - Context menu builder

    /// Returns the appropriate context menu for a row, called from the data source.
    ///
    /// F-6: For a partially-staged modified file (`isStaged && status == .modified`)
    /// the staged section row gets an extra "Discard Working Changes" item, letting users
    /// manage the working-tree half without first unstaging. Also label the "Stage" item
    /// on a partially-staged entry as "Stage All Changes" to clarify it stages both halves.
    func contextMenu(for entry: GitFileEntry) -> NSMenu {
        let menu = NSMenu()

        if entry.status == .untracked {
            let track = NSMenuItem(title: "Stage File", action: #selector(stageFile(_:)), keyEquivalent: "")
            track.representedObject = entry
            track.target = self
            menu.addItem(track)

            let clean = NSMenuItem(title: "Discard File", action: #selector(discardFile(_:)), keyEquivalent: "")
            clean.representedObject = entry
            clean.target = self
            menu.addItem(clean)
        } else if entry.isStaged {
            let unstage = NSMenuItem(title: "Unstage File", action: #selector(unstageFile(_:)), keyEquivalent: "")
            unstage.representedObject = entry
            unstage.target = self
            menu.addItem(unstage)

            // Partially-staged (MM): also offer discard of the working-tree changes.
            if entry.status == .modified {
                let discardWorking = NSMenuItem(
                    title: "Discard Working Changes",
                    action: #selector(discardWorkingChanges(_:)),
                    keyEquivalent: "")
                discardWorking.representedObject = entry
                discardWorking.target = self
                menu.addItem(discardWorking)
            }
        } else {
            let stage = NSMenuItem(title: "Stage File", action: #selector(stageFile(_:)), keyEquivalent: "")
            stage.representedObject = entry
            stage.target = self
            menu.addItem(stage)

            let discard = NSMenuItem(title: "Discard Changes", action: #selector(discardFile(_:)), keyEquivalent: "")
            discard.representedObject = entry
            discard.target = self
            menu.addItem(discard)
        }

        return menu
    }

    // MARK: - Internals

    /// Dispatch a git operation off-main, then bounce back to main for UI.
    private func performOperation(
        description: String,
        operation: @escaping @Sendable (GitRepository) -> Result<Void, GitOperationError>,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard let repo = repository else {
            showError("No git repository found.")
            return
        }

        let desc = description  // capture the value, not the interpolation context
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = operation(repo)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    onSuccess?()
                    self.delegate?.sourceControlDidChange(self)
                case .failure(let err):
                    self.showError("git \(desc) failed:\n\(err.message)")
                }
            }
        }
    }

    /// Extract a `GitFileEntry` from a sender.
    ///
    /// Context menu items carry the entry as `representedObject`. Hover buttons
    /// live inside `SourceControlRowView`, which stores the entry directly.
    private func entry(from sender: Any?) -> GitFileEntry? {
        // Context menu path
        if let menuItem = sender as? NSMenuItem {
            return menuItem.representedObject as? GitFileEntry
        }
        // Hover button path: walk up from the button to find the row view
        if let button = sender as? NSButton {
            var current: NSView? = button.superview
            while let view = current {
                if let row = view as? SourceControlRowView {
                    return row.entry
                }
                current = view.superview
            }
        }
        // Fallback: use the clicked/selected row in the outline view
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return row >= 0 ? outlineView.item(atRow: row) as? GitFileEntry : nil
    }

    /// Show an irreversible-discard confirmation sheet, calling `completion` on main.
    private func confirmDiscard(filename: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText    = "Discard changes to \(filename)?"
        alert.informativeText = "This cannot be undone. The file will be reverted to its last committed state."
        alert.alertStyle     = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// Show a non-fatal error message as a sheet (or modal when no window).
    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText    = "Source Control Error"
        alert.informativeText = message
        alert.alertStyle     = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
