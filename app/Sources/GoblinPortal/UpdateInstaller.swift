//
//  UpdateInstaller.swift
//  Download a release zip from GitHub and replace the running app in place.
//
//  The flow:
//    1. Download the zip asset to a temporary directory.
//    2. Extract with `ditto -x -k` (preserves extended attributes and code
//       signatures -- plain `unzip` does not).
//    3. Verify the extracted .app exists, has the expected bundle identifier,
//       and contains an executable.
//    4. Launch a trampoline script that waits for this process to exit, swaps
//       the old bundle for the new one with `mv`, and relaunches.
//    5. Call `NSApp.terminate` to hand off to the trampoline.
//
//  Why a trampoline: an app cannot replace its own bundle while it is running
//  -- the executable is memory-mapped, and replacing it under a live process is
//  undefined. Every non-App-Store updater (Sparkle, iTerm2, Alacritty) uses
//  the same pattern: a helper process outlives the app and does the swap.
//
//  The trampoline is `install-update.sh`, bundled as a `.copy` resource. It
//  receives four arguments: the PID to wait on, the path to the new .app, the
//  path to the installed .app, and the temp directory to clean up after. It is
//  the only file that touches /Applications.
//
//  Item 5 -- the extraction and install concern (ditto, bundle verification,
//  trampoline launch) lives in UpdateInstaller+Install.swift. This file owns
//  the public API, the download path, the progress UI, and the error helpers
//  that the install extension calls back into via MainActor.run.
//

import AppKit
import CryptoKit
import Foundation

// MARK: - Redirect-refusing URLSession delegate

/// Refuses HTTP redirects to hosts outside the GitHub download allowlist.
/// URLSession follows redirects by default with no callback; without this
/// delegate a compromised CDN redirect could deliver arbitrary content from
/// a non-allowlisted host. The allowlist matches UpdateChecker.findZipAsset.
///
/// `internal` (not `private`) so UpdateInstaller+Install.swift can create a
/// second instance for the SHA-256 sidecar fetch (S2). Private is file-scoped
/// in Swift and invisible to the extension file. Same access pattern as
/// fail() and cleanup() in UpdateInstaller.swift.
final class DownloadRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static let allowedHosts: Set<String> = [
        "objects.githubusercontent.com",
        "github.com",
    ]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let host = request.url?.host,
           Self.allowedHosts.contains(host),
           request.url?.scheme == "https" {
            completionHandler(request)
        } else {
            // Refuse the redirect -- the download task receives the redirect
            // response as its final response and the completion handler sees
            // a non-200 status, which download() handles as a failure.
            completionHandler(nil)
        }
    }
}

/// Downloads a release zip and installs it over the running app bundle.
///
/// Usage from `UpdateChecker`:
///   `UpdateInstaller.shared.install(zipURL:releaseName:)`
@MainActor
final class UpdateInstaller {
    static let shared = UpdateInstaller()

    /// True while a download/install is in progress. Prevents double-triggers.
    private(set) var isInstalling = false

    /// The progress window shown during download, or nil when idle.
    private var progressWindow: NSWindow?
    private var progressIndicator: NSProgressIndicator?
    private var statusLabel: NSTextField?

    // MARK: - Public API

    /// Download the zip at `zipURL`, verify its SHA-256 (if `zipHashURL` is
    /// non-nil), extract it, and replace the running app. Shows a progress
    /// window during download. On any failure, shows an alert and returns to
    /// the idle state -- never leaves the app in a broken state.
    ///
    /// S2 -- `zipHashURL` is the URL of the companion `.sha256` sidecar asset
    /// uploaded alongside the zip by the release workflow. When nil (old
    /// releases, private repos), verification is skipped and the update
    /// proceeds using the existing HTTPS + codesign trust chain.
    func install(zipURL: URL, zipHashURL: URL?, releaseName: String) {
        guard !isInstalling else { return }
        isInstalling = true
        showProgressWindow(releaseName: releaseName)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoblinPortalUpdate-\(ProcessInfo.processInfo.globallyUniqueString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            fail("Could not create temporary directory: \(error.localizedDescription)")
            return
        }

        download(zipURL, to: tempDir) { [weak self] zipPath in
            guard let self, let zipPath else {
                self?.cleanup(tempDir)
                return
            }
            self.extractAndInstall(zipPath: zipPath, zipHashURL: zipHashURL, tempDir: tempDir)
        }
    }

    // MARK: - Download

    private func download(_ url: URL, to dir: URL,
                          completion: @escaping @MainActor (URL?) -> Void) {
        let destination = dir.appendingPathComponent("update.zip")
        // Use a dedicated session with a redirect-refusing delegate so the
        // download never silently follows a redirect to a non-allowlisted host.
        // URLSession.shared follows all redirects by default.
        let delegate = DownloadRedirectDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url) {
            [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                // M-1 -- invalidate the download session on every exit path.
                // Without this, the URLSession (and its delegate) are never
                // freed, leaking one session per update attempt. Mirrors the
                // F2 fix applied to hashSession in UpdateInstaller+Install.swift.
                session.finishTasksAndInvalidate()

                guard let self else { return }

                if let error {
                    self.fail("Download failed: \(error.localizedDescription)")
                    completion(nil)
                    return
                }
                guard let tempURL,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    self.fail("Download failed -- server returned an unexpected response.")
                    completion(nil)
                    return
                }

                do {
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                } catch {
                    self.fail("Could not save download: \(error.localizedDescription)")
                    completion(nil)
                    return
                }
                completion(destination)
            }
        }

        // Observe download progress. The KVO callback is always on the main
        // thread because the indicator update is @MainActor.
        task.resume()
        observeProgress(task)
    }

    private func observeProgress(_ task: URLSessionDownloadTask) {
        // Poll every 250ms. URLSessionDownloadTask.progress is thread-safe.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self, weak task] timer in
            guard let self, let task else { timer.invalidate(); return }
            let fraction = task.progress.fractionCompleted
            self.progressIndicator?.doubleValue = fraction * 100
            if fraction >= 1.0 || task.state == .completed || task.state == .canceling {
                self.statusLabel?.stringValue = "Installing…"
                self.progressIndicator?.isIndeterminate = true
                self.progressIndicator?.startAnimation(nil)
                timer.invalidate()
            }
        }
    }

    // MARK: - UI

    private func showProgressWindow(releaseName: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Updating Goblin Portal"
        window.isReleasedWhenClosed = false
        window.center()

        let label = NSTextField(labelWithString: "Downloading \(releaseName)…")
        label.font = .systemFont(ofSize: 13)
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.isIndeterminate = false

        let stack = NSStackView(views: [label, indicator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack

        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
        ])

        window.makeKeyAndOrderFront(nil)
        self.progressWindow = window
        self.progressIndicator = indicator
        self.statusLabel = label
    }

    func dismissProgress() {
        progressWindow?.close()
        progressWindow = nil
        progressIndicator = nil
        statusLabel = nil
    }

    // MARK: - Error handling
    // `internal` so UpdateInstaller+Install.swift can call back into these from
    // MainActor.run blocks inside the detached Task (Item 5). `private` would be
    // file-scoped in Swift and invisible to the extension file.

    func fail(_ message: String) {
        dismissProgress()
        isInstalling = false

        let alert = NSAlert()
        alert.messageText = "Update failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
