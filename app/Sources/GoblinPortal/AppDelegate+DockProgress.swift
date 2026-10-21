// AppDelegate+DockProgress.swift
// Drives NSDockTile progress when any open terminal pane has active OSC 9;4 state.
//
// Why a separate file from AppDelegate+DockAttention.swift
// ---------------------------------------------------------
// DockAttention governs the badge count and bounce — a separate, orthogonal
// concern (user-attention signals vs progress reporting).  The badge (badgeLabel)
// and a custom contentView coexist on NSDockTile: the system draws the badge
// label over the tile; our contentView sits beneath it.  This file manages the
// contentView lifecycle only; +DockAttention manages badgeLabel only.  Neither
// touches the other's slot.
//
// Aggregation
// -----------
// Walks all open Space windows and their split peers on every call (same O(windows
// × documents) walk as attentionDocumentCount() — cheap at realistic scale).
// Calls ProgressAggregation.of([states]) from ProgressReportPolicy.swift.
// Installs a DockProgressView as contentView while progress is active; restores
// contentView = nil when aggregation returns .hidden, letting the system draw the
// normal app icon again.
//
// The attention badge (badgeLabel) is managed by recountAndUpdateBadge() in
// AppDelegate+DockAttention.swift and is completely unaffected by this file.
//
import AppKit

@MainActor
extension AppDelegate {

    // MARK: - Entry point (called from syncDocumentChrome via documentDidChangeStatus)

    /// Recompute the aggregated progress across all open documents and update the
    /// Dock tile.  Called from dockProgressDidChange() in SpaceViewController+Progress.swift
    /// which is called from syncDocumentChrome whenever any documentDidChangeStatus fires.
    func updateDockProgress() {
        let states = allProgressStates()
        let agg = ProgressAggregation.of(states)

        if agg == .hidden {
            clearDockProgress()
        } else {
            showDockProgress(agg)
        }
    }

    // MARK: - Aggregation

    private func allProgressStates() -> [ProgressState] {
        SpaceWindowController.open.flatMap { controller -> [ProgressState] in
            let primary = controller.space.allDocuments.compactMap {
                ($0 as? TerminalPane)?.progressPolicy.state
            }
            let peers = controller.space.splitPeers.values.flatMap {
                $0.allPeerDocuments.compactMap { ($0 as? TerminalPane)?.progressPolicy.state }
            }
            return primary + peers
        }
    }

    // MARK: - Dock tile management

    private func showDockProgress(_ agg: ProgressAggregation) {
        let tile = NSApp.dockTile
        // Reuse an existing DockProgressView if already installed.
        let view: DockProgressView
        if let existing = tile.contentView as? DockProgressView {
            view = existing
        } else {
            view = DockProgressView(frame: NSRect(x: 0, y: 0, width: tile.size.width,
                                                  height: tile.size.height))
            tile.contentView = view
        }
        view.aggregation = agg
        view.needsDisplay = true
        tile.display()
    }

    private func clearDockProgress() {
        guard NSApp.dockTile.contentView is DockProgressView else { return }
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

// MARK: - DockProgressView

/// A custom Dock tile view that draws a progress bar over the app icon.
///
/// Drawing strategy: paint the system app icon first (via NSApp.applicationIconImage)
/// then overlay a rounded progress bar at the bottom, styled by aggregation state.
/// The bar is 14% of the tile height, horizontally inset 8%.
///
/// Coexistence with badgeLabel: NSApp.dockTile.badgeLabel is drawn by the system
/// OVER the contentView — it is not part of our layer and is unaffected by this view.
@MainActor
final class DockProgressView: NSView {

    var aggregation: ProgressAggregation = .hidden

    override func draw(_ dirtyRect: NSRect) {
        // Draw the application icon as the tile background so the progress bar
        // overlays the real icon rather than a blank tile.
        NSApp.applicationIconImage.draw(in: bounds)

        guard aggregation != .hidden else { return }

        let barHeight: CGFloat = bounds.height * 0.14
        let insetX: CGFloat    = bounds.width  * 0.08
        let barY: CGFloat      = bounds.height * 0.04
        let barRect = NSRect(x: insetX, y: barY,
                             width: bounds.width - 2 * insetX, height: barHeight)
        let radius  = barHeight / 2

        // Track background.
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()

        switch aggregation {
        case .hidden:
            break   // handled above

        case .indeterminate:
            // Full-width bar in blue — no fraction known.
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()

        case .determinate(let pct):
            let fraction = CGFloat(pct) / 100
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY,
                                  width: barRect.width * fraction, height: barRect.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).addClip()
            NSColor.systemGreen.setFill()
            fillRect.fill()
            NSGraphicsContext.restoreGraphicsState()

        case .error:
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()

        case .paused(let pct):
            let fraction = CGFloat(pct) / 100
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY,
                                  width: barRect.width * fraction, height: barRect.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).addClip()
            NSColor.systemYellow.setFill()
            fillRect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
