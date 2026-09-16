//
//  CommandPalette.swift
//  ⌘⇧P command palette — fuzzy-search all editor commands and execute them.
//
//  The palette is a floating panel (NOT a sheet) so it can hover above the
//  document without being modal. It owns its own NSPanel + NSTextField for the
//  query and an NSTableView for the results.
//
//  Architecture: the palette is a singleton panel, created once and toggled
//  visible. `AppDelegate.showCommandPalette(_:)` is the ⌘⇧P action; it calls
//  `CommandPalette.shared.toggle(in:)`, passing the current SpaceViewController
//  as the command target so actions are dispatched through the right responder
//  chain.
//
//  Command list: statically built from `CommandPalette.allCommands` in
//  `CommandPalette+Commands.swift`. Adding a command means editing that file only.
//
//  Delegate conformances (NSTableView, NSSearchField, NSWindow) and `PaletteRowView`
//  live in `CommandPalette+UI.swift`, extracted when this file reached 400 LOC.
//
//  Fuzzy match: a simple character-containment test (VS Code "fuzzy" style, not
//  edit-distance). Fast enough for the command count this app will ever have.
//

import AppKit

// MARK: - Data model

/// One entry in the command palette.
struct PaletteCommand {
    let title: String
    /// Display-only key equivalent (e.g. "⌘S", "⌘⇧P"). Never executed here.
    let keyHint: String
    /// The AppKit selector the palette sends through the responder chain.
    let action: Selector
    /// Optional NSMenuItem tag needed by `performFindPanelAction`.
    let tag: Int?

    init(_ title: String, key: String = "", action: Selector, tag: Int? = nil) {
        self.title = title
        self.keyHint = key
        self.action = action
        self.tag = tag
    }
}

// MARK: - Palette panel

/// The ⌘⇧P floating command palette.
///
/// Singleton: one panel, shared across Spaces. `toggle(targeting:)` shows or
/// hides it; `dismiss()` hides it and returns focus to the previous key window.
@MainActor
final class CommandPalette: NSObject {
    static let shared = CommandPalette()

    // MARK: Views

    // Internal (not private) so CommandPalette+UI.swift's NSWindowDelegate can access panel.
    var panel: NSPanel?
    private var searchField: NSSearchField?
    // Internal (not private) so CommandPalette+UI.swift's delegate methods can
    // read selectedRow and call selectRowIndexes — they are in a separate file
    // and Swift's `private` is file-scoped.
    var tableView: NSTableView?
    private var scrollView: NSScrollView?

    // The window that was key before the palette opened, so we can restore focus.
    private weak var previousKeyWindow: NSWindow?

    // MARK: State

    /// The full command list (static + dynamic). Rebuilt on each `toggle` so
    /// dynamic entries (open Spaces) are always fresh.
    private var all: [PaletteCommand] = CommandPalette.allCommands

    // Internal so the delegate methods in CommandPalette+UI.swift can read it.
    var filtered: [PaletteCommand] = []

    // MARK: Layout constants

    private static let panelWidth: CGFloat = 500
    private static let rowHeight: CGFloat = 36
    private static let maxVisibleRows = 8
    private static let searchFieldHeight: CGFloat = 44
    private static let cornerRadius: CGFloat = 10

    // MARK: - Public API

