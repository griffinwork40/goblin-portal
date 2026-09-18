//
//  UpdateInstaller+Install.swift
//  Extraction, bundle verification, and trampoline launch for in-place updates.
//
//  Split from UpdateInstaller.swift by Item 5 of PR #104: that file reached 343
//  LOC; wrapping extractAndInstall in Task.detached (to move ditto off the main
//  thread) would have pushed it past the 350-LOC ceiling enforced by
//  check-file-size.sh. The seam is clean: this file owns everything that happens
//  AFTER the zip lands on disk (extract → verify → swap); UpdateInstaller.swift
//  owns everything BEFORE (download, progress UI, error helpers).
//
//  Threading contract (Item 5):
//    • extractAndInstall is called on @MainActor but immediately hands off to
//      Task.detached(priority: .userInitiated). The detached task runs the
//      blocking ditto + FileManager work on a cooperative thread pool thread,
//      never blocking the main thread.
//    • fail() and cleanup() are @MainActor methods (defined in UpdateInstaller.swift)
//      and are called via `await MainActor.run { }` from inside the detached task.
//    • launchTrampoline calls NSApp.terminate, which must run on the main thread.
//      It is also called via `await MainActor.run { }`.
//

import AppKit
import Foundation

@MainActor
extension UpdateInstaller {

    // MARK: - Extract & Install

    /// Entry point called by the download completion handler (on @MainActor).
    /// Immediately moves blocking work off the main thread via Task.detached.
    func extractAndInstall(zipPath: URL, tempDir: URL) {
        // Item 5 -- ditto and FileManager calls in this function are blocking.
        // Wrapping in Task.detached(priority: .userInitiated) moves them to a
        // cooperative thread pool thread so the main run loop stays responsive
        // during extraction (which can take 1-3 seconds for a ~50 MB bundle).
        // NSApp.terminate, fail(), and cleanup() hop back to MainActor via
        // await MainActor.run { } before touching any AppKit state.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let extractDir = tempDir.appendingPathComponent("extracted")

            // ditto preserves extended attributes and code signatures. Plain
            // unzip strips them, which breaks Gatekeeper on notarised bundles.
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zipPath.path, extractDir.path]

            do {
                try ditto.run()
                ditto.waitUntilExit()  // blocking -- intentionally off main thread
                guard ditto.terminationStatus == 0 else {
                    let status = ditto.terminationStatus
                    await MainActor.run {
                        self.fail("Failed to extract the update (ditto exit \(status)).")
                        self.cleanup(tempDir)
                    }
                    return
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self.fail("Failed to extract the update: \(msg)")
                    self.cleanup(tempDir)
                }
                return
            }

            // The zip from release.yml wraps GoblinPortal.app at the top level
            // (ditto --keepParent). Find the .app inside the extraction.
            guard let appBundle = Self.findAppBundle(in: extractDir) else {
                await MainActor.run {
                    self.fail("The downloaded archive did not contain a valid app bundle.")
                    self.cleanup(tempDir)
                }
                return
            }

            // Verify that the extracted bundle has the expected bundle identifier
            // before touching the installed copy. findAppBundle matches by extension
            // alone, so a malformed archive could slip through without this check.
            let infoPlistURL = appBundle.appendingPathComponent("Contents/Info.plist")
            if let plist = NSDictionary(contentsOf: infoPlistURL),
               let bundleID = plist["CFBundleIdentifier"] as? String {
                guard bundleID == "com.griffinlong.goblin-portal" else {
                    let id = bundleID
                    await MainActor.run {
                        self.fail("The downloaded archive contains an unexpected app (\(id)).")
                        self.cleanup(tempDir)
                    }
                    return
                }
            } else {
                await MainActor.run {
                    self.fail("The downloaded archive is missing a valid Info.plist.")
                    self.cleanup(tempDir)
                }
                return
            }

