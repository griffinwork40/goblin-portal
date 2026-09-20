//
//  UpdateChecker.swift
//  Check for new releases on GitHub and offer in-place installation.
//
//  Hits the GitHub Releases API, compares the tag against the running bundle
//  version, and shows an NSAlert with "Install Update" (downloads the zip and
//  replaces the app in place via UpdateInstaller) or "View on GitHub" (opens
//  the release page). No framework dependency, no appcast XML.
//
//  Two paths:
//    - Auto-check on launch, at most once per 24 hours, silent on failure.
//    - Manual check from the app menu (Help > Check for Updates...), always
//      runs, shows "up to date" or "couldn't reach GitHub" instead of silence.
//
//  The GitHub API for public repos needs no auth. While the repo is private the
//  auto-check silently returns nothing (404 -> no update); the manual check
//  says so explicitly. The feature lights up automatically the moment the repo
//  goes public, with zero code changes.
//

import AppKit
import Foundation

/// NSAlert response for the fourth button ("Skip This Version").
/// NSApplication.ModalResponse values are 1000-based: first = 1000, second = 1001,
/// third = 1002, fourth = 1003.
private let alertFourthButtonReturn = NSApplication.ModalResponse(rawValue: 1003)

/// One-file update checker against GitHub Releases.
///
/// Usage from `AppDelegate`:
///   `UpdateChecker.shared.checkOnLaunch(currentVersion:)` -- in `applicationDidFinishLaunching`
///   `UpdateChecker.shared.checkNow(currentVersion:)` -- from the menu action
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    // --- Configuration -----------------------------------------------------------

    /// Owner/repo for the GitHub API. Change only if the repo moves.
    private static let repo = "griffinwork40/goblin-portal"

    /// Minimum seconds between automatic checks. Manual checks bypass this.
    private static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    /// UserDefaults key for the last auto-check timestamp.
    private static let lastCheckKey = "GoblinPortal.lastUpdateCheck"

    /// UserDefaults key for a version the user chose to skip.
    private static let skippedVersionKey = "GoblinPortal.skippedUpdateVersion"

    // --- Public API --------------------------------------------------------------

    /// Silent launch-time check. Respects the 24-hour cooldown and the user's
    /// "skip this version" choice. Network or API errors are swallowed -- a
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

    struct Release {
        let version: String   // e.g. "0.2.0" (tag stripped of leading "v")
        let tag: String       // e.g. "v0.2.0"
        let url: URL          // release page on GitHub
        let name: String      // release title
        let zipURL: URL?      // direct download URL for the .zip asset, if any
        // S2 -- SHA-256 sidecar asset URL, e.g. "Goblin Portal-v0.3.0.zip.sha256".
        // nil when the release predates hash publishing or is from a private repo
        // where assets are not visible. UpdateInstaller skips verification gracefully
        // when this is nil -- it only blocks on a mismatch, never on absence.
        let zipHashURL: URL?
    }

    /// Fetches the latest release from GitHub. The completion is always called on
    /// the main thread with `nil` on any failure (network, HTTP, parse).
    private func fetchLatestRelease(completion: @escaping @MainActor (Release?) -> Void) {
        let endpoint = "https://api.github.com/repos/\(Self.repo)/releases/latest"
        guard let url = URL(string: endpoint) else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // No auth header -- works for public repos; returns 404 for private ones,
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

            // Find the .zip asset in the release's assets array. The release
            // workflow uploads Goblin Portal-vX.Y.Z.zip as the installable
            // artifact (ditto-compressed, code-signed, notarised).
            // S2 -- Also extract the companion .sha256 sidecar when present.
            // findHashAsset is kept separate from findZipAsset so the existing
            // belt-and-suspenders .sha256 exclusion in findZipAsset is unchanged.
            let zipURL = Self.findZipAsset(in: json)
            let zipHashURL = Self.findHashAsset(in: json)

            let release = Release(
                version: version, tag: tag, url: pageURL,
                name: name, zipURL: zipURL, zipHashURL: zipHashURL
            )
            DispatchQueue.main.async { completion(release) }
        }.resume()
    }

    /// Extracts the `.zip` asset download URL from the release JSON's `assets`
    /// array. Returns `nil` if there is no zip asset (pre-automation releases
    /// that only have a DMG, or private repos where assets are not visible).
    ///
    /// Item 4 -- Two additional guards beyond the original `.zip` suffix check:
    ///   • Name prefix: only accept "GoblinPortal-*.zip". A malicious or
    ///     mis-tagged release that happens to include a foreign zip cannot be
    ///     installed in place of Goblin Portal. Asset filenames use no space
    ///     because GitHub normalizes spaces to dots in release asset names.
    ///   • Host allowlist: the download URL's host must be
    ///     objects.githubusercontent.com (CDN) or github.com (direct). Any
    ///     other host would mean the release JSON was tampered with or the API
    ///     returned an unexpected redirect target.
    ///   The existing `.sha256` exclusion is kept as belt-and-suspenders.
    nonisolated private static func findZipAsset(
        in json: [String: Any]
    ) -> URL? {
        // Item 4: allowed CDN/release hosts for GitHub asset downloads.
        let allowedHosts: Set<String> = [
            "objects.githubusercontent.com",
            "github.com",
        ]
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        for asset in assets {
            guard let assetName = asset["name"] as? String,
                  assetName.hasSuffix(".zip"),
                  !assetName.hasSuffix(".sha256"),       // belt-and-suspenders
                  assetName.hasPrefix("GoblinPortal-"),  // Item 4: name prefix guard (no space -- GitHub normalizes spaces in asset names)
                  let downloadURL = asset["browser_download_url"] as? String,
                  let url = URL(string: downloadURL),
                  url.scheme == "https",                  // Item 4: reject non-HTTPS
                  let host = url.host,                   // Item 4: host allowlist
                  allowedHosts.contains(host)
            else { continue }
            return url
        }
        return nil
    }

    /// S2 -- Extracts the `.sha256` sidecar asset URL that matches the zip asset
    /// (e.g. "Goblin Portal-v0.3.0.zip.sha256"). Returns `nil` when no sidecar
    /// is present (old releases, private repos) -- UpdateInstaller proceeds
    /// without verification in that case (graceful degradation).
    ///
    /// Applies the same host allowlist and HTTPS requirement as findZipAsset
    /// so a tampered release JSON cannot redirect the hash fetch to an
    /// attacker-controlled host and serve a matching forged hash.
    nonisolated private static func findHashAsset(
        in json: [String: Any]
    ) -> URL? {
        let allowedHosts: Set<String> = [
            "objects.githubusercontent.com",
            "github.com",
        ]
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        for asset in assets {
            guard let assetName = asset["name"] as? String,
                  assetName.hasSuffix(".zip.sha256"),
                  assetName.hasPrefix("GoblinPortal-"),  // no space -- GitHub normalizes spaces
                  let downloadURL = asset["browser_download_url"] as? String,
                  let url = URL(string: downloadURL),
                  url.scheme == "https",
                  let host = url.host,
                  allowedHosts.contains(host)
            else { continue }
            return url
        }
        return nil
    }

    // --- Version comparison ------------------------------------------------------

    /// True when `remote` is strictly newer than `local` by semver comparison.
    /// `nonisolated` so callers inside `@Sendable` closures can use it without
    /// hopping to the main actor -- it is pure arithmetic over two strings.
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

        // "Install Update" is available when the release has a downloadable zip
        // asset AND the app is running from a writable location (not a DMG or
        // swift run). Otherwise fall back to the browser download path.
        // S-3 -- require both the zip asset AND the hash sidecar before offering
        // in-place install. Without the sidecar the integrity check in
        // extractAndInstall is skipped, so a release without a .sha256 asset must
        // fall back to the browser-download path instead of installing silently
        // unverified.
        let canInstallInPlace = release.zipURL != nil && release.zipHashURL != nil && canSelfUpdate()
        if canInstallInPlace {
            alert.addButton(withTitle: "Install Update")
        }
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Later")
        if !isManual {
            alert.addButton(withTitle: "Skip This Version")
        }

        let response = alert.runModal()

        if canInstallInPlace {
            switch response {
            case .alertFirstButtonReturn:
                // Install Update -- S2: pass zipHashURL so the installer can
                // verify the download before extraction. nil = skip gracefully.
                UpdateInstaller.shared.install(
                    zipURL: release.zipURL!,
                    zipHashURL: release.zipHashURL,
                    releaseName: release.name
                )
            case .alertSecondButtonReturn:
                // View on GitHub
                NSWorkspace.shared.open(release.url)
            case alertFourthButtonReturn where !isManual:
                UserDefaults.standard.set(
                    release.version, forKey: Self.skippedVersionKey
                )
            default:
                break
            }
        } else {
            switch response {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(release.url)
            case .alertThirdButtonReturn where !isManual:
                UserDefaults.standard.set(
                    release.version, forKey: Self.skippedVersionKey
                )
            default:
                break
            }
        }
    }

    /// True when the app is installed in a writable location and has a real
    /// bundle (not `swift run`). The trampoline needs write access to the
    /// parent directory to swap the bundle.
    private func canSelfUpdate() -> Bool {
        guard Bundle.main.infoDictionary?["CFBundleIdentifier"] != nil else {
            return false
        }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
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
