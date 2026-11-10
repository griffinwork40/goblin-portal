//
//  GoblinPortalTerminalView+FilePath.swift
//  cmd+click file-path detection — parallel to the URL path in +Links.swift.
//
//  WHAT THIS FILE OWNS.  When the user holds ⌘ and clicks in the terminal,
//  SwiftTerm's own mouseUp first tries to fire `requestOpenLink` for any string
//  it already identified as a URL (OSC 8 or plain-text regex match). That path
//  handles `https://`, `http://`, and `file://` URLs.
//
//  Bare compiler output — `/path/to/file.swift:42:10`, `src/main.rs:7:3`,
//  `File "script.py", line 12` — is never identified as a URL by SwiftTerm's
//  `ghosttyImplicitLinkRegex` (Terminal.swift:6204) because it has no scheme.
//  This extension adds a *separate* hook that fires on the same ⌘+click gesture
//  for that case: it extracts the row text from the terminal buffer at the click
//  position, runs `FilePathDetector.detect(in:near:)`, resolves the path, and
//  calls a new delegate method so `TerminalPane` (or any future host) can open
//  the file in the built-in editor.
//
//  WHY NOT mouseDown. SwiftTerm's link activation fires in `mouseUp`
//  (Mac/MacTerminalView.swift:2500-2507). We mirror that phase so the two paths
//  stay symmetric: mouseDown snaps the scroll grid and acquires focus
//  (+SmoothScroll.swift:48-51); mouseUp is where link intent is resolved.
//
//  WHY THE DELEGATE EXTENSION IS HERE. `GoblinPortalTerminalViewDelegate` is
//  declared in `GoblinPortalTerminalView.swift`. Adding `didDetectFilePath` there
//  would push that file over the 350-LOC ceiling. The protocol is `@objc`-free
//  and Swift allows extending protocols in any file in the same module, so the
//  default implementation lives here alongside the code that calls it.
//

import AppKit
import SwiftTerm

// MARK: - Delegate method

extension GoblinPortalTerminalViewDelegate {
    /// Sent when the user ⌘-clicks a file-path pattern in terminal output.
    ///
    /// - Parameters:
    ///   - view: The terminal view that detected the click.
    ///   - path: Resolved, absolute URL of the file (FileManager confirmed it exists).
    ///   - line: 1-based line number from the compiler output.
    ///
    /// Default implementation is a no-op so existing conformers (`TerminalPane`)
    /// compile without change until they opt in.
    func terminalView(_ view: GoblinPortalTerminalView, didDetectFilePath path: URL, line: Int) {}
}

// MARK: - cmd+click intercept

extension GoblinPortalTerminalView {

    /// Try to handle `event` as a ⌘-click on a file-path reference.
    ///
    /// Call this from `mouseUp(with:)` *before* calling `super.mouseUp(with:)` so
    /// that a file-path match is consumed and SwiftTerm's URL-open path never sees it.
    /// Returns `true` if a match was found and the delegate was notified; the caller
    /// should return without calling super in that case.  Returns `false` when the
    /// click does not hit a recognisable file-path pattern — normal link/selection
    /// handling should proceed.
    ///
    /// Guard order:
    ///   1. ⌘ must be held — matches SwiftTerm's own `hasCommandModifier` test
    ///      (`Mac/MacTerminalView.swift:2500`).
    ///   2. We must have a bellDelegate (== a TerminalPane host) to route the result.
    ///   3. The click must map to a valid terminal row.
    ///   4. `FilePathDetector.detect` must find a match near the click column.
    ///   5. `FilePathDetector.resolve` must confirm the file exists on disk.
    @discardableResult
    func handleFilePathClick(event: NSEvent) -> Bool {
        // 1. Require ⌘.
        guard event.modifierFlags.contains(.command) else { return false }
        // 2. Require a delegate to route to.
        guard let delegate = bellDelegate else { return false }

        // 3. Map click to terminal row/column.
        let terminal = getTerminal()
        let cellSize = terminalCellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return false }

        let pointInView = convert(event.locationInWindow, from: nil)
        // Terminal rows are 0-based from the top of the visible viewport.
        // The view is not flipped, so top of content is at bounds.height.
        let row = Int((bounds.height - pointInView.y) / cellSize.height)
        let col = Int(pointInView.x / cellSize.width)

        // Clamp to valid visible rows (0..<terminal.rows).
        guard row >= 0 && row < terminal.rows else { return false }

        // 4. Extract text for that visible row and run the detector.
        // `terminalRowText(visibleRow:)` uses `getLine(row:)` which adds yDisp
        // internally — Terminal.swift:1228-1235.
        let rowText = terminalRowText(visibleRow: row)
        guard !rowText.isEmpty else { return false }

        guard let match = FilePathDetector.detect(in: rowText, near: col) else { return false }

        // 5. Resolve the path; skip remote/relative-with-no-cwd cases gracefully.
        let cwd = (processDelegate as? ShellHosting)?.currentDirectory
        guard let resolvedURL = FilePathDetector.resolve(match.path, cwd: cwd) else {
            if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
                FileHandle.standardError.write(
                    "[diag] file-path-click: could not resolve '\(match.path)' (cwd=\(cwd?.path ?? "nil"))\n"
                        .data(using: .utf8)!)
            }
            return false
        }

        if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
            FileHandle.standardError.write(
                "[diag] file-path-click: \(resolvedURL.path):\(match.line)\n"
                    .data(using: .utf8)!)
        }

        delegate.terminalView(self, didDetectFilePath: resolvedURL, line: match.line)
        return true
    }

    // MARK: - mouseUp intercept

    /// Override mouseUp to intercept ⌘-click on file paths BEFORE SwiftTerm's own
    /// URL-open path runs (`Mac/MacTerminalView.swift:2500-2507`).
    ///
    /// If `handleFilePathClick` returns true the event is consumed. Otherwise super
    /// runs normally, which covers URL clicks, text selection, and mouse reporting.
    ///
    /// `mouseUp` is `public` on `NSView` and not overridden by SwiftTerm with
    /// `@objc dynamic`, but it IS overridden as `public override func mouseUp` in
    /// `MacTerminalView` — so overriding it here (in an extension, since it is an
    /// `@objc` Objective-C method on NSView) works correctly on Swift 6.
    override func mouseUp(with event: NSEvent) {
        if handleFilePathClick(event: event) { return }
        super.mouseUp(with: event)
    }

    // MARK: - Row text extraction

    /// Extract the visible text of one terminal row using SwiftTerm's public API.
    ///
    /// `Terminal.getLine(row:)` takes a 0-based visible-viewport row and adds
    /// `buffer.yDisp` internally to reach the right entry in the scrollback buffer
    /// (`Terminal.swift:1228-1235`). `BufferLine.translateToString(trimRight:)`
    /// renders the cell array to a plain String, right-trimming trailing spaces
    /// (`BufferLine.swift:945-986`). Both are `public` API.
    ///
    /// `visibleRow` must be in `0..<terminal.rows`; callers guard this before calling.
    ///
    /// Internal (not private) so the unit gate can call it via a test shim if needed.
    func terminalRowText(visibleRow: Int) -> String {
        let terminal = getTerminal()
        guard let line = terminal.getLine(row: visibleRow) else { return "" }
        return line.translateToString(trimRight: true)
    }
}
