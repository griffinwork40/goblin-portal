//
//  DiffViewerPane.swift
//  A read-only side-by-side diff of one file — a document tab opened when the
//  user clicks a changed file in the Source Control panel.
//
//  Owns the view hierarchy, the async diff load, and the synced-scroll wiring.
//  SpaceDocument conformance lives in +Document; diff rendering in +Highlighting.
//
//  View hierarchy:
//    containerView (NSView)
//    ├── headerBar (NSView, 28pt) — old path, arrow, new path, 'Staged' badge
//    └── splitView (NSSplitView, horizontal)
//        ├── leftScroll → leftTextView   (old file content)
//        └── rightScroll → rightTextView (new file content)
//
//  Scroll sync uses NSView.boundsDidChangeNotification on the clip views.
//  Either side can drive; a re-entrancy flag prevents feedback loops.
//

import AppKit

/// A thin NSView subclass whose sole job is to call back into the pane's
/// layout pass whenever AppKit decides to lay out this view.
///
/// Without this, `DiffViewerPane.layoutSubviews(in:)` is defined but never
/// called, leaving the header bar with a zero frame and invisible on screen.
/// Using `layout()` rather than `resizeSubviews(withOldSize:)` is correct
/// because we size both the header and the split view, not just subviews.
@MainActor
final class DiffContainerView: NSView {
    weak var pane: DiffViewerPane?

    override func layout() {
        super.layout()
        pane?.layoutSubviews(in: bounds)
    }
}

@MainActor
final class DiffViewerPane: NSObject {
    // MARK: - Identity

    /// Repo-relative path of the file being diffed.
    let filePath: String
    /// True when diffing index vs HEAD (staged); false for working-tree vs HEAD.
    let staged: Bool
    let repository: GitRepository
    var config: AppConfig

    // MARK: - Stored layout constants

    static let headerHeight: CGFloat = 28
    static let gutterWidth: CGFloat = 44  // digits + padding
    static let minFontSize = CGFloat(AppConfig.minFontSize)
    static let maxFontSize = CGFloat(AppConfig.maxFontSize)

    // MARK: - Font size state (same shape as FileViewerPane)

    var fontSize: CGFloat

    // MARK: - Views

    /// Single root exposed to the Space as `documentView`.
    let containerView = DiffContainerView()
    let headerBar = NSView()
    let splitView = NSSplitView()

    let leftScroll  = NSScrollView()
    let leftTextView  = NSTextView()
    let rightScroll = NSScrollView()
    let rightTextView = NSTextView()

    // Header labels — internal (not private) so DiffViewerPane+Highlighting.swift
    // can update them directly when a rename is detected, without a fragile view
    // hierarchy walk. Swift `private` is file-scoped, blocking extension access.
    let oldPathLabel  = NSTextField(labelWithString: "")
    private let arrowLabel    = NSTextField(labelWithString: "→")
    let newPathLabel  = NSTextField(labelWithString: "")
    private let stagedBadge   = NSTextField(labelWithString: "Staged")

    // MARK: - Scroll-sync state

    /// Re-entrancy guard: prevents the observer from bouncing updates back.
    private var isSyncingScroll = false

    // MARK: - Init

    init(filePath: String, staged: Bool, repository: GitRepository, config: AppConfig) {
        self.filePath   = filePath
        self.staged     = staged
        self.repository = repository
        self.config     = config
        self.fontSize   = FontZoom.override ?? config.font.pointSize
        super.init()

        // Give the container a back-reference so its layout() override can call
        // into our layoutSubviews(in:) — see DiffContainerView above.
        containerView.pane = self

        buildViewHierarchy()
        applyTheme()
        loadDiff()
    }

    // MARK: - View assembly

    private func buildViewHierarchy() {
        // Header bar
        containerView.addSubview(headerBar)
        buildHeader()

        // Split view — two text views side by side
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        containerView.addSubview(splitView)

        configureTextPane(leftScroll, textView: leftTextView)
        configureTextPane(rightScroll, textView: rightTextView)
        splitView.addArrangedSubview(leftScroll)
        splitView.addArrangedSubview(rightScroll)

        // Layout is driven by viewDidLayout-equivalent: autoresizing masks handle it.
        headerBar.autoresizingMask = [.width, .maxYMargin]
        containerView.autoresizingMask = [.width, .height]

        wireScrollSync()
    }

