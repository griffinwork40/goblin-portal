//
//  SpaceWindowController+Titlebar.swift
//  Applies the `titlebar` config style ("standard" | "compact") to a Space window — at
//  creation, on live reload (⌘R / Settings Apply → `AppDelegate.reloadConfig`), and again
//  when the window leaves full screen.
//
//  Its own file because `SpaceWindowController.swift` sits a dozen lines under the 350-LOC
//  ceiling and window chrome is one whole concern. The parse and the inset rule are pure and
//  live in `TitlebarStyle.swift`; the consumer of the style is
//  `DocumentAreaViewController+SafeArea.swift`, which reads `allowsContentInTitleRow` below.
//
//  WHY these three properties together (measured on macOS 27, scope §1b): `.fullSizeContentView`
//  alone, or with an opaque/visible title, leaves `NSTitlebarView` winning hit-testing over the
//  band, so nothing usable is reclaimed. Transparent + `.hidden` title is what hands the band
//  to content. The window keeps its title for Mission Control, the Window menu, VoiceOver, and
//  the native Space tab bar (which still shows titles with 2+ Spaces).
//

import AppKit

extension SpaceWindowController {
    /// Set the three titlebar properties for `style`. Static so `init` can call it before
    /// `super.init`. The window's FRAME is kept: toggling `.fullSizeContentView` changes how
    /// the frame is split between titlebar and content, never the frame — but a live window
    /// is pinned back to its frame anyway, because a moved saved frame is the failure the
    /// reload case (C10 in `check-titlebar-layout.sh`) exists to catch.
    static func applyTitlebarStyle(_ style: TitlebarStyle, to window: NSWindow) {
        // In full screen AppKit owns the titlebar; changing the mask there fights the
        // transition. `windowDidExitFullScreen` re-applies the configured style instead.
        guard !window.styleMask.contains(.fullScreen) else { return }
        let compact = style == .compact
        let frame = window.frame
        if compact { window.styleMask.insert(.fullSizeContentView) }
        else { window.styleMask.remove(.fullSizeContentView) }
        window.titlebarAppearsTransparent = compact
        window.titleVisibility = compact ? .hidden : .visible
        if window.frame != frame { window.setFrame(frame, display: false) }
    }

    /// Re-apply the style from the Space's current config (reload, full-screen exit), then
    /// re-lay out the document area: its inset depends on the style but its bounds may not
    /// change, so nothing else would trigger the pass.
    func applyTitlebarStyle() {
        guard let window else { return }
        Self.applyTitlebarStyle(space.config.titlebar, to: window)
        space.documentArea.view.needsLayout = true
    }

    /// Ghostty re-applies its titlebar style on full-screen exit because "macOS breaks it
    /// usually"; so do we, and it also covers a ⌘R that happened while in full screen.
    /// `NSWindowDelegate` conformance is declared in `SpaceWindowController.swift:22`.
    func windowDidExitFullScreen(_ notification: Notification) {
        applyTitlebarStyle()
    }
}

extension NSWindow {
    /// True when content may be drawn in the title row: the compact style is active (content
    /// extends under a transparent, title-less titlebar). The harness-forced
    /// `.fullSizeContentView` of PR1's gate leaves this false, so the plain safe-area inset
    /// (row 0 below the title row) still applies there.
    var allowsContentInTitleRow: Bool {
        styleMask.contains(.fullSizeContentView) && titlebarAppearsTransparent
            && titleVisibility == .hidden
    }

    /// Height of the bare title row, independent of `.fullSizeContentView`.
    var titleRowHeight: CGFloat {
        let probe = NSRect(x: 0, y: 0, width: 100, height: 100)
        let mask = styleMask.subtracting(.fullSizeContentView)
        return NSWindow.frameRect(forContentRect: probe, styleMask: mask).height - probe.height
    }

    /// Rightmost window-x of anything AppKit draws at the left of the title row: visible
    /// traffic lights plus `.left`/`.leading` titlebar accessories (`SidebarToggleAccessory`).
    var titleRowControlsMaxX: CGFloat {
        var maxX: CGFloat = 0
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            if let b = standardWindowButton(type), !b.isHidden, b.window === self {
                maxX = max(maxX, b.convert(b.bounds, to: nil).maxX)
            }
        }
        for acc in titlebarAccessoryViewControllers
        where (acc.layoutAttribute == .left || acc.layoutAttribute == .leading)
            && !acc.isHidden && acc.view.window === self {
            maxX = max(maxX, acc.view.convert(acc.view.bounds, to: nil).maxX)
        }
        return maxX
    }
}
