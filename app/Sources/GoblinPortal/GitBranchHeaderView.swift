//
//  GitBranchHeaderView.swift
//  The one line above the file tree: which branch, and how far from its upstream.
//
//  Its own file because it is a view with its own layout, and the file tree's git concern
//  (`FileTreeViewController+Git.swift`) is a poller with its own lifecycle — one file per
//  concern, not one file per feature.
//
//  WHERE THIS GOES WAS A JUDGMENT CALL, and the research left it open on purpose
//  (`.afk/research/git-sidebar-decision-2026-07-31.md` §6.1): a sidebar header, or a live
//  window title. The window lost on plumbing, not on taste. `window.subtitle` already has
//  exactly one writer — `SpaceWindowController.spaceViewController(_:didChangeDocumentTitle:)`
//  is the single funnel for it — so a branch string would have had to reach that funnel from
//  the file tree through the Space, which means a new delegate member, a forward through
//  `SpaceViewController.swift` (345/350 lines, four to spare), and a second thing composing
//  one string. The header reaches the same eye with no plumbing at all, because the poller
//  that knows the branch already owns the tree this sits on top of.
//
//  It is also the reversible choice, which is what an open judgment call deserves: deleting
//  this file and one stack-view line in `loadView` removes the feature and leaves the
//  decorations untouched.
//
//  IT DISAPPEARS COMPLETELY WHEN THERE IS NO REPOSITORY. Not greyed out, not "—": hidden,
//  and hidden inside an `NSStackView`, which drops hidden views out of the layout rather
//  than leaving a gap. A Space opened on `~/Documents` therefore looks exactly as it did
//  before this feature existed, which is the bar for anything that adds chrome to a tool
//  whose whole premise is getting out of the way.
//

import AppKit

/// A single ambient line: branch name, and ahead/behind when there is an upstream.
///
/// Read-only by construction — there is nothing here to click. That is the project boundary
/// the plan of record already drew before the question was asked, listing "destructive git
/// operations in a GUI" among the things to refuse regardless
/// (`.afk/plans/emulator-foundation-probe-and-vendor-integrity.md:208-215`). A branch name
/// you can read is not a branch you can switch, and this view is the read-only half.
@MainActor
final class GitBranchHeaderView: NSView {
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // No background of its own. The sidebar item paints a vibrant material and an
        // opaque strip on top of it would flatten that to a solid rectangle — the same
        // reason `FileTreeViewController`'s scroll view sets `drawsBackground = false`.
        glyph.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        glyph.image?.isTemplate = true
        glyph.contentTintColor = .secondaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false

        // Secondary, and a point smaller than a filename. This is ambient state — the
        // answer to "which branch am I on" that you take in without looking for it — so it
        // must lose to the filenames underneath it in the visual hierarchy. The same
        // argument the tree's own glyphs make for `secondaryLabelColor`.
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyph)
        addSubview(label)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Fixed height rather than derived from the label, so the tree below it does
            // not shift by a point when a branch name's glyphs happen to be taller.
            heightAnchor.constraint(equalToConstant: 22),
        ])

        // Hidden until told otherwise. The alternative — visible and empty until the first
        // poll lands ~immediately after the window becomes key — is a strip that appears a
        // frame after the window does, which reads as a glitch.
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — views are created programmatically")
    }

    /// Show `summary`, or disappear entirely when it is nil.
    ///
    /// Called from `FileTreeViewController.gitStatusDidChange()` only, so there is one
    /// writer and no way for this to disagree with the decorations below it — both read the
    /// same snapshot in the same pass.
    func update(summary: String?) {
        guard let summary else {
            isHidden = true
            return
        }
        isHidden = false
        label.stringValue = summary
        // VoiceOver would otherwise read the raw string, and "main ↑2" is not a sentence.
        // The arrows are the compact form for a glance; this is the same information for
        // someone who is not glancing.
        setAccessibilityLabel("Git branch: " + summary
            .replacingOccurrences(of: "↑", with: "ahead ")
            .replacingOccurrences(of: "↓", with: "behind "))
    }
}