    /// Show or hide the palette inside `window`.
    func toggle(in window: NSWindow) {
        if let p = panel, p.isVisible {
            dismiss()
        } else {
            show(in: window)
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        previousKeyWindow?.makeKey()
    }

    // MARK: - Construction

    private func show(in window: NSWindow) {
        previousKeyWindow = window

        // Build the panel once; subsequent shows just reset query + reposition.
        if panel == nil { buildPanel() }
        // Rebuild command list so dynamic entries (open Spaces) are fresh.
        all = Self.allCommands + Self.spaceCommands()

        guard let p = panel, let sf = searchField, let tv = tableView else { return }

        // Reset state.
        sf.stringValue = ""
        applyFilter("")

        // Centre the panel over the host window, slightly above centre — the VS
        // Code / Xcode style that keeps results visible and the code readable.
        let wf = window.frame
        let panelHeight = Self.panelHeight(for: filtered.count)
        let origin = CGPoint(
            x: wf.midX - Self.panelWidth / 2,
            y: wf.midY + wf.height * 0.1)
        p.setContentSize(NSSize(width: Self.panelWidth, height: panelHeight))
        p.setFrameOrigin(origin)

        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(sf)
        tv.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func buildPanel() {
        // NSPanel floats above document windows without grabbing application focus
        // from the host window's responder chain for AppKit validation purposes.
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.delegate = self

        // Container with rounded corners and a blurred/glass background.
        // macOS 26+: NSGlassEffectView for the native Liquid Glass material.
        // Pre-26: NSVisualEffectView with .hudWindow, the standard HUD blur.
        let container: NSView
        if #available(macOS 26, *) {
            container = LiquidGlass.makeGlassContainer(
                frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
                cornerRadius: Self.cornerRadius)
        } else {
            let vev = NSVisualEffectView(
                frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300))
            vev.material = .hudWindow
            vev.blendingMode = .behindWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.cornerRadius = Self.cornerRadius
            vev.layer?.masksToBounds = true
            vev.autoresizingMask = [.width, .height]
            container = vev
        }
        p.contentView = container

        // Search field at the top.
        let sf = NSSearchField(frame: NSRect(
            x: 0, y: 0, width: Self.panelWidth, height: Self.searchFieldHeight))
        sf.placeholderString = "Run command…"
        sf.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        sf.controlSize = .large
        sf.focusRingType = .none
        sf.autoresizingMask = [.width, .maxYMargin]
        sf.translatesAutoresizingMaskIntoConstraints = false
        sf.target = self
        sf.action = #selector(searchFieldChanged(_:))
        sf.delegate = self
        container.addSubview(sf)
        searchField = sf

        // Table view for results (no header, single-column, no selection ring).
        let tv = NSTableView()
        tv.headerView = nil
        tv.rowHeight = Self.rowHeight
        tv.selectionHighlightStyle = .regular
        tv.backgroundColor = .clear
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.focusRingType = .none
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        col.isEditable = false
        tv.addTableColumn(col)
        tv.dataSource = self
        tv.delegate = self
        tv.doubleAction = #selector(commitSelection(_:))
        tv.target = self
        tv.allowsEmptySelection = false

        let sv = NSScrollView(frame: NSRect(
            x: 0, y: Self.searchFieldHeight,
            width: Self.panelWidth,
            height: 100))
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller = false
        sv.autoresizingMask = [.width, .height]
        container.addSubview(sv)

        // Pin search field with Auto Layout (table view uses autoresizing mask).
        NSLayoutConstraint.activate([
            sf.topAnchor.constraint(equalTo: container.topAnchor),
            sf.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            sf.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            sf.heightAnchor.constraint(equalToConstant: Self.searchFieldHeight),
        ])

        tableView = tv
        scrollView = sv
        self.panel = p
    }

    // MARK: - Filtering

    private func applyFilter(_ query: String) {
        if query.isEmpty {
            filtered = all
        } else {
            filtered = all.filter { fuzzyMatch(query.lowercased(), in: $0.title.lowercased()) }
        }
        tableView?.reloadData()

        // Resize panel to fit results.
        let newHeight = Self.panelHeight(for: filtered.count)
        if let p = panel {
            var f = p.frame
            let delta = newHeight - p.contentLayoutRect.height
            f.origin.y -= delta
            f.size.height += delta
            p.setFrame(f, display: true)
        }

        scrollView?.frame = NSRect(
            x: 0, y: Self.searchFieldHeight,
            width: Self.panelWidth,
            height: Self.panelHeight(for: filtered.count) - Self.searchFieldHeight)

        if !filtered.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Character-containment fuzzy match: every character of `query` must appear
    /// in `text` in order, but not necessarily consecutively.
    /// Fast enough for < 50 commands; edit-distance would be overkill.
    private func fuzzyMatch(_ query: String, in text: String) -> Bool {
        var ti = text.startIndex
        for qc in query {
            guard let found = text[ti...].firstIndex(of: qc) else { return false }
            ti = text.index(after: found)
        }
        return true
    }

    private static func panelHeight(for count: Int) -> CGFloat {
        let rows = min(count, maxVisibleRows)
        return searchFieldHeight + CGFloat(rows) * rowHeight
    }

    // MARK: - Execution

    @objc private func searchFieldChanged(_ sender: Any?) {
        applyFilter(searchField?.stringValue ?? "")
    }

    // Internal (not private) so CommandPalette+UI.swift's key-intercept can call it.
    @objc func commitSelection(_ sender: Any?) {
        let row = tableView?.selectedRow ?? -1
        guard row >= 0 && row < filtered.count else { return }
        execute(filtered[row])
    }

    private func execute(_ command: PaletteCommand) {
        dismiss()

        // If the command needs a tag (find-panel actions), build a dummy menu item
        // carrying that tag and send it — `performFindPanelAction` requires the
        // sender to be an NSMenuItem whose `.tag` it reads (`AppMenu.swift`, search
        // block comment for the full explanation).
        if let tag = command.tag {
            let item = NSMenuItem()
            item.tag = tag
            item.action = command.action
            NSApp.sendAction(command.action, to: nil, from: item)
        } else {
            NSApp.sendAction(command.action, to: nil, from: nil)
        }
    }
}

// Delegate conformances, PaletteRowView → CommandPalette+UI.swift
// allCommands → CommandPalette+Commands.swift
