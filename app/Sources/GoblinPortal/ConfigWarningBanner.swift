//
//  ConfigWarningBanner.swift
//  The non-modal strip under a Space window's titlebar that says which config
//  settings were ignored (#166, T1.5). View only — the words and the show/hide
//  decision come from `ConfigWarningPolicy` (Foundation-only, gated), and which
//  windows carry it is `ConfigWarningPresenter`'s job (`ConfigWarningPresenter.swift`).
//
//  WHY A TITLEBAR ACCESSORY, NOT AN OVERLAY OR AN ALERT.
//  - Not an `NSAlert`: the issue asks for a non-modal banner, and an alert at launch
//    blocks the very window the user opened the app to type in. A bad `config.json`
//    is degraded-but-working by design (AFK.md "Config parsing fails soft"), so the
//    notice must not be louder than the problem.
//  - Not a subview over the document area: `DocumentAreaViewController` lays its
//    container out by hand (`viewDidLayout`), and an overlay there would cover the
//    terminal's top rows — the exact clipping bug `SpaceWindowController.swift:130-141`
//    records for `.fullSizeContentView`.
//  - `NSTitlebarAccessoryViewController` with `.bottom` is the system slot for a
//    full-width strip under the titlebar (Safari's and Xcode's banners live there).
//    AppKit shrinks the content area to make room, so nothing is covered, and the
//    window's own titlebar draws behind it with the theme's appearance
//    (`window.appearance = config.appearance`, SpaceWindowController.swift:162), so
//    `labelColor` text stays legible on both dark and light themes without this file
//    reading the palette. `SidebarToggleAccessory.swift` is the in-repo precedent for
//    using this class at all.
//

import AppKit

@MainActor
final class ConfigWarningBanner: NSTitlebarAccessoryViewController {
    /// Fixed metrics, so the strip's height is a function of the line count only.
    /// Every warning line truncates to one line (`.byTruncatingTail`); the tooltip
    /// carries the full text. A wrapping label would make the height depend on the
    /// window width, which an accessory's fixed frame cannot follow.
    private static let padding: CGFloat = 8
    private static let titleHeight: CGFloat = 18
    private static let lineHeight: CGFloat = 16

    private let banner: ConfigWarningPolicy.Banner
    /// Weak so a banner never keeps its presenter alive. Safe because the presenter is
    /// a process-lifetime singleton (`ConfigWarningPresenter.shared`).
    private weak var presenter: ConfigWarningPresenter?

    init(banner: ConfigWarningPolicy.Banner, presenter: ConfigWarningPresenter) {
        self.banner = banner
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        // The strip's height is ours, from the frame `loadView` sets — not a fit
        // AppKit computes. With the default (`true`) the titlebar sized it to ~34pt,
        // the button row, and the warning lines spilled over the sidebar (observed
        // live on macOS 27 with a five-warning config).
        automaticallyAdjustsSize = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — controllers are created programmatically")
    }

    /// The text this banner was built from — read back by the presenter to skip a
    /// rebuild when a reload produced identical warnings.
    var content: ConfigWarningPolicy.Banner { banner }

    override func loadView() {
        var bodyLines = banner.lines
        if banner.overflow > 0 {
            bodyLines.append("and \(banner.overflow) more — hover for the full list")
        }
        let height = Self.padding * 2 + Self.titleHeight + Self.lineHeight * CGFloat(bodyLines.count)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        container.wantsLayer = true
        // A tint, not an opaque fill: the titlebar material underneath already follows
        // the theme's appearance, and a translucent yellow reads as "warning" on both
        // the dark and the light chrome without picking a second, theme-blind colour.
        container.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        container.toolTip = banner.fullText
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("Config warnings. \(banner.title). \(banner.fullText)")

        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                              accessibilityDescription: "Warning") ?? NSImage())
        icon.contentTintColor = .systemYellow

        let title = Self.label(banner.title, font: .boldSystemFont(ofSize: 12), colour: .labelColor)
        let lines = NSStackView(views: [title] + bodyLines.map {
            Self.label("• " + $0, font: .systemFont(ofSize: 11), colour: .secondaryLabelColor)
        })
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 0

        let open = NSButton(title: "Open config.json", target: self, action: #selector(openConfig(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark",
                                            accessibilityDescription: "Dismiss") ?? NSImage(),
                             target: self, action: #selector(dismissBanner(_:)))
        close.isBordered = false
        close.setAccessibilityLabel("Dismiss config warnings")
        close.toolTip = "Dismiss — reappears on the next ⌘R or Settings Apply if still unfixed"

        for v in [icon, lines, open, close] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        // The text column takes whatever width the buttons leave, and gives it up
        // first: low compression resistance lets each label truncate instead of
        // pushing the buttons off the right edge of a narrow window.
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let p = Self.padding
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: p + 1),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            lines.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            lines.topAnchor.constraint(equalTo: container.topAnchor, constant: p),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -12),
            open.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            open.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            close.widthAnchor.constraint(equalToConstant: 20),
            close.heightAnchor.constraint(equalToConstant: 20),
        ])
        // Keep the strip visible in full screen too: a `.bottom` accessory otherwise
        // only appears with the auto-hidden titlebar, i.e. not while the user types.
        fullScreenMinHeight = height
        view = container
    }

    private static func label(_ text: String, font: NSFont, colour: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = colour
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// The raw JSON, not the Settings panel: the most common cause of this banner is a
    /// syntax error, and the panel cannot show or fix text it could not parse
    /// (`PreferencesWindow.rawConfigDict()` returns nil for invalid JSON).
    @objc private func openConfig(_ sender: Any?) {
        NSWorkspace.shared.open(AppConfig.configURL)
    }

    @objc private func dismissBanner(_ sender: Any?) {  // not `dismiss(_:)`: NSViewController owns that selector
        presenter?.dismiss()
    }
}