    private func buildHeader() {
        headerBar.wantsLayer = true

        for label in [oldPathLabel, arrowLabel, newPathLabel] {
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            headerBar.addSubview(label)
        }

        // Staged badge — pill-shaped, hidden unless staged
        stagedBadge.font = .systemFont(ofSize: 10, weight: .medium)
        stagedBadge.translatesAutoresizingMaskIntoConstraints = false
        stagedBadge.wantsLayer = true
        stagedBadge.layer?.cornerRadius = 3
        stagedBadge.isHidden = !staged
        headerBar.addSubview(stagedBadge)

        // Labels derive their displayed values from filePath
        let oldDisplay = (filePath as NSString).lastPathComponent
        let newDisplay = oldDisplay
        oldPathLabel.stringValue = oldDisplay
        newPathLabel.stringValue = newDisplay

        NSLayoutConstraint.activate([
            oldPathLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 8),
            oldPathLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            oldPathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            arrowLabel.leadingAnchor.constraint(equalTo: oldPathLabel.trailingAnchor, constant: 6),
            arrowLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            newPathLabel.leadingAnchor.constraint(equalTo: arrowLabel.trailingAnchor, constant: 6),
            newPathLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            newPathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            stagedBadge.leadingAnchor.constraint(equalTo: newPathLabel.trailingAnchor, constant: 8),
            stagedBadge.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
        ])
    }

    private func configureTextPane(_ scroll: NSScrollView, textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true        // required for attributed rendering
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.contentView.postsBoundsChangedNotifications = true
    }

    // MARK: - Scroll sync

    private func wireScrollSync() {
        let nc = NotificationCenter.default
        // Drive from left → right and right → left, guarded by isSyncingScroll.
        nc.addObserver(self,
            selector: #selector(leftScrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: leftScroll.contentView)
        nc.addObserver(self,
            selector: #selector(rightScrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: rightScroll.contentView)
    }

    @objc private func leftScrolled(_ note: Notification) {
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        let origin = leftScroll.contentView.bounds.origin
        rightScroll.contentView.scroll(to: NSPoint(x: rightScroll.contentView.bounds.minX,
                                                   y: origin.y))
        rightScroll.reflectScrolledClipView(rightScroll.contentView)
        isSyncingScroll = false
    }

    @objc private func rightScrolled(_ note: Notification) {
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        let origin = rightScroll.contentView.bounds.origin
        leftScroll.contentView.scroll(to: NSPoint(x: leftScroll.contentView.bounds.minX,
                                                  y: origin.y))
        leftScroll.reflectScrolledClipView(leftScroll.contentView)
        isSyncingScroll = false
    }

    // MARK: - Layout

    /// Called by `DiffContainerView.layout()` whenever AppKit lays out the container.
    /// Manually positions the header bar and split view within `frame` since they
    /// use autoresizing masks rather than Auto Layout constraints.
    func layoutSubviews(in frame: NSRect) {
        let hh = Self.headerHeight
        headerBar.frame = NSRect(x: 0, y: frame.height - hh, width: frame.width, height: hh)
        splitView.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - hh)
        containerView.frame = frame
    }

    // MARK: - Async diff load

    func loadDiff() {
        // Show a loading placeholder immediately so the tab does not look broken.
        showPlaceholder("Loading diff…")

        let path = filePath
        let isStaged = staged
        let repo = repository

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = GitDiff.diff(path: path, staged: isStaged, in: repo)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let raw else {
                    self.showPlaceholder("No diff available — the file may be untracked or clean.")
                    return
                }
                let diffs = DiffParser.parse(raw)
                if let fileDiff = diffs.first {
                    self.renderDiff(fileDiff)
                } else {
                    self.showPlaceholder("The file appears clean with respect to HEAD.")
                }
            }
        }
    }

    private func showPlaceholder(_ message: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: message, attributes: attrs)
        leftTextView.textStorage?.setAttributedString(str)
        rightTextView.textStorage?.setAttributedString(NSAttributedString())
    }

    // MARK: - Theme application

    func applyTheme() {
        let bg = config.effectiveBackground
        let fg = config.effectiveForeground

        headerBar.layer?.backgroundColor = bg.blended(withFraction: 0.05, of: .white)?.cgColor
            ?? bg.cgColor

        for scroll in [leftScroll, rightScroll] {
            scroll.backgroundColor = bg
        }
        for tv in [leftTextView, rightTextView] {
            tv.backgroundColor = bg
            tv.textColor = fg
        }

        // Header labels
        let labelColor = fg.withAlphaComponent(0.75)
        oldPathLabel.textColor = labelColor
        newPathLabel.textColor = labelColor
        arrowLabel.textColor = labelColor.withAlphaComponent(0.5)

        // Staged badge pill
        stagedBadge.textColor = NSColor.white
        stagedBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.8).cgColor
    }
}
