//
//  ConfigWarningPresenter.swift
//  Puts config-load warnings in front of GUI users (#166, T1.5): one call per load
//  (launch, ⌘R, Settings Apply), fanned out to every Space window as a
//  `ConfigWarningBanner`.
//
//  Its own type and file rather than more lines in `AppDelegate.swift`: the delegate
//  sits at the 350-LOC ceiling (AFK.md Conventions), and "which windows carry the
//  banner, and when it goes away" is one whole concern with state of its own (the
//  current banner, whether the user dismissed it). The delegate's two load sites —
//  `applicationDidFinishLaunching` and `reloadConfig(_:)`, which Settings Apply also
//  calls (`PreferencesWindow.saveValues()`) — each make exactly one `report(_:)` call.
//
//  stderr is KEPT, not replaced: a `swift run` or Terminal-launched session still
//  gets the `config: …` lines it always had, so the banner adds a channel rather
//  than moving one.
//

import AppKit

@MainActor
final class ConfigWarningPresenter {
    /// Process-lifetime singleton: banners hold it weakly for their Dismiss button,
    /// and the window-became-key observer below must outlive every window.
    static let shared = ConfigWarningPresenter()

    /// What every Space window should show right now; nil when the last load was
    /// clean or the user dismissed it.
    private var current: ConfigWarningPolicy.Banner?
    private var observer: NSObjectProtocol?

    private init() {
        // Windows opened AFTER a load (⌘N, ⌘O, a restored tab selected later) never
        // saw `report(_:)`. Syncing on became-key covers all of them with one rule.
        // It does NOT cover the launch windows on its own — a process that is never
        // activated (launched from a shell, or behind another app) never makes a
        // window key — so the delegate reports AFTER `restoreSpaces()`, and
        // `report(_:)` syncs every window that already exists.
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            // `queue: .main` delivers on the main thread; the closure type is still
            // nonisolated under Swift 6, hence the assertion rather than a hop.
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window else { return }
                ConfigWarningPresenter.shared.sync(window)
            }
        }
    }

    /// Call once per `AppConfig.load()`. Writes the stderr lines, then shows,
    /// replaces or hides the banner in every Space window.
    ///
    /// A previous dismissal does not survive this call: each load is the user asking
    /// again (⌘R, Apply, relaunch), so a still-broken file shows again and a fixed
    /// one clears. `ConfigWarningPolicy.action(for:home:)` documents that contract.
    func report(_ warnings: [String]) {
        for warning in warnings {
            FileHandle.standardError.write(Data("config: \(warning)\n".utf8))
        }
        switch ConfigWarningPolicy.action(for: warnings, home: NSHomeDirectory()) {
        case .show(let banner): current = banner
        case .hide: current = nil
        }
        diag(current.map { "show (\($0.lines.count) line(s), +\($0.overflow) more): \($0.title)" } ?? "hide")
        syncAll()
    }

    /// The banner's ✕. Hides it everywhere until the next load.
    func dismiss() {
        current = nil
        diag("dismissed")
        syncAll()
    }

    private func syncAll() {
        for controller in SpaceWindowController.open {
            if let window = controller.window { sync(window) }
        }
    }

    /// Make one window's banner match `current`. Space windows only — the Settings
    /// panel and the command palette also become key, and a strip there would be
    /// noise on a panel with its own layout.
    private func sync(_ window: NSWindow) {
        guard SpaceWindowController.open.contains(where: { $0.window === window }) else { return }
        let accessories = window.titlebarAccessoryViewControllers
        let installed = accessories.lastIndex { $0 is ConfigWarningBanner }
        // Identical warnings on a repeat ⌘R: leave the installed banner alone rather
        // than tearing it down, which would flicker the content area's height.
        if let index = installed, (accessories[index] as? ConfigWarningBanner)?.content == current {
            return
        }
        if let index = installed { window.removeTitlebarAccessoryViewController(at: index) }
        guard let banner = current else { return }
        window.addTitlebarAccessoryViewController(ConfigWarningBanner(banner: banner, presenter: self))
    }

    /// `GOBLIN_PORTAL_DIAG=1` line per decision — the only observable record of the
    /// banner for a session with no window server to look at, and how a live test
    /// with a deliberately bad config confirms the presenter fired.
    private func diag(_ message: String) {
        guard ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil else { return }
        FileHandle.standardError.write(Data("[diag] config-banner: \(message)\n".utf8))
    }
}
