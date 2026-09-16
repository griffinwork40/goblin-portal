//
//  DocumentStatus+Presentation.swift
//  How a `DocumentStatus` looks in the tab strip: one colour, or nothing.
//
//  Its own file, rather than riding along in `DocumentTabStrip+Drawing.swift`, because
//  it extends a DIFFERENT type. `DocumentStatus` is declared in `SpaceDocument.swift`
//  and belongs to the document seam, not to the strip; this is the strip's chosen
//  presentation of it. Keeping it separate makes the direction of the dependency
//  legible — the strip renders the status enum, the status enum knows nothing about the
//  strip — and it means the next surface that wants to show status (an overflow-menu
//  badge, a Space-level indicator) extends this file instead of reaching into a
//  drawing routine.
//

import AppKit

// MARK: - Status presentation

// Was `private extension` when this lived at the bottom of `DocumentTabStrip.swift`.
// It has to be internal now: the only caller is `drawTab` in
// `DocumentTabStrip+Drawing.swift`, and Swift's `private` (and `fileprivate`) stop at
// this file's edge. Internal, not more — nothing outside the module has any business
// asking what colour a status is.
extension DocumentStatus {
    /// The dot's colour, or nil for "draw nothing".
    ///
    /// System colours, not hex literals: they are the only ones that adapt to Increase
    /// Contrast and to the window's effective appearance, and this app already derives
    /// its chrome from the theme rather than hardcoding it (`DocumentTabStrip`'s
    /// `railBackground`, `SpaceWindowController`'s window colour).
    ///
    /// `fallback` is the terminal's own foreground, used for `.succeeded`: green would
    /// be the obvious choice and is the wrong one — a green dot on a tab is the same
    /// "there is news" weight as a red one, and a finished command is not a problem.
    /// The neutral dot says "this changed" and leaves red for the case that earned it.
    func dotColour(fallback: NSColor, isActive: Bool) -> NSColor? {
        switch self {
        case .idle:
            return nil
        case .running:
            // Unreachable today — see the enum. A running command is the *least*
            // remarkable non-idle state, hence the dimmest treatment.
            return fallback.withAlphaComponent(isActive ? 0.55 : 0.45)
        case .succeeded:
            return fallback.withAlphaComponent(isActive ? 0.9 : 0.8)
        case .failed:
            return .systemRed
        case .attention:
            // The one wired case. Blue rather than yellow: it is the platform's
            // "something wants you" colour (unread badges, sidebar dots) and it does not
            // read as a warning, which a waiting prompt is not.
            return .controlAccentColor
        }
    }
}
