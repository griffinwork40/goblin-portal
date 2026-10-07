//
//  SpaceWindowController+InitialFrame.swift
//  The frame a Space window opens at when it has no saved frame of its own.
//
//  Its own file because it is one whole concern (first-launch geometry) and
//  `SpaceWindowController.swift` sits within a dozen lines of the 350-LOC ceiling.
//
//  WHY THIS EXISTS — measured, not theorised (`check-first-window.sh`, 2026-10-07).
//  On a clean defaults domain the window went through these frames in `init`:
//
//      NSWindow(contentRect: 1100x680)          → (0, 0, 1100, 712)
//      window.contentViewController = space     → (0, 180, 500, 532)
//      window.setFrameAutosaveName(...)          → (244, 180, 500, 532), and WRITTEN
//
//  AppKit sizes a window to its content view controller's view when that property is
//  assigned, and an `NSSplitViewController` whose `loadView` never set a frame has a
//  500x500 view. So the 1100x680 rect handed to `NSWindow` never survived to the
//  screen: every first launch opened a 500x532 window with a 220pt sidebar and a 28x28
//  shell. Worse, `setFrameAutosaveName` saved that frame under the per-root key
//  immediately, so a stale-frame restore (the other hypothesis on record) was the
//  bug's *echo* on later launches, not its cause — no key existed on the first one.
//
//  The fix restores the intended size AFTER the assignment and BEFORE the autosave
//  name, so a frame the user actually saved still wins: `setFrameAutosaveName` reads
//  any saved frame for that name and applies it over this default (measured by the
//  gate's control case).
//

import AppKit

extension SpaceWindowController {
    /// The frame a fresh Space window should have: `contentSize` plus the titlebar,
    /// clamped to `visibleFrame` (a 1100x712 window does not fit a 1024x600 display,
    /// and a window taller than the visible area hides its own titlebar under the
    /// menu bar), then centred exactly in it.
    ///
    /// Exactly centred rather than `NSWindow.center()`, which places a window
    /// "somewhat above center vertically" by documented design — fine for an alert,
    /// but the spec here is a centred first window and that is checkable as numbers.
    ///
    /// Pure and static, so the gate can ask it about a small screen it does not have.
    static func defaultFrame(
        contentSize: NSSize, styleMask: NSWindow.StyleMask, in visibleFrame: NSRect
    ) -> NSRect {
        let full = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize), styleMask: styleMask)
        let width = min(full.width, visibleFrame.width)
        let height = min(full.height, visibleFrame.height)
        // Rounded so the window lands on whole points; a half-point origin blurs nothing
        // in AppKit but makes the saved frame string and the gate's arithmetic noisier.
        return NSRect(
            x: (visibleFrame.midX - width / 2).rounded(.down),
            y: (visibleFrame.midY - height / 2).rounded(.down),
            width: width, height: height)
    }

    /// Undo the content-view-controller resize described in the file header. Must be
    /// called after `contentViewController` is assigned and before
    /// `setFrameAutosaveName`, or one of the two will overwrite it.
    static func applyDefaultFrame(to window: NSWindow, contentSize: NSSize) {
        // `NSScreen.main` first: it is the screen holding the key window, which is where a
        // user expects a new window to appear. `window.screen` is only derived from the
        // not-yet-placed frame at the origin — the primary display, which on a two-monitor
        // desk may be the one they are not looking at — so it is just the fallback.
        guard let screen = NSScreen.main ?? window.screen else { return }
        let frame = defaultFrame(
            contentSize: contentSize, styleMask: window.styleMask, in: screen.visibleFrame)
        window.setFrame(frame, display: false)
    }

    /// Content size `NSSplitViewController` gives a window it was never told to size: the
    /// exact signature of the bug in the file header (500x532 frame, 500x500 content).
    static let poisonedContentSize = NSSize(width: 500, height: 500)

    /// Repair a frame the bug SAVED. Every user who launched before the fix has a 500x532
    /// frame stored under their per-root key, and `setFrameAutosaveName` restores it over
    /// the fixed default, so without this they stay stuck forever. Matches the exact
    /// content size only, never "too small": a user who deliberately drags a window to
    /// some small size keeps it; one who lands on exactly 500x500 content gets the default
    /// once, a cost judged far below leaving every early installer at 28 columns.
    /// Call AFTER `setFrameAutosaveName`; re-saves so the repair sticks.
    static func repairPoisonedSavedFrame(of window: NSWindow, contentSize: NSSize) {
        let content = window.contentRect(forFrameRect: window.frame).size
        guard abs(content.width - poisonedContentSize.width) < 0.5,
              abs(content.height - poisonedContentSize.height) < 0.5 else { return }
        applyDefaultFrame(to: window, contentSize: contentSize)
        let name = window.frameAutosaveName
        if !name.isEmpty { window.saveFrame(usingName: name) }
    }
}
