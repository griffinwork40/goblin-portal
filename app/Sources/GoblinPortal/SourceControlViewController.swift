//
//  SourceControlViewController.swift
//  The Source Control sidebar panel: commit message input, Push/Pull toolbar,
//  and a three-section outline view (Staged Changes / Changes / Untracked).
//
//  Separate from the file-tree controller because it is a distinct conceptual
//  surface (write-side git vs. read-side decoration), a distinct NSViewController
//  life cycle, and would push FileTreeViewController past the 350-LOC ceiling.
//  Action methods live in +Actions.swift; NSOutlineView plumbing in +DataSource.swift.
//

import AppKit

// MARK: - Section model

/// The three logical buckets shown in the outline view.
enum SourceControlSection: Int, CaseIterable {
    case staged, changes, untracked

    var title: String {
        switch self {
        case .staged:    return "Staged Changes"
        case .changes:   return "Changes"
        case .untracked: return "Untracked"
        }
    }
}

// MARK: - Controller

@MainActor final class SourceControlViewController: NSViewController {

    // MARK: Delegate & repository state

    weak var delegate: SourceControlDelegate?

    /// The repository this panel is operating on. Set by the wiring code when
    /// the sidebar discovers (or loses) a git repo for the active Space.
    var repository: GitRepository?

    /// The last snapshot delivered by the poller. Drives the outline sections.
    private(set) var snapshot: GitStatusSnapshot = .empty

    /// Derived arrays from `snapshot`, rebuilt in `update(snapshot:)`.
    private(set) var staged:    [GitFileEntry] = []
    private(set) var changes:   [GitFileEntry] = []
    private(set) var untracked: [GitFileEntry] = []

    // The section-header strings used as group items in the outline view.
    // Kept as an ordered array so index arithmetic is unambiguous.
    let sections: [String] = SourceControlSection.allCases.map(\.title)

    // MARK: Subviews

