//
//  UpdateChecker.swift
//  Check for new releases on GitHub and offer the user a way to download them.
//
//  A lightweight alternative to Sparkle that fits this project: no framework
//  dependency, no appcast XML, no automatic installation. It hits the GitHub
//  Releases API, compares the tag against the running bundle version, and shows
//  an NSAlert linking to the release page. The user downloads the zip and drags
//  to /Applications — the same flow every non-App Store Mac app has used since
//  2001.
//
//  Two paths:
//    • Auto-check on launch, at most once per 24 hours, silent on failure.
//    • Manual check from the app menu (Help → Check for Updates…), always runs,
//      shows "up to date" or "couldn't reach GitHub" instead of staying silent.
//
//  The GitHub API for public repos needs no auth. While the repo is private the
//  auto-check silently returns nothing (404 → no update); the manual check says
//  so explicitly. This means the feature lights up automatically the moment the
//  repo goes public, with zero code changes.
//

import AppKit
import Foundation

/// One-file update checker against GitHub Releases.
///
/// Usage from `AppDelegate`:
///   `UpdateChecker.shared.checkOnLaunch(currentVersion:)` — in `applicationDidFinishLaunching`
///   `UpdateChecker.shared.checkNow(currentVersion:)` — from the menu action
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    // --- Configuration -----------------------------------------------------------

    /// Owner/repo for the GitHub API. Change only if the repo moves.
    private static let repo = "griffinwork40/umber"

    /// Minimum seconds between automatic checks. Manual checks bypass this.
    private static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    /// UserDefaults key for the last auto-check timestamp.
    private static let lastCheckKey = "GoblinPortal.lastUpdateCheck"

    /// UserDefaults key for a version the user chose to skip.
    private static let skippedVersionKey = "GoblinPortal.skippedUpdateVersion"

    // --- Public API --------------------------------------------------------------

    /// Silent launch-time check. Respects the 24-hour cooldown and the user's
    /// "skip this version" choice. Network or API errors are swallowed — a
    /// launch-time check must never show an error dialog.
    func checkOnLaunch(currentVersion: String) {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard now - last >= Self.autoCheckInterval else { return }

        let skippedKey = Self.skippedVersionKey
        let lastCheckKey = Self.lastCheckKey
        fetchLatestRelease { [weak self] release in
            guard let release else { return }
            UserDefaults.standard.set(now, forKey: lastCheckKey)
            guard UpdateChecker.isNewer(release.version, than: currentVersion),
                  release.version != UserDefaults.standard.string(forKey: skippedKey)
            else { return }
            self?.showUpdateAlert(release: release, isManual: false)
        }
    }

    /// Explicit check from the menu. Always runs, always shows feedback.
    func checkNow(currentVersion: String) {
        fetchLatestRelease { [weak self] release in
            if let release, UpdateChecker.isNewer(release.version, than: currentVersion) {
                self?.showUpdateAlert(release: release, isManual: true)
            } else if let release, !UpdateChecker.isNewer(release.version, than: currentVersion) {
                self?.showUpToDateAlert(currentVersion: currentVersion)
            } else {
                self?.showErrorAlert()
            }
        }
    }

    // --- GitHub API --------------------------------------------------------------

    private struct Release {
        let version: String   // e.g. "0.2.0" (tag stripped of leading "v")
        let tag: String       // e.g. "v0.2.0"
        let url: URL          // release page on GitHub
        let name: String      // release title
    }

    /// Fetches the latest release from GitHub. The completion is always called on
    /// the main thread with `nil` on any failure (network, HTTP, parse).
    private func fetchLatestRelease(completion: @escaping @MainActor (Release?) -> Void) {
        let endpoint = "https://api.github.com/repos/\(Self.repo)/releases/latest"
        guard let url = URL(string: endpoint) else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // No auth header — works for public repos; returns 404 for private ones,
        // which the caller handles as nil.

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let data,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlUrl = json["html_url"] as? String,
                  let pageURL = URL(string: htmlUrl)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let name = (json["name"] as? String) ?? tag
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            let release = Release(version: version, tag: tag, url: pageURL, name: name)
            DispatchQueue.main.async { completion(release) }
        }.resume()
    }

    // --- Version comparison ------------------------------------------------------

    /// True when `remote` is strictly newer than `local` by semver comparison.
    /// `nonisolated` so callers inside `@Sendable` closures can use it without
    /// hopping to the main actor — it is pure arithmetic over two strings.
    nonisolated private static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) }
        let l = local.split(separator: ".").map { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? (r[i] ?? 0) : 0
            let lv = i < l.count ? (l[i] ?? 0) : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    // --- UI (NSAlert) ------------------------------------------------------------

    private func showUpdateAlert(release: Release, isManual: Bool) {
        let alert = NSAlert()
        alert.messageText = "A new version of Goblin Portal is available"
        alert.informativeText = "\(release.name) is available — you have \(Self.bundleVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if !isManual {
            alert.addButton(withTitle: "Skip This Version")
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.url)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    private func showUpToDateAlert(currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Goblin Portal \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorAlert() {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "Unable to reach GitHub. Check your connection and try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The running app's version from Info.plist, or "0.0.0" if unset (swift run
    /// without a bundle). Kept here rather than passed through every call site so
    /// the menu action can be a zero-argument `#selector`.
    static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}
