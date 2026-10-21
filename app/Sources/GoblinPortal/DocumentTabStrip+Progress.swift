// DocumentTabStrip+Progress.swift
// Draws the OSC 9;4 progress bar inside each tab pill.
//
// Design (see ProgressReportPolicy.swift header for rationale)
// ------------------------------------------------------------
// A 2pt bar along the bottom of each tab pill, drawn AFTER the accent line so it
// sits on top.  For the ACTIVE tab the bar shares the 2pt accent-line strip at the
// bottom of the pill — the accent line is the full-width background; the progress
// bar is drawn proportionally on top of it.  For INACTIVE tabs the bar is drawn at
// 0.7 alpha in the same 2pt zone so it reads against the dimmed rail without
// competing with the status dot.
//
// State → colour mapping (palette-independent system colours):
//   .none          → not drawn
//   .determinate   → systemGreen, proportional width
//   .indeterminate → systemBlue, full width (the caller animates if desired;
//                    we draw static — a static full-width blue bar reads as
//                    "in progress, unknown amount" without animation cost)
//   .error         → systemRed, full width
//   .paused        → systemYellow, proportional width
//
// These system colours adapt to Increase Contrast and to the window's effective
// appearance, matching the reasoning in DocumentStatus+Presentation.swift.
//
// Legibility across palettes (classic-repaired, umber, afk-light)
// ---------------------------------------------------------------
// The 2pt bar sits in the bottom strip of the pill, below the title text and
// symbol icon.  It does not share space with the status dot (right side of the
// pill) or the close glyph.  On the 56pt minTabWidth the bar is still a full
// 56pt wide track with a proportional fill — the narrower the tab, the more
// dramatic the progress fraction looks, which is fine.  The bar is clipped to
// the pill's rounded path so it follows the corners exactly.
//
// VoiceOver
// ---------
// Progress state is appended to the tab's AX label in tabElement(_:_:) in
// DocumentTabStrip+Accessibility.swift.  This file provides the helper string.
//
import AppKit

extension DocumentTabStrip {

    // MARK: - Tab progress drawing (called from drawTab in +Drawing.swift)

    /// Draw the 2pt progress bar at the bottom of `rect` for `progress`.
    /// Must be called AFTER the accent line is drawn so the bar renders on top.
    /// `isActive` controls opacity — full on the active pill, 0.7 on inactive.
    func drawProgressBar(in rect: NSRect, progress: ProgressAggregation, isActive: Bool) {
        guard progress != .hidden else { return }

        let barHeight: CGFloat = 2
        let barY = rect.minY   // bottom of the pill
        let trackRect = NSRect(x: rect.minX, y: barY, width: rect.width, height: barHeight)

        let alpha: CGFloat = isActive ? 1.0 : 0.7

        // Clip to the pill so the bar follows the rounded corners.
        // `tabCornerRadius` is private to +Drawing.swift; read from drawingStyle
        // directly (the same backing value, same reasoning as the Drawing file's
        // own `tabCornerRadius` computed property).
        let cr = drawingStyle.tabCornerRadius
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: cr, yRadius: cr).addClip()

        switch progress {
        case .hidden:
            break

        case .determinate(let pct):
            let fraction = CGFloat(pct) / 100
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY,
                                  width: trackRect.width * fraction, height: barHeight)
            NSColor.systemGreen.withAlphaComponent(alpha).setFill()
            fillRect.fill()

        case .indeterminate:
            NSColor.systemBlue.withAlphaComponent(alpha).setFill()
            trackRect.fill()

        case .error:
            NSColor.systemRed.withAlphaComponent(alpha).setFill()
            trackRect.fill()

        case .paused(let pct):
            let fraction = CGFloat(pct) / 100
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY,
                                  width: trackRect.width * fraction, height: barHeight)
            NSColor.systemYellow.withAlphaComponent(alpha).setFill()
            fillRect.fill()
        }

        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Item progress

extension DocumentTabStrip.Item {
    /// The progress aggregation for a single tab item.
    /// Stored as a value type alongside `status` and `isEdited`.
    // Note: progress is added as a stored property on Item below.
}

// MARK: - VoiceOver label helper

extension ProgressAggregation {
    /// Appended to the tab's AX label.  Nil when hidden.
    var accessibilityDescription: String? {
        switch self {
        case .hidden:           return nil
        case .determinate(let p): return "progress \(p)%"
        case .indeterminate:    return "indeterminate progress"
        case .error:            return "progress error"
        case .paused(let p):    return "paused \(p)%"
        }
    }
}