    let commitField: NSTextField = {
        let f = NSTextField()
        f.placeholderString = "Message (⌘Enter to commit)"
        f.bezelStyle = .roundedBezel
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let commitButton: NSButton = {
        let b = NSButton(title: "Commit", target: nil, action: #selector(commitChanges(_:)))
        b.bezelStyle = .rounded
        b.keyEquivalent = "\r"
        b.keyEquivalentModifierMask = .command
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let pushButton: NSButton = {
        let b = NSButton(title: "", target: nil, action: #selector(pushChanges(_:)))
        b.image = NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: "Push")
        b.image?.isTemplate = true
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.toolTip = "Push"
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let pullButton: NSButton = {
        let b = NSButton(title: "", target: nil, action: #selector(pullChanges(_:)))
        b.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Pull")
        b.image?.isTemplate = true
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.toolTip = "Pull"
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    let outlineView: NSOutlineView = {
        let ov = NSOutlineView()
        ov.style = .sourceList
        ov.selectionHighlightStyle = .sourceList
        ov.indentationPerLevel = 12
        ov.rowHeight = 22
        ov.floatsGroupRows = false
        ov.autoresizesOutlineColumn = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.minWidth = 80
        ov.addTableColumn(col)
        ov.outlineTableColumn = col
        ov.headerView = nil
        ov.translatesAutoresizingMaskIntoConstraints = false
        return ov
    }()

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.drawsBackground = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    // MARK: Init

    init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SourceControlViewController is programmatic") }

    // MARK: Life cycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Wire up targets (self is not yet in scope at field init time)
        commitButton.target = self
        pushButton.target   = self
        pullButton.target   = self

        outlineView.dataSource = self
        outlineView.delegate   = self
        outlineView.target     = self
        outlineView.doubleAction = #selector(outlineDoubleClicked(_:))

        // Wire up the context menu via NSMenuDelegate so AppKit actually calls it.
        // NSOutlineViewDelegate has no menuFor: method — the correct pattern is to
        // assign a menu with a delegate (see FileTreeViewController+ContextMenu.swift).
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self

        scrollView.documentView = outlineView
        buildLayout()
    }

    // MARK: Layout

    private func buildLayout() {
        // Commit area: [field] [commit] with push/pull icons on a second row
        let commitRow = NSStackView(views: [commitField, commitButton])
        commitRow.orientation  = .horizontal
        commitRow.spacing      = 6
        commitRow.translatesAutoresizingMaskIntoConstraints = false

        let syncRow = NSStackView(views: [pushButton, pullButton, NSView()])
        syncRow.orientation  = .horizontal
        syncRow.spacing      = 4
        syncRow.translatesAutoresizingMaskIntoConstraints = false

        let commitArea = NSView()
        commitArea.translatesAutoresizingMaskIntoConstraints = false
        commitArea.addSubview(commitRow)
        commitArea.addSubview(syncRow)

        NSLayoutConstraint.activate([
            commitRow.topAnchor.constraint(equalTo: commitArea.topAnchor, constant: 8),
            commitRow.leadingAnchor.constraint(equalTo: commitArea.leadingAnchor, constant: 8),
            commitRow.trailingAnchor.constraint(equalTo: commitArea.trailingAnchor, constant: -8),

            syncRow.topAnchor.constraint(equalTo: commitRow.bottomAnchor, constant: 4),
            syncRow.leadingAnchor.constraint(equalTo: commitArea.leadingAnchor, constant: 8),
            syncRow.trailingAnchor.constraint(equalTo: commitArea.trailingAnchor, constant: -8),
            syncRow.bottomAnchor.constraint(equalTo: commitArea.bottomAnchor, constant: -8),
        ])

        view.addSubview(commitArea)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            commitArea.topAnchor.constraint(equalTo: view.topAnchor),
            commitArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            commitArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: commitArea.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: Data update

    /// Called by the wiring code (e.g. the git poller) with a fresh snapshot.
    func update(snapshot: GitStatusSnapshot, repository: GitRepository? = nil) {
        if let repository { self.repository = repository }
        self.snapshot = snapshot

        var s: [GitFileEntry] = []
        var c: [GitFileEntry] = []
        var u: [GitFileEntry] = []

        for entry in snapshot.entries.values.sorted(by: { $0.path < $1.path }) {
            switch entry.status {
            case .untracked, .ignored:
                u.append(entry)
            default:
                if entry.isStaged { s.append(entry) } else { c.append(entry) }
                // A partially-staged file (MM porcelain) has isStaged=true AND
                // working-tree changes. Show it in both sections so the user sees
                // the unstaged half, matching VS Code's two-row presentation.
                if entry.isStaged && entry.status == .modified {
                    c.append(entry)
                }
            }
        }

        staged    = s
        changes   = c
        untracked = u

        // Preserve user collapse state across reloads so the 2-second poll tick
        // does not destroy sections the user intentionally collapsed.
        var expanded = Set<String>()
        for title in sections {
            if outlineView.isItemExpanded(title) { expanded.insert(title) }
        }
        // On first load (outline is empty), default all sections to expanded.
        let isFirstLoad = expanded.isEmpty && outlineView.numberOfRows == 0
        outlineView.reloadData()
        for title in sections {
            if isFirstLoad || expanded.contains(title) {
                outlineView.expandItem(title)
            }
        }
    }

    func entries(for section: SourceControlSection) -> [GitFileEntry] {
        switch section {
        case .staged:    return staged
        case .changes:   return changes
        case .untracked: return untracked
        }
    }

    func section(for title: String) -> SourceControlSection? {
        SourceControlSection.allCases.first { $0.title == title }
    }

    // MARK: Double-click

    @objc private func outlineDoubleClicked(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0,
              let entry = sender.item(atRow: row) as? GitFileEntry,
              let section = sectionFor(entry: entry) else { return }
        let staged = section == .staged
        delegate?.sourceControl(self, didRequestDiff: entry, staged: staged)
    }

    private func sectionFor(entry: GitFileEntry) -> SourceControlSection? {
        if staged.contains(entry)    { return .staged }
        if changes.contains(entry)   { return .changes }
        if untracked.contains(entry) { return .untracked }
        return nil
    }
}
