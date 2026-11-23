//
//  FileTreeRowView.swift
//  Hover-aware row view for the file tree sidebar. Draws a subtle rounded
//  background fill that fades in when the cursor enters the row, matching
//  the hover idiom in SourceControlRowView (0.12 s).
//
//  Its own file because it is one concern with one reason to change: how a
//  file tree row responds to mouse hover. The outline view asks for it via
//  `outlineView(_:rowViewForItem:)` in `FileTreeViewController+OutlineView.swift`;
//  `FileTreeOutlineView.swift` sets `isHovered` from a single tracking area.
//

import AppKit

/// A `NSTableRowView` that draws a subtle hover highlight behind the file tree cell.
///
/// The highlight is a Core Animation sublayer whose opacity animates between
/// 0 and 1, so the transition runs in the compositor with no main-thread draw
/// calls. The layer is hidden when the row is selected so the system's
/// selection pill is unobstructed.
@MainActor
final class FileTreeRowView: NSTableRowView {

    /// Whether the cursor is currently over this row. Set by
    /// `FileTreeOutlineView`'s tracking area; never by the row itself.
    var isHovered: Bool = false {
        didSet {
            guard isHovered != oldValue else { return }
            animateHover()
        }
    }

    private let hoverLayer: CALayer = {
        let layer = CALayer()
        layer.opacity = 0
        layer.cornerRadius = 5
        return layer
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(hoverLayer)
        resolveHoverColour()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Inset so the hover fill sits inside the row like the selection pill.
        hoverLayer.frame = bounds.insetBy(dx: 4, dy: 1)
    }

    override var isSelected: Bool {
        didSet {
            // The selection pill provides its own fill; drawing the hover
            // behind it muddies the contrast.
            hoverLayer.isHidden = isSelected
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveHoverColour()
    }

    // MARK: - Private

    private func animateHover() {
        let target: Float = isHovered ? 1 : 0
        let duration = isHovered ? 0.12 : 0.18
        // Remove any in-flight animation to prevent visual stutter when
        // the cursor sweeps across rows quickly.
        hoverLayer.removeAnimation(forKey: "hoverFade")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = hoverLayer.presentation()?.opacity ?? hoverLayer.opacity
        anim.toValue = target
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hoverLayer.opacity = target
        hoverLayer.add(anim, forKey: "hoverFade")
    }

    /// Re-resolve the fill colour so it tracks Dark Mode and Increase Contrast.
    ///
    /// `NSColor` is appearance-relative, but `CGColor` is not, so a resolved
    /// `CGColor` goes stale on a system appearance change. The same pattern
    /// appears in `FileCellView.applyTint()` for the session-touched chip.
    private func resolveHoverColour() {
        hoverLayer.backgroundColor =
            NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }
}
