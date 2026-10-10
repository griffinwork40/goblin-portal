//
//  DirectoryFollowIndicatorView.swift
//  A quiet ambient note above the file tree: "remote: host / following paused".
//
//  WHY THIS EXISTS. When the focused shell is remote (ssh) or a multiplexer we cannot
//  follow (screen, zellij), the sidebar tree sits on the last local directory. Without
//  feedback, the user has no way to know following is paused. This view fills that gap
//  with a secondary-colour note that matches `GitBranchHeaderView`'s style — same font
//  (11pt), same colour (.secondaryLabelColor), same height (22pt). It is deliberately
//  lighter and smaller than anything load-bearing, because it describes a limitation
//  rather than an action. Reference: plan §3, decision 3; ShellContext.swift lines 29–38.
//
//  WHEN IT SHOWS.
//  - `.remote(host:)` → "remote: <host>" line 1 + "following paused" line 2.
//  - `.remote(host:nil)` → "remote session" line 1 + "following paused" line 2.
//  - `.paused(program:)` → SF Symbol pause.circle line 1 + "following paused: <prog>" line 2.
//  - `.local` and `.unavailable` → hidden. `.unavailable` is transient (shell starting or
//    exiting); flashing a note and hiding it within one 750ms tick would be distracting.
//
//  VISUAL STYLE. Matches GitBranchHeaderView: no background (sidebar vibrant material shows
//  through), .secondaryLabelColor for text and symbol tinting, 11pt system font.
//  Theme-aware by construction — system semantic colours adapt automatically.
//
//  IN SOURCE CONTROL VIEW. Hidden. The SCM panel replaces the Explorer tree; showing a
//  cwd-follow note while the tree itself is hidden would be confusing and wasted space.
//  `FileTreeViewController+FollowStatus.swift` enforces this by also hiding the indicator
//  when chromeSuppressed is true (same flag GitBranchHeaderView uses).
//

import AppKit

@MainActor
final class DirectoryFollowIndicatorView: NSView {

    // MARK: - Subviews

    /// Symbol glyph: `network` for remote, `pause.circle` for paused.
    private let glyph = NSImageView()

    /// Primary text: "remote: host", "remote session", or "following paused: <prog>".
    let line1Label = NSTextField(labelWithString: "")

    /// Secondary text: "following paused" (remote cases only, empty for paused).
    let line2Label = NSTextField(labelWithString: "")

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // No background: sidebar paints its own vibrant material, same as GitBranchHeaderView.
        glyph.image?.isTemplate = true
        glyph.contentTintColor = .secondaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false

        for label in [line1Label, line2Label] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        let textColumn = NSStackView(views: [line1Label, line2Label])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 0
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        // Text column fills all available horizontal space (stack pins it).
        textColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        line1Label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        line2Label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(glyph)
        addSubview(textColumn)

        NSLayoutConstraint.activate([
            // Glyph: fixed 14pt wide, centred in our 22pt height, flush leading.
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            glyph.heightAnchor.constraint(equalToConstant: 14),

            // Text column: follows glyph with a 4pt gap, trails with 4pt margin.
            textColumn.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            textColumn.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            textColumn.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Fixed height: 22pt, same as GitBranchHeaderView's 26pt minus its 4pt gap.
            // The stack in FileTreeViewController manages spacing between header and indicator.
            heightAnchor.constraint(equalToConstant: 22),
        ])

        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used — views are built programmatically")
    }

    // MARK: - Configuration

    /// Update the view's content and visibility to match `status`.
    ///
    /// `.local` and `.unavailable` hide; `.remote` and `.paused` show with the
    /// appropriate text and symbol. This is the only path that writes the view's state,
    /// so there is one writer and the view cannot disagree with what `tick()` last read.
    func configure(status: DirectoryFollowStatus) {
        switch status {
        case .local, .unavailable:
            // Unavailable is transient — hide silently, no note.
            isHidden = true

        case .remote(let host):
            let symbolName = "network"
            glyph.image = NSImage(
                systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            glyph.image?.isTemplate = true
            glyph.contentTintColor = .secondaryLabelColor

            line1Label.stringValue = host.map { "remote: \($0)" } ?? "remote session"
            line2Label.stringValue = "following paused"
            line2Label.isHidden = false

            // Tooltip and AX label: explain what the note means so it's not cryptic.
            // "Sidebar shows the last local folder" is the key fact for any user asking why
            // the tree is not updating — referenced from AFK.md Known Risks (planned row).
            let axText = "Remote session active. Sidebar shows the last local folder."
            setAccessibilityLabel(axText)
            toolTip = axText
            isHidden = false

        case .paused(let program):
            let symbolName = "pause.circle"
            glyph.image = NSImage(
                systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            glyph.image?.isTemplate = true
            glyph.contentTintColor = .secondaryLabelColor

            line1Label.stringValue = "following paused: \(program)"
            line2Label.stringValue = ""
            line2Label.isHidden = true

            let axText = "Following paused (\(program) in front). Sidebar shows the last local folder."
            setAccessibilityLabel(axText)
            toolTip = axText
            isHidden = false
        }
    }
}
