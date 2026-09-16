//
//  AppearanceObserver.swift
//  Watches NSApp.effectiveAppearance and fans a theme switch out to every open
//  Space when the user has configured `"preset": "auto"`.
//
//  The existing pinned-theme path is COMPLETELY UNCHANGED. When `AppConfig.autoTheme`
//  is nil — which it always is for any non-"auto" preset — this observer exists but
//  never acts. The appearance pin at `SpaceWindowController.init` (line 166) remains
//  authoritative for pinned themes; `AppearanceObserver` only fires when auto mode
//  deliberately opts out of that pin.
//
//  KVO vs. NSWorkspace.shared.publisher: KVO on NSApp.effectiveAppearance is the
//  canonical Cocoa mechanism here. `NSWorkspace.effectiveAppearance` follows the
//  *global* System Settings switch, which fires earlier than NSApp's (whose value
//  AppKit derives after processing the window-server notification); using NSApp's
//  value means we never act on a stale reading when building the initial theme in
//  `AppConfig.load()` or in the observer callback itself.
//
//  Lifecycle: `AppDelegate` holds the single instance. It is created after the first
//  config load and torn down with the app. No timer, no polling — the callback fires
//  exactly once per appearance change, on the main actor.
//
//  Why a class with @objc rather than a Combine pipeline: NSApp's effectiveAppearance
//  is an NSObject property that cannot be subscribed to with Swift Concurrency without
//  bridging through KVO anyway. The KVO bridge is the irreducible bottom here. The
//  class is `final` and `@MainActor`, matching every other type in this project.
//

import AppKit

@MainActor
final class AppearanceObserver: NSObject {
    // MARK: - Static helper (used at load time too)

    /// True when NSApp's current effective appearance is one of the dark variants.
    ///
    /// Called from `AppConfig.load()` to pick the initial theme WITHOUT waiting for
    /// the first KVO callback, so the very first window always opens in the right
    /// palette. Reading from NSApp is correct at load time: applicationDidFinishLaunching
    /// fires after AppKit has already resolved the initial appearance.
    ///
    /// Using `bestMatch(from:)` rather than a name string comparison because AppKit
    /// can return variants like `.accessibilityHighContrastDarkAqua` that contain
    /// "dark" but are not the literal `.darkAqua`. The four listed names are the
    /// exhaustive set of dark-family appearances documented in NSAppearance.Name.
    ///
    /// `@MainActor` because `NSApp.effectiveAppearance` is MainActor-isolated (NSApp
    /// is `NS_SWIFT_UI_ACTOR` per AppKit headers). All call sites — `AppConfig.load()`
    /// from `AppDelegate` and `applyThemeSwitch()` — are already on the main actor, so
    /// this attribute adds no new constraint in practice.
    @MainActor static var currentIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantDark]) != nil
    }

    // MARK: - Instance

    private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        // KVO on NSApp.effectiveAppearance. The handler closure captures `self` weakly
        // to avoid a retain cycle (NSKeyValueObservation already holds a strong reference
        // to its key path context, so a strong capture here would create a cycle even
        // though the class itself holds the observation token).
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // The KVO callback arrives on whatever thread AppKit chooses. We need to be
            // on the main actor because `applyThemeSwitch` touches AppKit views.
            // `MainActor.assumeIsolated` is safe here because NSApp KVO notifications
            // are ALWAYS delivered on the main thread (AppKit's documented guarantee —
            // NSApp itself is not thread-safe and its KVO is no exception). We do not
            // use DispatchQueue.main.async so the switch is applied synchronously in
            // the same run-loop iteration that delivered the appearance change, which
            // prevents one frame of the wrong palette flashing on screen.
            MainActor.assumeIsolated {
                self?.applyThemeSwitch()
            }
        }
    }

    deinit {
        // NSKeyValueObservation.invalidate() is called automatically in deinit, but
        // the explicit call makes the intent clear and is harmless to double-call.
        observation?.invalidate()
        observation = nil
    }

    // MARK: - Fan-out

    /// Picks the correct palette from each open Space's `autoTheme` and fans out
    /// `apply(config:)` + window chrome updates, matching exactly what `reloadConfig`
    /// does for a manual ⌘R reload (`AppDelegate.reloadConfig`).
    ///
    /// Called only when the observation fires, so it never runs for pinned themes even
    /// if a Space is open with a pinned theme while another uses auto mode — every Space
    /// checks its own `config.autoTheme` and ignores the signal when it is nil.
    ///
    /// Why per-controller rather than reading `AppDelegate.config`: each open Space
    /// carries its own resolved `AppConfig` (via `SpaceViewController.config`), which is
    /// the config snapshot that was live when the space was opened or last ⌘R'd. Mutating
    /// the delegate's `config` here would silently shadow any per-Space state; updating
    /// each controller's space directly mirrors what `reloadConfig` has always done.
    private func applyThemeSwitch() {
        let isDark = Self.currentIsDark
        for controller in SpaceWindowController.open {
            guard let auto = controller.space.config.autoTheme else { continue }
            let newTheme = isDark ? auto.dark : auto.light
            // Build a new config snapshot with the switched theme. `AppConfig` is a
            // struct, so this is a value copy — no aliasing risk. We update `.theme`
            // directly rather than calling `AppConfig.load()` again, which would be a
            // full disk read and would discard any live state (zoom, etc.).
            var updated = controller.space.config
            updated.theme = newTheme
            // Propagate the new appearance so the sidebar and chrome switch too.
            // The chrome appearance is derived from the theme's background luminance
            // (`Config+Chrome.swift:appearance`), so it updates automatically when
            // `theme` changes — no separate pin needed.
            controller.space.apply(config: updated)
            controller.window?.backgroundColor = updated.effectiveBackground
            controller.window?.appearance = updated.appearance
        }
    }
}
