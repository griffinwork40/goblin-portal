//
//  GoblinPortalTerminalViewDelegate.swift
//  The event contract for terminal view consumers — extracted from
//  GoblinPortalTerminalView.swift at the 350-LOC ceiling.
//

import Foundation

/// Callbacks from `GoblinPortalTerminalView` to its owning `TerminalPane`.
/// Separate from `LocalProcessTerminalViewDelegate` because SwiftTerm's own
/// protocol carries exactly four members (sizeChanged, setTerminalTitle,
/// hostCurrentDirectoryUpdate, processTerminated) and does not forward the
/// bell or file-path detection events this app needs.
@MainActor
protocol GoblinPortalTerminalViewDelegate: AnyObject {
    /// The program in this terminal rang the bell (BEL / `\a`).
    func terminalViewDidRingBell(_ view: GoblinPortalTerminalView)

    /// The user cmd-clicked a compiler-style file-path reference (`/path/file.swift:42`)
    /// in terminal output. `path` is absolute and confirmed to exist on disk.
    /// `line` is 1-based. Default implementation is a no-op so existing conformers
    /// compile without change — see `GoblinPortalTerminalView+FilePath.swift`.
    func terminalView(_ view: GoblinPortalTerminalView, didDetectFilePath path: URL, line: Int)
}
