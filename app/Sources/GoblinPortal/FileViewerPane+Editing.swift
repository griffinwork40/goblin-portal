//
//  FileViewerPane+Editing.swift
//  Saving and the alerts that stand between a buffer and lost work.
//
//  Its own file because this is the *dangerous* half of the viewer. Reading a
//  file is fail-soft and reversible; writing one over an agent that rewrote it
//  underneath you is neither, and commit 1d1c3f2 closed a silent-overwrite path
//  right here. Isolating the write path — `write()`, the encoding-change prompt,
//  the overwrite prompt — means a reader auditing "can this destroy work?" reads
//  one file, and `FileViewerPane.swift` stays about getting bytes on screen.
//
//  `NSTextViewDelegate` used to ride along here for its single `textDidChange`
//  callback. It moved to `+SmartEditing.swift` because `shouldChangeTextIn` (the
//  hook for auto-indent, tab→spaces and bracket pairing) must live in the SAME
//  extension as `textDidChange` — Swift requires one conformance per protocol —
//  and that concern outgrew the save/alert file.
//

import AppKit

// MARK: - Editing

extension FileViewerPane {
    /// Was `fileprivate` when all of this lived in one file. It has to be internal
    /// now: `reload` clears the flag from `FileViewerPane.swift`, and `fileprivate`
    /// stops at this file's edge. Still the only writer of `isDirty`, which is the
    /// property that matters — every dirty transition goes through here and so
    /// always notifies the delegate.
    func setDirty(_ dirty: Bool) {
        guard dirty != isDirty else { return }
        isDirty = dirty
        delegate?.fileViewerDidChangeEditedState(self)
    }

    /// Write the buffer back to disk. Returns false if the user cancelled or the
    /// write failed — callers treat that as "do not close".
    ///
    /// Internal rather than `fileprivate` because its two callers — `saveDocument()`
    /// (⌘S) and `documentShouldClose()` — are the `SpaceDocument` conformance in
    /// `+Document`. Still the only path to disk in this class.
    func write() -> Bool {
        // Nothing to write, and nothing that *should* be written: a placeholder body
        // is Goblin Portal's prose, not the user's file.
        guard !isPlaceholder else { return true }
        guard isDirty else { return true }

        if hasExternalChange && !confirmOverwriteOfChangedFile() { return false }

        guard let data = encodedBuffer() else { return false }

        // Capture the mode before writing. `.atomic` writes a temp file and renames
        // it over the target, which means a NEW inode — so the original's permission
        // bits do not carry across on their own, and saving a shell script would
        // quietly drop its +x. Re-applied below.
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .posixPermissions] as? NSNumber

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            presentError(
                "Could not save \(url.lastPathComponent).", detail: error.localizedDescription)
            return false
        }
        if let mode {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: mode], ofItemAtPath: url.path)
            } catch {
                // The write itself already succeeded above — this is a secondary,
                // non-blocking failure, so it gets the same stderr treatment as a
                // bad config field (`AppConfig.load()`), not an alert: don't stop
                // the user over a permission bit when the content already landed.
                // Silent before this fix — a saved shell script could lose +x with
                // no signal anywhere (PR #2 review, finding 6).
                FileHandle.standardError.write(
                    "Could not restore permissions on \(url.lastPathComponent): "
                        .appending(error.localizedDescription).appending("\n")
                        .data(using: .utf8)!)
            }
        }

        // Re-stamp from what is now on disk, so the very save we just performed is
        // not mistaken for someone else's external change on the next window focus.
        let stamp = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let date = stamp?.contentModificationDate, let size = stamp?.fileSize {
            loadedStamp = (date, size)
        }
        hasExternalChange = false
        setDirty(false)
        return true
    }

    /// Encode with the file's original encoding, or get explicit permission to change
    /// it. Typing an emoji into a Latin-1 file is the usual way to land here.
    private func encodedBuffer() -> Data? {
        if let data = textView.string.data(using: savedEncoding) { return data }

        let alert = NSAlert()
        alert.messageText = "\(url.lastPathComponent) cannot be saved as \(encodingName)."
        alert.informativeText =
            "Some characters you typed do not exist in that encoding. Saving as UTF-8 will "
            + "rewrite the whole file's encoding."
        alert.addButton(withTitle: "Save as UTF-8")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        savedEncoding = .utf8
        return textView.string.data(using: .utf8)
    }

    private var encodingName: String {
        String.localizedName(of: savedEncoding)
    }

    private func confirmOverwriteOfChangedFile() -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(url.lastPathComponent) has changed on disk."
        alert.informativeText =
            "Something else — most likely the agent in the terminal — rewrote this file after "
            + "you started editing. Saving replaces its version with yours."
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Mine and Reload")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertThirdButtonReturn:
            reload(preservingScroll: true)
            return false
        default: return false
        }
    }

    private func presentError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
