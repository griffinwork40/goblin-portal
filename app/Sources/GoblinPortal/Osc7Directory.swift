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
    /// names that mean "this machine". Returns nil for malformed input, wrong scheme,
    /// relative paths, userinfo, or a port in the URL.
    ///
    /// For `file://` URLs:
    ///   - The host is compared case-insensitively against `localHostnames`.
    ///   - An empty authority (`file:///path`) counts as local — RFC 8089 §2 treats
    ///     an absent/empty host as meaning localhost.
    ///   - A matching host → `.local(path:)` with Foundation's single percent-decode
    ///     (`URL.path`; never call `removingPercentEncoding` again, so a literal `%2520`
    ///     stays `%20` after one pass rather than becoming a space).
    ///   - A non-matching host → `.remote(host:)`, keeping the host as reported (not
    ///     lowercased) so display text is faithful to what the shell emitted.
    ///   - Userinfo (user@host) or a port (host:N) → nil. Neither appears in a well-formed
    ///     file: URI (RFC 8089 §2 forbids userinfo; file: has no port), and allowing them
    ///     could silently accept an ssh:// look-alike.
    ///
    /// For bare absolute paths (no scheme): always `.local(path:)` — no host question.
    ///
    /// Returns nil for: relative paths, non-`file:` schemes, empty input, userinfo/port,
    /// an empty path after URL parsing.
    ///
    /// Self-contained: does NOT call `ShellIntegration.parseOsc7Directory` — that is now
    /// a thin wrapper around this function, and calling it would be circular.
    static func parse(_ raw: String, localHostnames: Set<String>) -> Osc7Directory? {
        guard !raw.isEmpty else { return nil }

        if raw.hasPrefix("file://") {
            // URL(string:) handles the full RFC 3986 parse including percent-encoding.
            guard let url = URL(string: raw) else { return nil }

            // url.user and url.port must both be absent. Userinfo in file: URIs is not
            // meaningful (RFC 8089 §2) and a port signals a non-file URL masquerading as one.
            guard url.user == nil, url.port == nil else { return nil }

            // url.path gives the single-decoded POSIX path (Foundation docs: "the path,
            // unescaped"). Never call removingPercentEncoding again — that would be a second
            // decode pass and would turn a literal directory named "%20" (encoded as "%2520")
            // into a space rather than the correct "%20".
            let decoded = url.path
            guard !decoded.isEmpty else { return nil }

            // url.host returns nil for `file:///path` (empty authority). Treat nil or ""
            // as empty — both mean "this machine" per RFC 8089 §2.
            let urlHost = (url.host ?? "").lowercased()

            if localHostnames.contains(urlHost) {
                return .local(path: decoded)
            } else {
                // Keep the host as reported (url.host, not the lowercased form) so display
                // text is faithful to what the remote shell emitted.
                return .remote(host: url.host ?? "")
            }
        } else {
            // Bare path (no scheme). Only absolute paths are valid working directories.
            // Relative paths cannot be resolved without a base, so they are rejected.
            guard raw.hasPrefix("/") else { return nil }
            return .local(path: raw)
        }
    }

    /// Host spellings that mean this machine: `""` (empty authority), `"localhost"`,
    /// and names derived from `gethostname()` (lowercased): the full name, the short
    /// form (text before the first dot), and the `.local` mDNS variant.
    ///
    /// Why `gethostname()` and not `ProcessInfo.processInfo.hostName`:
    ///   `ProcessInfo.hostName` resolves via DNS which can block on the main thread,
    ///   and `currentLocalHostnames()` is called on the main actor. `gethostname()`
    ///   reads the kernel hostname string directly (same as zsh's `$HOST`, which is
    ///   what `shell-integration.zsh` writes into the OSC 7 host field).
    ///
    /// Why include the `.local` variant: macOS mDNS (Bonjour) appends `.local` to the
    /// hostname; `gethostname()` itself may or may not include it depending on the
    /// machine's network configuration, so we always include both forms.
    ///
    /// Why NOT add other guessed suffixes (e.g. `.example.com`): the goal is zero false
    /// positives. A hostname not in the set becomes `.remote`, which is safe — the sidebar
    /// ignores it. A false positive would silently re-root the sidebar at a remote path.
    static func currentLocalHostnames() -> Set<String> {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, 255)
        // String(cString:) is always safe here: the buffer is null-terminated by
        // gethostname on success and was pre-zeroed on failure.
        let full = String(cString: &buf).lowercased()

        // Short form: text before the first dot (e.g. "griffins-macbook-pro" from
        // "griffins-macbook-pro.local"). If there is no dot, short == full.
        let short: String
        if let dot = full.firstIndex(of: ".") {
            short = String(full[full.startIndex..<dot])
        } else {
            short = full
        }

        // .local variant: if full already ends in ".local" the variant is full itself;
        // otherwise append it so both are in the set.
        let dotLocal = full.hasSuffix(".local") ? full : "\(full).local"

        return ["", "localhost", full, short, dotLocal]
    }
}
