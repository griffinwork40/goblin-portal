//
//  LinkScheme.swift
//  Which URL schemes are safe to hand to NSWorkspace.shared.open from arbitrary terminal output.
//
//  Its own file, and deliberately view-free (Foundation only, no AppKit, no SwiftTerm), for the
//  same reason Renderer.swift, CursorStyle.swift and CommandOutcome.swift are: the *decision* is
//  a pure predicate over a string, and a pure predicate can be compiled into a gate —
//  check-links.sh — without linking an NSView. *Acting* on the decision (calling
//  NSWorkspace.shared.open) needs AppKit and lives in TerminalPane+Links.swift. Keeping them
//  apart is what makes the security-relevant allow-list auditable and testable without a window
//  server, a running emulator, or a full swift build.
//
//  WHY THE FILTER EXISTS. NSWorkspace.shared.open(url) is a shell-open: it dispatches to
//  whatever handler the user has registered for the scheme. A terminal that forwards arbitrary
//  link clicks without filtering therefore dispatches arbitrary scheme handlers on behalf of
//  any program that can print to a pty. SwiftTerm's plain-text detector
//  (ghosttyImplicitLinkRegex, Terminal.swift:6204) matches many schemes — http/https, mailto,
//  ftp, file, ssh, git, tel, magnet, ipfs, ipns, gemini, gopher, news — so the filter is the
//  PRIMARY defence for every detected link, not a backstop for a narrow category. Matching
//  Terminal.app and Ghostty, we allow a small safe set and block everything else.
//
//  WHY file:// IS IN THE ALLOW-LIST. Build tools, compilers, and formatters emit file:// paths
//  as clickable output. Terminal.app and Ghostty both allow it. The required ⌘-hover-then-click
//  gesture and Gatekeeper together bound the risk to files the user explicitly targeted.
//

import Foundation

/// The set of URL schemes safe to open from arbitrary terminal output.
enum LinkScheme {
    /// Schemes safe to hand to `NSWorkspace.shared.open` from arbitrary terminal output.
    ///
    /// `file` is a deliberate parity choice with Terminal.app and Ghostty: build tools and
    /// compilers routinely emit `file://` paths as clickable output, and the required
    /// ⌘-hover-then-click gesture plus Gatekeeper together bound the risk to files the user
    /// explicitly targeted. All three of the named terminals allow it.
    ///
    /// `javascript`, `mailto`, `ftp`, `ssh`, `git`, `data`, and custom/unknown schemes are
    /// intentionally absent — they route to arbitrary registered handlers and, in some cases
    /// (javascript:, data:), can escape sandboxes.
    static let allowed: Set<String> = ["https", "http", "file"]

    /// Returns `true` iff the scheme is in the allow-list.
    ///
    /// Case-insensitive, matching URL parsing convention (RFC 3986 §3.1 requires parsers
    /// to normalise scheme to lower case). `nil` and the empty string are treated as unsafe
    /// — a URL with no scheme cannot be classified and must not be opened.
    static func isSafe(_ scheme: String?) -> Bool {
        guard let s = scheme, !s.isEmpty else { return false }
        return allowed.contains(s.lowercased())
    }
}
