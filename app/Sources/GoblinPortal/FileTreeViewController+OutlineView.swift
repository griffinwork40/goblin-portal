//
//  FileTreeViewController+OutlineView.swift
//  Everything AppKit asks the tree: the two `NSOutlineView` conformances and the
//  row view behind them.
//
//  Its own file because this is one concern with one reason to change — how a row
//  is answered for and drawn. It holds the data source's four callbacks, the
//  delegate's `viewFor`, and the cell machinery nothing else uses: `FileCellView`,
//  the SF Symbol table, the glyph cache, and the row's Auto Layout. It reaches
//  back into the controller for `root`, and — since the git sidebar landed — for
//  the current status snapshot, which it asks about per row rather than caching
//  anything on the node. What stays in `FileTreeViewController.swift` is the
//  controller's own job: building the outline and scroll view, the
//  identity-preserving `refresh()`, and double-click routing. The right-click menu
//  and the git poller each have their own file.
//

import AppKit

extension FileTreeViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(for: item).children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(for: item).children?[index] ?? root
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    /// Populate on demand. `numberOfChildrenOfItem` is asked about collapsed
    /// directories too, so loading there instead would walk the entire tree.
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if let node = item as? FileNode, node.children == nil { node.reloadChildren() }
        return true
    }

    private func node(for item: Any?) -> FileNode { (item as? FileNode) ?? root }
}

/// A source-list row whose glyph and text track the row's own state.
///
/// The tint has to be re-derived from `backgroundStyle` rather than assigned once
/// at build time: AppKit flips a selected row to `.emphasized` and expects the cell
/// to answer, and a fixed `contentTintColor` would leave a dim grey glyph stranded
/// inside the blue selection pill. `secondaryLabelColor` deliberately sits the icon
/// *below* the filename in the visual hierarchy — the name is what you read, the
/// glyph is what you skim.
@MainActor
private final class FileCellView: NSTableCellView {
    /// The git tint for this row, or nil when the file is clean. Stored rather than applied
    /// directly because the selection pill can arrive at any time and the answer has to be
    /// re-derivable: inside the pill, git colour must yield to the pill's own contrast
    /// colour or an orange filename on saturated blue becomes the least legible thing in
    /// the window. This is the same problem the icon already had, so it takes the same
    /// shape — one stored input, one `applyTint()` that owns the whole rule.
    var decorationColour: NSColor?

