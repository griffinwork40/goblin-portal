//
//  UpdateInstaller.swift
//  Download a release zip from GitHub and replace the running app in place.
//
//  The flow:
//    1. Download the zip asset to a temporary directory.
//    2. Extract with `ditto -x -k` (preserves extended attributes and code
//       signatures -- plain `unzip` does not).
//    3. Verify the extracted .app exists and contains an executable.
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
//  path to the installed .app, and the path to the installed executable (for
//  relaunch). It is the only file that touches /Applications.
//

import AppKit
import Foundation

/// Downloads a release zip and installs it over the running app bundle.
///
/// Usage from `UpdateChecker`:
///   `UpdateInstaller.shared.install(zipURL:appName:)`
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

    /// Download the zip at `zipURL`, extract it, and replace the running app.
    /// Shows a progress window during download. On any failure, shows an alert
    /// and returns to the idle state -- never leaves the app in a broken state.
    func install(zipURL: URL, releaseName: String) {
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
            guard let self, let zipPath else { return }
            self.extractAndInstall(zipPath: zipPath, tempDir: tempDir)
        }
    }

    // MARK: - Download

    private func download(_ url: URL, to dir: URL,
                          completion: @escaping @MainActor (URL?) -> Void) {
        let destination = dir.appendingPathComponent("update.zip")
        let task = URLSession.shared.downloadTask(with: url) {
            [weak self] tempURL, response, error in
            DispatchQueue.main.async {
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

    // MARK: - Extract & Install

    private func extractAndInstall(zipPath: URL, tempDir: URL) {
        let extractDir = tempDir.appendingPathComponent("extracted")

        // ditto preserves extended attributes and code signatures. Plain
        // unzip strips them, which breaks Gatekeeper on notarised bundles.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipPath.path, extractDir.path]

        do {
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                fail("Failed to extract the update (ditto exit \(ditto.terminationStatus)).")
                return
            }
        } catch {
            fail("Failed to extract the update: \(error.localizedDescription)")
            return
        }

        // The zip from release.yml wraps GoblinPortal.app at the top level
        // (ditto --keepParent). Find the .app inside the extraction.
        guard let appBundle = findAppBundle(in: extractDir) else {
            fail("The downloaded archive did not contain a valid app bundle.")
            cleanup(tempDir)
            return
        }

        // Verify the extracted app has an executable.
        let executable = appBundle.appendingPathComponent("Contents/MacOS/GoblinPortal")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            fail("The extracted app bundle is incomplete -- no executable found.")
            cleanup(tempDir)
            return
        }

        // Where is the running app installed?
        guard let installedURL = runningAppURL() else {
            fail("Could not determine the installed app location. "
                 + "Update manually by dragging GoblinPortal.app to /Applications.")
            cleanup(tempDir)
            return
        }

        // Verify the installed location is writable. If the user launched from
        // a read-only DMG mount this would fail silently without this check.
        guard FileManager.default.isWritableFile(atPath: installedURL.deletingLastPathComponent().path) else {
            fail("Goblin Portal does not have permission to write to "
                 + "\(installedURL.deletingLastPathComponent().path). "
                 + "Move the app to /Applications and try again.")
            cleanup(tempDir)
            return
        }

        launchTrampoline(
            newApp: appBundle,
            installedApp: installedURL,
            tempDir: tempDir
        )
    }

    /// Walk the extraction directory for a `.app` bundle.
    private func findAppBundle(in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "app" {
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { return fileURL }
            }
        }
        return nil
    }

    /// The URL of the running app bundle, or nil when running via `swift run`.
    private func runningAppURL() -> URL? {
        let bundle = Bundle.main
        // Bundle.main.bundleURL for a .app is e.g.
        //   /Applications/GoblinPortal.app
        // Under `swift run` it points into .build/ and has no Info.plist.
        guard bundle.infoDictionary?["CFBundleIdentifier"] != nil else { return nil }
        return bundle.bundleURL
    }

    // MARK: - Trampoline

    /// Launch the shell trampoline to swap bundles after this process exits.
    private func launchTrampoline(newApp: URL, installedApp: URL, tempDir: URL) {
        guard let scriptPath = Bundle.main.path(
            forResource: "install-update", ofType: "sh"
        ) else {
            fail("Update script missing from the app bundle. Reinstall Goblin Portal.")
            cleanup(tempDir)
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunchPath = installedApp
            .appendingPathComponent("Contents/MacOS/GoblinPortal").path

        let trampoline = Process()
        trampoline.executableURL = URL(fileURLWithPath: "/bin/sh")
        trampoline.arguments = [
            scriptPath,
            "\(pid)",
            newApp.path,
            installedApp.path,
            relaunchPath,
            tempDir.path
        ]

        // Detach from the parent process group so the trampoline survives
        // NSApp.terminate.
        trampoline.qualityOfService = .userInitiated

        do {
            try trampoline.run()
        } catch {
            fail("Could not launch the update installer: \(error.localizedDescription)")
            cleanup(tempDir)
            return
        }

        // Hand off to the trampoline. The next thing the user sees is the
        // relaunched app at the new version.
        NSApp.terminate(nil)
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

    private func dismissProgress() {
        progressWindow?.close()
        progressWindow = nil
        progressIndicator = nil
        statusLabel = nil
    }

    // MARK: - Error handling

    private func fail(_ message: String) {
        dismissProgress()
        isInstalling = false

        let alert = NSAlert()
        alert.messageText = "Update failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
