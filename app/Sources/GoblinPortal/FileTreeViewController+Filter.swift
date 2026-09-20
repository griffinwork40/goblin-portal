//
//  FileTreeViewController+Filter.swift
//  Sidebar filter field: type to narrow the tree to matching files.
//
//  Separate from the main controller because it owns a whole sub-concern: the
//  NSSearchField, the filter state machine, and the filtered-children queries the
//  data source delegates to. Keeping it here means `FileTreeViewController.swift`
//  stays focused on the controller itself, and `+OutlineView.swift` stays focused on
//  how a row is answered for and drawn.
//
//  Design: the controller holds a `filterQuery` string (empty = no filter) and a
//  `visibleURLs: Set<URL>?` (nil = no filter, non-nil = the accepted set). The data
//  source asks `filteredChildren(of:)` instead of `node.children` directly, so every
//  filtering decision lives here, not scattered across the data source callbacks.
//
//  Filtering is substring, case-insensitive, applied to `node.name`. When a file
//  matches, every ancestor directory is kept too (ancestry walk). All matching
//  directories are auto-expanded so the results are visible without manual disclosure.
//

import AppKit

// MARK: - Filter field

extension FileTreeViewController {

    /// Build the search field and splice it into the sidebar stack between
    /// `gitHeader` and `scrollView`. Called once from `loadView()`.
    func addFilterField(to stack: NSStackView) {
        filterField.placeholderString = "Filter files…"
        filterField.font = .systemFont(ofSize: 11)
        // `.roundedBezel` with a border-less cell gives the field the small,
        // recessed look native to macOS sidebar search fields (used in Finder's
        // sidebar filter, Xcode's navigator filter, etc.) without the thick stroke
        // that `NSTextFieldSquareBezel` adds.
        filterField.bezelStyle = .roundedBezel
        filterField.controlSize = .small
        filterField.delegate = self
        // The field hugs its intrinsic height; the scroll view absorbs the rest.
        filterField.setContentHuggingPriority(.required, for: .vertical)
        // Insert between header and scroll view. `addArrangedSubview` appends, so
        // splice by index. `stack.arrangedSubviews` at this point is [gitHeader,
        // scrollView]; we want [gitHeader, filterField, scrollView].
        stack.insertArrangedSubview(filterField, at: 1)
        // Small top/bottom spacing so the field doesn't crowd the branch header or the tree.
        stack.setCustomSpacing(4, after: gitHeader)
        stack.setCustomSpacing(4, after: filterField)
    }

    // MARK: - Escape / clear

    /// Intercept Escape in the filter field: clear the query and return focus to
    /// the outline view so keyboard navigation continues without a stray click.
    override func cancelOperation(_ sender: Any?) {
        guard filterField.window?.firstResponder === filterField.currentEditor() else {
            // Not our field — let AppKit handle normally.
            super.cancelOperation(sender)
            return
        }
        filterField.stringValue = ""
        applyFilter("")
        view.window?.makeFirstResponder(outlineView)
    }
}

// MARK: - NSSearchFieldDelegate / NSControlTextEditingDelegate

extension FileTreeViewController: NSSearchFieldDelegate {
    // `controlTextDidChange` fires on every keystroke. Substring filtering is fast
    // enough for typical project sizes (hundreds to low thousands of files) so we
    // apply immediately without debounce.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === filterField else { return }
        applyFilter(field.stringValue)
    }
}

// MARK: - Filter state

extension FileTreeViewController {

    /// Update `filterQuery` / `visibleURLs`, reload the outline, and expand all
    /// matching directories. Called on every keystroke and on Escape.
    func applyFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let wasFiltered = !filterQuery.isEmpty
        filterQuery = trimmed

        if trimmed.isEmpty {
            // Filter cleared — restore the pre-filter expansion state if we have
            // one, so the tree looks exactly as it did before the user started
            // typing. `reloadData` collapses everything, so restore runs after.
            visibleURLs = nil
            outlineView.reloadData()
            if let saved = preFilterExpansion {
                for node in saved { outlineView.expandItem(node) }
                preFilterExpansion = nil
            }
            return
        }

        // Going from no filter to a filter: snapshot which directories are
        // currently expanded so we can put them back when the filter is cleared.
        if !wasFiltered {
            preFilterExpansion = (0..<outlineView.numberOfRows)
                .compactMap { outlineView.item(atRow: $0) as? FileNode }
                .filter { outlineView.isItemExpanded($0) }
        }

        // Walk the whole tree to build the accepted URL set: every matching leaf
        // plus every ancestor that contains at least one match.
        var accepted = Set<URL>()
        collectVisible(node: root, query: trimmed, into: &accepted)
        visibleURLs = accepted

        outlineView.reloadData()

        // Expand every directory in the accepted set so matches are visible without
        // manual disclosure. `reloadData` collapses the tree, so this runs after.
        expandMatchingDirectories(accepted)
    }

    /// Recursively collect URLs of nodes that match or that have a matching
    /// descendant. Returns true when this node or any descendant matched, so the
    /// caller can include the current directory node.
    @discardableResult
    private func collectVisible(node: FileNode, query: String, into set: inout Set<URL>) -> Bool {
        if node.isDirectory {
            // Ensure children are loaded — the filter needs to walk the full tree,
            // including directories the user has never manually opened.
            if node.children == nil { node.reloadChildren() }
            var anyChildMatched = false
            for child in node.children ?? [] {
                if collectVisible(node: child, query: query, into: &set) {
                    anyChildMatched = true
                }
            }
            if anyChildMatched {
                set.insert(node.url)
            }
            return anyChildMatched
        } else {
            // Leaf: match by name, case-insensitive substring.
            let matched = node.name.localizedCaseInsensitiveContains(query)
            if matched { set.insert(node.url) }
            return matched
        }
    }

    /// Expand every directory node whose URL is in `accepted`. The outline view
    /// must have been reloaded first so item rows are present.
    private func expandMatchingDirectories(_ accepted: Set<URL>) {
        func expandNode(_ node: FileNode) {
            guard node.isDirectory, accepted.contains(node.url) else { return }
            outlineView.expandItem(node)
            for child in node.children ?? [] where child.isDirectory {
                expandNode(child)
            }
        }
        expandNode(root)
    }
}

// MARK: - Filtered children query

extension FileTreeViewController {

    /// The children the data source should vend for `node`. Returns the full
    /// `children` array when no filter is active; returns only the subset whose
    /// URL is in `visibleURLs` when a filter is active.
    ///
    /// This is the single point of truth for "which nodes are visible right now",
    /// keeping `FileNode` pure and the data source callbacks simple.
    func filteredChildren(of node: FileNode) -> [FileNode] {
        guard let visible = visibleURLs else {
            // No filter — all children, same as before.
            return node.children ?? []
        }
        return (node.children ?? []).filter { visible.contains($0.url) }
    }
}