    /// The status letter, trailing-aligned. Its own control rather than a suffix on the
    /// filename: appended to `stringValue` it would be truncated away by
    /// `.byTruncatingMiddle` on exactly the long paths where a status matters most, and it
    /// would be read aloud as part of the name.
    let badge = NSTextField(labelWithString: "")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTint() }
    }

    /// Whether the index holds this change too — `GitFileEntry.isStaged`.
    ///
    /// Stored beside `decorationColour` and for the same reason: the selection pill can
    /// arrive at any time and `applyTint()` has to be able to re-derive the whole look
    /// from inputs rather than from whatever it drew last.
    var isStaged = false

    /// Held so the decoration can switch it on and off. An always-active minimum would
    /// reserve badge width on every clean row, which is exactly what `makeCell`'s layout
    /// comment says must not happen.
    var badgeMinWidth: NSLayoutConstraint?

    func applyTint() {
        let selected = backgroundStyle == .emphasized
        imageView?.contentTintColor =
            selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        // A clean row keeps `labelColor` — decoration is the exception, never the default,
        // so an unmodified tree looks precisely as it did before this feature landed.
        textField?.textColor =
            selected ? .alternateSelectedControlTextColor : (decorationColour ?? .labelColor)
        badge.textColor =
            selected ? .alternateSelectedControlTextColor : (decorationColour ?? .clear)

        // Staged rows get the letter in a soft chip of its own colour. A *translucent* fill
        // rather than a solid one so the letter can stay in the decoration colour and keep
        // its meaning: a solid fill would force the glyph to invert to the window
        // background, and then "staged" would be carrying two changes at once (a box AND a
        // recoloured letter) to say one thing.
        //
        // Derived from the same system colour as the text so it tracks the window's
        // appearance and Increase Contrast — but only because of the override below. A
        // `CGColor` is a colour already *resolved* against one appearance, unlike the
        // three `NSColor`s above, which AppKit re-resolves on every draw. Assigned and
        // then left alone, the chip would keep its old fill while the letter inside it
        // recoloured, and nothing else would come along to fix it: the poller repaints
        // only when the snapshot *changes* (`FileTreeViewController+Git.swift`, `guard
        // changed else { return }`), so a quiet repo holds the stale fill indefinitely.
        //
        // KNOWN GAP, matching the one the tint already has: the chip is dropped inside the
        // selection pill, because a tinted box on saturated blue is the least legible thing
        // in the window. Only one row is selected at a time, and that row's tooltip and
        // VoiceOver label both still say "staged", so the fact is reachable — it is the
        // *glance* that is unavailable, for the one row the user is already looking at.
        let chip = (isStaged && !selected) ? decorationColour : nil
        badge.layer?.backgroundColor = chip?.withAlphaComponent(0.18).cgColor ?? NSColor.clear.cgColor
    }

    /// Re-derive the chip when the window's appearance changes.
    ///
    /// This is what makes the "follows the appearance for free" claim above true. The
    /// text and glyph colours need no help — they hold their `NSColor`. The chip is a
    /// `CGColor` on a layer and is therefore the one mark in this cell that a Dark Mode
    /// or Increase Contrast switch would otherwise leave behind.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }
}

