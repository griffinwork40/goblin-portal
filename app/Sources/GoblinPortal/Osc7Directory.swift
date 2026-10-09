//
//  Osc7Directory.swift
//  What an OSC 7 report means: a directory on THIS machine, or a remote host.
//
//  Pure and view-free — Foundation only — compiled by `check-shell-integration.sh`
//  beside `ShellIntegration.swift`.
//
//  WHY THIS EXISTS. OSC 7 carries `file://<host>/<path>`. Until this file, the host was
//  discarded (`ShellIntegration.parseOsc7Directory`), so a shell on another machine that
//  reported `/home/me/src` — or, worse, `/tmp` — re-rooted the local sidebar at a local
//  path that merely shares the spelling. The host is the only part of the message that
//  says which filesystem the path belongs to, so it must decide whether the path is used
//  at all. A remote report survives only as display text ("remote: host").
//
//  CONTRACT FROZEN in wave 0 (K). Lane D owns the bodies.
//

import Foundation

/// A parsed OSC 7 report.
enum Osc7Directory: Equatable {
    /// A directory on this machine (percent-decoded, absolute; not yet symlink-resolved).
    case local(path: String)
    /// A report from another machine. Its path is deliberately not kept: nothing may
    /// treat it as a local directory.
    case remote(host: String)

    /// Parse `raw` (`file://host/path`, or a bare absolute path) against the set of host
    /// names that mean "this machine". Nil for malformed input.
    static func parse(_ raw: String, localHostnames: Set<String>) -> Osc7Directory? {
        // K STUB (lane D replaces): behaviour-preserving — every report is local, exactly
        // as before this file existed.
        ShellIntegration.parseOsc7Directory(raw).map { .local(path: $0) }
    }

    /// Host spellings that mean this machine: empty, `localhost`, and this host's names
    /// (lowercased). Matches zsh's `$HOST`, which the integration script emits.
    static func currentLocalHostnames() -> Set<String> {
        // K STUB (lane D replaces).
        ["", "localhost"]
    }
}