            // Verify the extracted app has an executable.
            let executable = appBundle.appendingPathComponent("Contents/MacOS/GoblinPortal")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                await MainActor.run {
                    self.fail("The extracted app bundle is incomplete -- no executable found.")
                    self.cleanup(tempDir)
                }
                return
            }

            // Where is the running app installed?
            guard let installedURL = Self.runningAppURL() else {
                await MainActor.run {
                    self.fail("Could not determine the installed app location. "
                              + "Update manually by dragging GoblinPortal.app to /Applications.")
                    self.cleanup(tempDir)
                }
                return
            }

            // Verify the installed location is writable. If the user launched
            // from a read-only DMG mount this would fail silently without this.
            guard FileManager.default.isWritableFile(
                atPath: installedURL.deletingLastPathComponent().path
            ) else {
                let parentPath = installedURL.deletingLastPathComponent().path
                await MainActor.run {
                    self.fail("Goblin Portal does not have permission to write to "
                              + "\(parentPath). "
                              + "Move the app to /Applications and try again.")
                    self.cleanup(tempDir)
                }
                return
            }

            // All checks passed. Hand off to the trampoline on the main thread
            // (NSApp.terminate must be called from @MainActor).
            await MainActor.run {
                self.launchTrampoline(
                    newApp: appBundle,
                    installedApp: installedURL,
                    tempDir: tempDir
                )
            }
        }
    }

    // MARK: - Bundle helpers (nonisolated: called from the detached Task)

    /// Walk the extraction directory for a `.app` bundle.
    nonisolated private static func findAppBundle(in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        // resolvingSymlinksInPath (realpath(3)) resolves symlinks, unlike
        // standardizedFileURL which only removes . and .. components. Without
        // this, a crafted zip containing a directory symlink
        // (e.g. Evil.app -> /Applications/X.app) passes the prefix check
        // because the symlink's own path is inside extractDir while the
        // resolved target is not.
        let dirPrefix = dir.resolvingSymlinksInPath().path + "/"
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "app" {
                let vals = try? fileURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                let isDir = vals?.isDirectory ?? false
                let isSymlink = vals?.isSymbolicLink ?? false
                // Containment guard: reject symlinks unconditionally (a
                // symlink to a directory inside the tree is not a bundle) and
                // reject paths whose resolved location escapes the extraction
                // directory.
                guard isDir, !isSymlink,
                      fileURL.resolvingSymlinksInPath().path.hasPrefix(dirPrefix)
                else { continue }
                return fileURL
            }
        }
        return nil
    }

    /// The URL of the running app bundle, or nil when running via `swift run`.
    nonisolated private static func runningAppURL() -> URL? {
        let bundle = Bundle.main
        // Bundle.main.bundleURL for a .app is e.g.
        //   /Applications/GoblinPortal.app
        // Under `swift run` it points into .build/ and has no Info.plist.
        guard bundle.infoDictionary?["CFBundleIdentifier"] != nil else { return nil }
        return bundle.bundleURL
    }

    // MARK: - Trampoline

    /// Launch the shell trampoline to swap bundles after this process exits.
    /// Must be called on @MainActor (NSApp.terminate is AppKit).
    private func launchTrampoline(newApp: URL, installedApp: URL, tempDir: URL) {
        guard let scriptPath = Bundle.main.path(
            forResource: "install-update", ofType: "sh"
        ) else {
            fail("Update script missing from the app bundle. Reinstall Goblin Portal.")
            cleanup(tempDir)
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier

        let trampoline = Process()
        trampoline.executableURL = URL(fileURLWithPath: "/bin/sh")
        trampoline.arguments = [
            scriptPath,
            "\(pid)",
            newApp.path,
            installedApp.path,
            tempDir.path
        ]

        // NSApp.terminate calls exit() on the parent process. POSIX does not
        // deliver a signal to child processes on parent exit -- they are
        // re-parented to launchd and keep running. The trampoline's open file
        // descriptors also keep it alive until it finishes the swap.
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
}