extension FileTreeViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        guard let node = item as? FileNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)

        cell.textField?.stringValue = node.name
        cell.imageView?.image = Self.symbol(named: Self.symbolName(for: node))
        applyGitDecoration(to: cell, for: node)
        return cell
    }

    /// Put this row's git status on the cell — or take it off.
    ///
    /// Called from two places, and the second is why this is a function rather than four
    /// lines inside `viewFor`: a new snapshot repaints realised rows through
    /// `gitStatusDidChange()` without rebuilding them, and one description of how a row
    /// looks is the only way those two paths cannot drift apart.
    ///
    /// **It must always write, never only when there is a status.** Cells are recycled by
    /// `makeView(withIdentifier:)`, so a clean file scrolling into the cell a modified one
    /// just vacated inherits its orange text and its `M` unless the nil case is written
    /// too. That is the whole class of bug behind "the sidebar shows the wrong status",
    /// and it is invisible until you scroll.
    func applyGitDecoration(to cell: NSTableCellView, for node: FileNode) {
        let status = gitStatus(for: node)
        // Nil for a clean row and for every directory — a roll-up has no single entry to
        // describe, so folders keep the plain status wording they already had.
        let entry = gitEntry(for: node)
        if let view = cell as? FileCellView {
            view.decorationColour = status?.decorationColour
            view.badge.stringValue = status?.letter ?? ""
            view.isStaged = entry?.isStaged ?? false
            // Only widen the badge when it has something in it: the empty badge's
            // zero intrinsic width is what lets a clean row's name run the full width of
            // the sidebar, which the layout comment in `makeCell` is explicit about.
            view.badgeMinWidth?.isActive = status != nil
            view.applyTint()
        }
        // The tooltip is the only channel with room for a rename's origin, and it is
        // written on every pass — including the nil case — for the same reason the tint is:
        // cells are recycled, so a clean file scrolling into a renamed file's cell would
        // otherwise inherit "Renamed, from …" and describe the wrong file.
        cell.toolTip = entry?.tooltip
        // VoiceOver reads the cell, not its subviews, so the status has to join the name
        // here or it is announced as a bare letter after it — or not at all. A file uses
        // the entry's fuller sentence; a directory falls back to its rolled-up status.
        let phrase = entry?.statusPhrase ?? status?.accessibilityDescription
        cell.setAccessibilityLabel(phrase.map { "\(node.name), \($0)" } ?? node.name)
    }

    /// SF Symbols rather than `NSWorkspace.icon(forFile:)`.
    ///
    /// Finder's icons are full-colour raster art. Measured against the now-dark
    /// tree they were 5.4% of the sidebar's pixels in saturated blue, competing
    /// for attention with the filenames they exist to label — and they are the one
    /// thing in the sidebar that cannot follow the window's appearance, because a
    /// baked bitmap has no template to tint. Xcode's navigator, VS Code and Zed all
    /// draw monochrome glyphs here for the same reason.
    ///
    /// Deliberately coarse: enough shape variety to scan a directory by, not a
    /// per-language icon set to maintain. Dotfiles get their own glyph because this
    /// tree shows them on purpose (see `FileNode.isVisible`), so they are a category
    /// a developer actually looks for rather than noise to hide.
    private static func symbolName(for node: FileNode) -> String {
        if node.isDirectory { return "folder.fill" }
        switch node.url.pathExtension.lowercased() {
        case "swift", "c", "h", "m", "mm", "cpp", "py", "js", "ts", "tsx", "jsx", "rs", "go",
            "rb", "java", "kt", "lua", "pl", "php", "cs":
            return "curlybraces"
        case "json", "yml", "yaml", "toml", "plist", "xml", "lock", "cfg", "conf", "ini", "env":
            return "list.bullet.rectangle"
        case "md", "markdown", "txt", "rst", "adoc", "log":
            return "doc.text"
        case "sh", "bash", "zsh", "fish", "command":
            return "terminal"
        case "png", "jpg", "jpeg", "gif", "svg", "icns", "webp", "heic", "pdf":
            return "photo"
        default:
            return node.name.hasPrefix(".") ? "gearshape" : "doc"
        }
    }

    /// Cached because `viewFor` runs on every row recycle during a scroll, and the
    /// call this replaced (`NSWorkspace.icon(forFile:)`) hit icon services on each
    /// one. There are a dozen distinct glyphs for any tree, so the cache is bounded
    /// by the table above, not by the number of files.
    private static var symbolCache: [String: NSImage] = [:]

    private static func symbol(named name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        else { return nil }
        // Template is what lets `contentTintColor` apply at all — see `FileCellView`.
        image.isTemplate = true
        symbolCache[name] = image
        return image
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = FileCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingMiddle

        // Bold and a point smaller: at 12pt regular the letter reads as another character
        // of the filename, which is the one thing it must not do.
        let badge = cell.badge
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .boldSystemFont(ofSize: 11)
        badge.alignment = .center
        // The chip's frame, set once. Only its *fill* is per-row, and that is
        // `applyTint`'s job — these two never change, so re-assigning them on every
        // selection change and every decoration pass was work with no output.
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.addSubview(badge)
        cell.imageView = imageView
        cell.textField = textField

        // The badge must never be the thing that gives way: a filename truncating is a
        // cosmetic loss in a narrow sidebar, a status silently vanishing is a correctness
        // one. So it resists compression and the name — already `.byTruncatingMiddle` —
        // absorbs the squeeze instead.
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            // Between the name and the trailing edge. An empty badge has no intrinsic
            // width, so a clean row's name reaches exactly as far as it did before.
            badge.leadingAnchor.constraint(
                equalTo: textField.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        // Enough width for the staged chip to sit around a single character instead of
        // hugging it — and switched on for *every* decorated row, not only staged ones,
        // so the letter column holds one width instead of jittering by 8pt as a staged
        // file scrolls past. Deliberately created inactive and toggled per row by
        // `applyGitDecoration`: active here it would reserve the width on clean rows too,
        // undoing the zero-intrinsic-width property the constraint above depends on.
        cell.badgeMinWidth = badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16)
        // Seed the tint: `backgroundStyle` only fires its observer on a *change*,
        // so an unselected row built fresh would otherwise draw an untinted glyph.
        cell.applyTint()
        return cell
    }
}
