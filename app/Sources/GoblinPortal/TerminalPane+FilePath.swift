//
//  TerminalPane+FilePath.swift
//  Receives file-path click events from GoblinPortalTerminalView and opens the file
//  in the built-in editor at the right line.
//
//  Its own file because:
//  • TerminalPane+Links.swift documents the URL-click path and is a natural sibling,
//    but TerminalPane+Links.swift has no code — the URL path lives entirely in
//    GoblinPortalTerminalView (see that file's header for why). Adding editor-open
//    logic there would be a misnomer.
//  • TerminalPane.swift is at the 350-LOC ceiling.
//  • The concern (receive a resolved URL + line, call space.openFile, then scrollToLine)
//    is completely self-contained.
//
//  CALL CHAIN (from cmd+click to cursor placement):
//    GoblinPortalTerminalView.mouseUp
//      → handleFilePathClick (GoblinPortalTerminalView+FilePath.swift)
//        → FilePathDetector.detect + resolve
//          → terminalView(_:didDetectFilePath:line:)   ← this file
//            → SpaceViewController.openFile(url:)      ← dedupes tabs
//              → FileViewerPane created/activated
//                → scrollToLine(line)                  ← FileViewerPane+Navigation.swift
//
//  WHY CAST TO SpaceViewController. `documentDelegate` is typed as `SpaceDocumentDelegate?`,
//  which carries only termination/title/status callbacks — not `openFile`. The only real
//  conformer at runtime is `SpaceViewController`, which does have `openFile(url:)`.
//  Casting is narrower than adding `openFile` to `SpaceDocumentDelegate` (that protocol
//  is about reporting state, not requesting navigation) and avoids a protocol change that
//  would require `FileViewerPane` and other future conformers to stub an unrelated method.
//

import AppKit

// MARK: - File-path click handler
//
// The GoblinPortalTerminalViewDelegate conformance declaration lives in
// TerminalPane.swift:283 (alongside `terminalViewDidRingBell`). Swift allows
// protocol method implementations to be split across extension files in the same
// module — the conformance is declared once; the methods satisfy it from anywhere.

extension TerminalPane {

    /// Received when `GoblinPortalTerminalView+FilePath.swift` resolves a ⌘-clicked
    /// file-path reference. The URL is already absolute and confirmed to exist by
    /// `FilePathDetector.resolve(_:cwd:)`.
    ///
    /// We route through `documentDelegate` cast to `SpaceViewController` — the only
    /// type that both conforms to `SpaceDocumentDelegate` and exposes `openFile(url:)`.
    /// A nil cast means the pane is not yet attached to a space (e.g. during teardown),
    /// and we silently skip rather than crash.
    ///
    /// `scrollToLine` is called after `openFile` returns. `openFile` returns the
    /// `FileViewerPane` (created or existing) synchronously on the main actor, so the
    /// scroll is always applied to the correct viewer.
    func terminalView(_ view: GoblinPortalTerminalView, didDetectFilePath path: URL, line: Int) {
        guard let space = documentDelegate as? SpaceViewController else { return }
        let viewer = space.openFile(url: path)
        // scrollToLine is 1-based, matching compiler output conventions.
        // FilePathDetector already enforces lineNum > 0 (regex captures \d+, real
        // compilers never emit line 0), but guard here so a hypothetical 0 is a no-op.
        if line > 0 {
            viewer.scrollToLine(line)
        }
    }
}
