//
//  AppDelegate+EditorActions.swift
//  Editor-specific menu actions: Go to Line, Word Wrap, Send Path to Terminal,
//  Run in Terminal, and openSearch. Extracted from AppDelegate.swift when that file hit the
//  350-line ceiling — the seam is clean because every action here requires a
//  `FileViewerPane` to be the active document (terminals do not answer these).
//
//  Also holds the shared `shellQuoted(_:)` helper and `findAncestorFile(named:from:)`
//  used by the terminal-integration actions.
//
//  **Wave 3 actions**
//    · `openSearch(_:)`           — ⌘F, opens the find bar (terminal) or NSTextFinder (editor)
//    · `selectNextOccurrence(_:)` — ⌘D, routes through the responder chain
//    · `showCommandPalette(_:)`   — ⌘⇧P, opens the floating command palette
//

import AppKit

extension AppDelegate {
    // MARK: - Editor actions

    /// ⌘L — go to a line in the focused file viewer. Terminals do not answer.
    @objc func goToLine(_ sender: Any?) {
        guard let viewer = focusedSpace?.activeDocument as? FileViewerPane else { return }
        viewer.goToLine(sender)
    }

    /// View → Word Wrap. Toggles soft-wrap on the focused file viewer.
    @objc func toggleWordWrap(_ sender: Any?) {
        guard let viewer = focusedSpace?.activeDocument as? FileViewerPane else { return }
        viewer.setWrapping(!viewer.isWrapping)
    }

    // MARK: - Terminal integration

    /// Shell-safe single-quoted path: escapes `'` and strips `\n`/`\r`.
    func shellQuoted(_ url: URL) -> String {
        let safe = url.path
            .replacingOccurrences(of: "'", with: "'\\''")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return "'\(safe)'"
    }

    /// Edit → Send Path to Terminal (⌘⇧C). Sends the file's path to the shell.
    @objc func sendPathToTerminal(_ sender: Any?) {
        guard let viewer = focusedSpace?.activeDocument as? FileViewerPane,
              let shell = focusedSpace?.focusedShellHost else { return }
        shell.send(text: "\(shellQuoted(viewer.url)) ")
    }

    /// Edit → Run in Terminal (⌘⇧R). Sends a language-appropriate run command
    /// for the current file to the focused shell and executes it immediately —
    /// no confirmation dialog, same as Xcode ⌘R and Script Editor ⌘R.
    /// `validateMenuItem` gates it behind an active `FileViewerPane` + a live
    /// shell host; the three deliberate acts (open, focus, ⌘⇧R) are the guard.
    @objc func runInTerminal(_ sender: Any?) {
        guard let viewer = focusedSpace?.activeDocument as? FileViewerPane,
              let shell = focusedSpace?.focusedShellHost else { return }
        let quoted = shellQuoted(viewer.url)
        let ext = viewer.url.pathExtension.lowercased()
        // Language-detected run command. SyntaxLanguage already knows the file
        // type; this maps it to the obvious `$RUNNER $FILE` invocation.
        let command: String
        switch ext {
        case "swift":       command = "swift \(quoted)"
        case "py":          command = "python3 \(quoted)"
        case "rb":          command = "ruby \(quoted)"
        case "js", "mjs":   command = "node \(quoted)"
        case "ts":          command = "npx tsx \(quoted)"
        case "sh", "bash":  command = "bash \(quoted)"
        case "zsh":         command = "zsh \(quoted)"
        case "go":          command = "go run \(quoted)"
        case "rs":
            // Walk up from the .rs file to find the nearest Cargo.toml — standard
            // Rust layouts put source under `src/`, so the file's immediate parent
            // is wrong. Falls back to bare `cargo run` if no manifest is found.
            if let manifest = Self.findAncestorFile(named: "Cargo.toml", from: viewer.url) {
                command = "cargo run --manifest-path \(shellQuoted(manifest))"
            } else {
                command = "cargo run"
            }
        case "c":
            // Unique temp path avoids races when two C files compile concurrently.
            let out = "/tmp/umber-\(UUID().uuidString).out"
            command = "cc \(quoted) -o '\(out)' && '\(out)'; rm -f '\(out)'"
        case "cpp", "cc":
            let out = "/tmp/umber-\(UUID().uuidString).out"
            command = "c++ \(quoted) -o '\(out)' && '\(out)'; rm -f '\(out)'"
        default:            command = quoted  // Unknown: just send the path
        }
        shell.send(text: command + "\n")
    }

    // MARK: - Wave 3 actions

    /// Edit → Find… (⌘F from the command palette). Opens the scrollback find bar
    /// in the focused terminal pane by calling `TerminalPane.openSearch()` directly,
    /// so the palette does not need to synthesise a tagged `NSMenuItem` internally.
    ///
    /// Falls back gracefully when no terminal is focused: `focusedShellHost` returns
    /// nil if the active document is a file viewer with no visible terminal — the
    /// action silently no-ops, mirroring how the menu item greys out in that state.
    @objc func openSearch(_ sender: Any?) {
        (focusedSpace?.focusedShellHost as? TerminalPane)?.openSearch()
    }

    /// Edit → Select Next Occurrence (⌘D). Routes through the responder chain —
    /// `FileViewerPane` answers `selectNextOccurrence:`; terminals don't, so the
    /// item greys itself out over a terminal automatically.
    @objc func selectNextOccurrence(_ sender: Any?) {
        NSApp.sendAction(#selector(FileViewerPane.selectNextOccurrence(_:)), to: nil, from: sender)
    }

    /// Navigate → Command Palette (⌘⇧P). Opens the floating command palette above
    /// the current window.
    @objc func showCommandPalette(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? SpaceWindowController.open.first?.window
        else { return }
        CommandPalette.shared.toggle(in: window)
    }

    // MARK: - Helpers

    /// Walk up from `file`'s parent directory looking for a file named `name`.
    /// Returns the URL of the first match, or nil if the filesystem root is
    /// reached without finding it. Used by `runInTerminal` to locate
    /// `Cargo.toml` from a `.rs` source file anywhere in the project tree.
    static func findAncestorFile(named name: String, from file: URL) -> URL? {
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let fm = FileManager.default
        while true {
            let candidate = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { return nil }  // reached root
            dir = parent
        }
    }

    // MARK: - Space switching (window chooser via command palette)

    /// Switch to a Space by index. Invoked from the command palette's dynamic
    /// Space entries, where the `tag` is the index into `SpaceWindowController.open`.
    @objc func selectSpace(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let index = item.tag
        let spaces = SpaceWindowController.open
        guard spaces.indices.contains(index) else { return }
        spaces[index].window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘⇧A: open the command palette as a window chooser. Equivalent to typing
    /// "space" in the palette, but the shortcut is discoverable from the menu.
    @objc func showWindowChooser(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? SpaceWindowController.open.first?.window
        else { return }
        CommandPalette.shared.toggle(in: window)
    }
}
