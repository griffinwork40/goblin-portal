//
//  TerminalPane+Links.swift
//  URL clicking — ⌘-hover to highlight, ⌘-click to open.
//
//  Its own file because TerminalPane.swift is at the 350-LOC ceiling and this is a
//  whole independent concern: detecting URLs in terminal output and opening them.
//
//  HOW LINK CLICKING WORKS IN SWIFTTERM (the wiring, so future readers do not have
//  to grep the vendor tree):
//
//  1. DETECTION. `MacTerminalView` tracks links via `view.linkReporting`:
//       .none     — no tracking at all
//       .explicit — OSC 8 hyperlinks only (e.g. `\e]8;;https://…\a`)
//       .implicit — OSC 8 first, then falls back to plain-text URL detection
//     We use `.implicit` so that both OSC 8 payloads and bare URLs printed to the
//     terminal are clickable without requiring the program to emit hyperlink escapes.
//     Set in `GoblinPortalTerminalView.init(frame:)`.
//     Source: `Apple/AppleTerminalView.swift:41-49`, `Mac/MacTerminalView.swift:889-890`.
//
//  2. HIGHLIGHTING. `view.linkHighlightMode` controls when underlines appear and
//     when a click is honoured:
//       .hover             — underline on hover; click always activates
//       .hoverWithModifier — underline on ⌘+hover; click activates only if highlighted
//       .always            — always underline explicit links; click activates
//       .alwaysWithModifier — underline explicit links when ⌘ held; click when highlighted
//     `.hoverWithModifier` (the default and our setting) is the standard macOS terminal
//     convention: hold ⌘ to reveal and activate links, plain clicks remain free for
//     selection and mouse reporting. iTerm2, Ghostty, and Terminal.app all behave this way.
//     Source: `Apple/AppleTerminalView.swift:51-68`, `Mac/MacTerminalView.swift:893`.
//
//  3. ACTIVATION. On mouse-up, `MacTerminalView.mouseUp(with:)` calls `linkForClick`,
//     which requires both `hasCommandModifier` AND that the link is currently
//     highlighted (the user was hovering with ⌘ held). If matched, it invokes
//     `terminalDelegate?.requestOpenLink(source:link:params:)`.
//     Source: `Mac/MacTerminalView.swift:2500-2507`,
//             `Apple/AppleTerminalView.swift:935-951`.
//
//  4. DELEGATE. `LocalProcessTerminalView` sets `terminalDelegate = self` in its own
//     `setup()` (`Mac/MacLocalTerminalView.swift:85`). Its `requestOpenLink` forwards
//     to `openLink(_:)`, which validates and opens. We override `requestOpenLink` in
//     `GoblinPortalTerminalView` — the subclass that already exists for Goblin Portal-specific behaviour —
//     to filter to safe schemes and log under `GOBLIN_PORTAL_DIAG`. Reassigning `terminalDelegate`
//     is explicitly warned against upstream (`MacLocalTerminalView.swift:59-64`), so the
//     override is the correct hook.
//     Source: `Mac/MacTerminalView.swift:3020-3030`.
//
//  WHY TERMINALVIEW, NOT TERMINALPANE. `requestOpenLink` is on `TerminalViewDelegate`,
//  not `LocalProcessTerminalViewDelegate`. `TerminalPane` conforms to the latter; only
//  `GoblinPortalTerminalView` (which extends `LocalProcessTerminalView`) is the delegate.
//  There is nothing for `TerminalPane` to implement here — the link callback never
//  reaches it. The concern file lives here so the architecture is documented in one
//  place, and so any future `TerminalPane`-level hook (custom link handler, open-in-
//  editor routing, security policy) has an obvious home.
//

import AppKit
import SwiftTerm

// MARK: - GoblinPortalTerminalView link activation

extension GoblinPortalTerminalView {
    /// Open `link` in the default browser, filtering to schemes that are safe to
    /// hand to `NSWorkspace.shared.open` without prompting the user.
    ///
    /// WHY SCHEME-FILTER. `NSWorkspace.shared.open(url)` is a shell-open: it honours
    /// the URL's scheme and dispatches to whatever handler the user has registered.
    /// The base `openLink(_:)` in SwiftTerm (`Mac/MacTerminalView.swift:3020-3025`)
    /// accepts any string parseable as a `URL(string:)` with no scheme check at all.
    ///
    /// The plain-text detector, `ghosttyImplicitLinkRegex` (`Terminal.swift:6204`),
    /// matches many schemes from raw terminal output — `https?://`, `mailto:`, `ftp://`,
    /// `file:`, `ssh:`, `git://`, `tel:`, `magnet:`, `ipfs://`, `gemini://`, and more.
    /// OSC 8 payloads are arbitrary: a rogue program can emit any scheme it likes.
    /// `openSafeURL`'s allow-list is therefore the PRIMARY defence for every detected
    /// link — plain-text and OSC 8 alike — not a backstop for a narrow category.
    ///
    /// The allow-list is {https, http, file} (see `LinkScheme.allowed`). `file://` is
    /// deliberately included to match Terminal.app and Ghostty: build tools and compilers
    /// routinely emit `file://` paths as clickable output, and the required ⌘-hover-
    /// then-click gesture plus Gatekeeper together bound the risk. `mailto`, `ftp`, `ssh`,
    /// `javascript`, `data`, and all custom/unknown schemes are blocked because they
    /// dispatch to arbitrary registered handlers.
    func openSafeURL(_ link: String) {
        guard let url = URL(string: link) else {
            if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
                FileHandle.standardError.write(
                    "[diag] link-click: not a valid URL — \(link.count) chars\n"
                        .data(using: .utf8)!)
            }
            return
        }
        guard LinkScheme.isSafe(url.scheme) else {
            if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
                let scheme = url.scheme ?? "?"
                FileHandle.standardError.write(
                    "[diag] link-click: scheme '\(scheme)' blocked\n"
                        .data(using: .utf8)!)
            }
            return
        }
        if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
            let loc = "\(url.scheme ?? "?")://\(url.host ?? "")"
            FileHandle.standardError.write(
                "[diag] link-click: opening \(loc)\n"
                    .data(using: .utf8)!)
        }
        NSWorkspace.shared.open(url)
    }
}
