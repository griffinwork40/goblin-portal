//
//  LiquidGlass.swift
//  macOS 26+ Liquid Glass adoption — the single place all glass-specific code lives.
//
//  Goblin Portal gets Liquid Glass *automatically* when linked against the macOS 26 SDK
//  (determined by the `sdk` field in the Mach-O LC_BUILD_VERSION load command,
//  set via -platform_version in make-app-bundle.sh — NOT from Info.plist):
//  the sidebar (via NSSplitViewItem) becomes a floating glass pane, window corners
//  round, controls gain glass bezels, and the menu bar goes transparent — all with
//  zero code changes beyond the plist keys.
//
//  This file handles the enhancements that require explicit API calls:
//
//  1. Window chrome adjustments (titlebar separator) so the glass reads cleanly.
//  2. NSGlassEffectView for floating panels (Command Palette, Symbol Outline),
//     replacing the older NSVisualEffectView(.hudWindow) material that predates
//     the glass system.
//
//  Everything here is guarded by @available(macOS 26, *). On macOS 14/15, these
//  helpers are never called, and the app renders exactly as it did before.
//
//  fullSizeContentView is deliberately NOT enabled here. It was tried (2026-08-20,
//  this file's first version) and caused the terminal's top rows to be clipped
//  behind the glass titlebar — the exact same bug documented at
//  SpaceWindowController.swift:132-141. The root cause: NSSplitViewController does
//  not propagate safeAreaInsets.top to a child view controller that uses manual
//  frame layout (DocumentAreaViewController.viewDidLayout), so the document area
//  extends behind the titlebar with no offset. Glass does NOT require
//  fullSizeContentView — the sidebar gets its floating glass pane automatically
//  via NSSplitViewItem, and the titlebar gets glass from the SDK linkage alone.
//
//  The terminal content area and the editor content area are NEVER touched by
//  glass — the ANSI colour contract, the 345-assertion contrast gate
//  (check-theme-contrast.sh), and SwiftTerm's opaque layer all require a known,
//  opaque background. Apple's own Terminal.app made the same call: glass chrome,
//  opaque content (MacForce review, September 2025).
//

import AppKit

/// macOS 26+ Liquid Glass helpers.
///
/// Called from two sites: `SpaceWindowController.init` (window chrome) and
/// `CommandPalette.buildPanel` (floating panel). `SymbolOutlinePanel` gets glass
/// automatically via its titled window chrome — no explicit glass view needed.
/// Keeping them here rather than inlining the `#available` blocks means a single
/// file to update when the glass API evolves — and a single file to read when
/// asking "what does Goblin Portal do differently on Tahoe?"

/// Drawing-style tokens that vary between macOS 26+ (Liquid Glass) and earlier.
///
/// Each drawing site initialises its own instance via `.resolved()` at declaration
/// time — `DocumentTabStrip.drawingStyle` and `FileTreeViewController.viewDidLoad`
/// are the two current call sites. Both resolve once (not per-frame) and read the
/// same two constants, so in practice they always agree; the factory is cheap enough
/// that a single shared instance is unnecessary.
///
/// This lives here — not beside the drawing code — because `LiquidGlass.swift` is
/// the stated single answer to "what does Goblin Portal do differently on Tahoe?"
/// Scattering version-conditional numbers across `+Drawing.swift` and
/// `FileTreeViewController.swift` would break that promise the first time a second
/// glass tweak lands.
@MainActor
struct GlassDrawingStyle {
    /// Corner radius for pill-shaped tab fills (active and hover). 8pt on macOS 26
    /// produces a proportional pill on the 30pt strip; 4pt on earlier systems adds
    /// gentle rounding without the full Tahoe pill shape (the visual design roadmap's
    /// original suggestion). 0pt would restore sharp rectangles.
    let tabCornerRadius: CGFloat

    /// Top inset on the sidebar's NSStackView. 4pt on macOS 26 gives breathing room
    /// under the glass titlebar; 2pt on earlier systems is the original tight spacing
    /// that worked well with the opaque titlebar strip.
    let sidebarTopInset: CGFloat

    /// macOS 26+: Liquid Glass era. Pill tabs, roomier sidebar.
    static let liquidGlass = GlassDrawingStyle(tabCornerRadius: 8, sidebarTopInset: 4)

    /// Pre-macOS 26: gentle rounding, tight sidebar. The 4pt tab radius was the
    /// visual design roadmap's proposal before the Tahoe pill research raised it.
    static let classic = GlassDrawingStyle(tabCornerRadius: 4, sidebarTopInset: 2)

    /// Resolve the style for the running OS. Called once per window.
    static func resolved() -> GlassDrawingStyle {
        if #available(macOS 26, *) { return .liquidGlass }
        return .classic
    }
}

@available(macOS 26.0, *)
@MainActor
enum LiquidGlass {

    /// Adjust window chrome for Liquid Glass.
    ///
    /// The separator between the titlebar and the content area is a hard line
    /// that contradicts the glass material sitting above it. Removing it lets the
    /// glass boundary define the edge instead.
    ///
    /// `window.backgroundColor` and `window.appearance` (set by the caller) are
    /// still honoured: the glass material samples the window background for
    /// tinting, so a dark-themed terminal gets a dark glass titlebar and a
    /// light-themed one gets light glass — matching the sidebar's own adaptive
    /// tint with no additional code.
    static func configureWindow(_ window: NSWindow) {
        window.titlebarSeparatorStyle = .none
    }

    /// Create a glass container for a floating panel (Command Palette,
    /// Symbol Outline).
    ///
    /// Replaces the `NSVisualEffectView(.hudWindow)` pattern used on pre-26
    /// systems. The glass material adapts to the content behind the panel and
    /// follows the system appearance, so it looks native in both light and dark
    /// mode without manual colour management.
    ///
    /// Callers add subviews to this view the same way they did to the old
    /// NSVisualEffectView — NSGlassEffectView is an NSView subclass and its
    /// `addSubview` works identically.
    static func makeGlassContainer(
        frame: NSRect,
        cornerRadius: CGFloat = 10
    ) -> NSView {
        let glass = NSGlassEffectView()
        glass.frame = frame
        glass.wantsLayer = true
        glass.layer?.cornerRadius = cornerRadius
        glass.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        return glass
    }
}
