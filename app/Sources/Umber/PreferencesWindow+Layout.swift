//
//  PreferencesWindow+Layout.swift
//  Form layout for the preferences window.
//
//  Extracted from PreferencesWindow.swift to keep both files under the
//  350-LOC ceiling.  This extension owns the visual construction of the
//  settings panel: section headers, label-control rows, and the footer bar.
//  All mutation of control STATE (loading from JSON, writing back) stays in
//  PreferencesWindow.swift.
//

import AppKit

extension PreferencesWindow {

    // MARK: - Entry point (called from PreferencesWindow.init)

    func setupUI() {
        guard let contentView = window?.contentView else { return }

        // — Appearance section —
        let themeRow      = makeRow(label: "Theme:",       control: themePopup)
        let familyRow     = makeRow(label: "Font Family:", control: fontFamilyPopup)
        let sizeRow       = makeRow(label: "Font Size:",   control: makeSizeContainer())
        let cursorRow     = makeRow(label: "Cursor:",      control: cursorPopup)
        let rendererRow   = makeRow(label: "Renderer:",    control: rendererPopup)
        let thickenRow    = makeRow(label: "",             control: fontThickenCheck)

        // — Terminal section —
        let scrollbackRow = makeRow(label: "Scrollback:",  control: makeScrollbackContainer())
        let metaRow       = makeRow(label: "",             control: optionAsMetaCheck)

        // Fill in popup items now that the controls exist.
        populatePopups()

        // Main stack — vertical, full-width rows.
        let stack = NSStackView(views: [
            makeSectionHeader("Appearance"),
            themeRow, familyRow, sizeRow, cursorRow, rendererRow, thickenRow,
            makeSectionHeader("Terminal"),
            scrollbackRow, metaRow,
        ])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.distribution = .fill
        stack.spacing     = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        // Footer: "Open config.json" on the left, "Apply" on the right.
        let openButton  = makeButton("Open config.json", action: #selector(openConfigFile(_:)))
        let applyButton = makeButton("Apply",            action: #selector(saveValues))
        applyButton.keyEquivalent = "\r"  // Return confirms

        let footer = NSStackView(views: [openButton, NSView(), applyButton])
        footer.orientation  = .horizontal
        footer.distribution = .fill
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(footer)

        // Layout
        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),

            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -pad),
            footer.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // MARK: - Popup population

    private func populatePopups() {
        // Theme
        themePopup.removeAllItems()
        themePopup.addItems(withTitles: themePresets)

        // Font family — system default first, then every installed monospaced face.
        fontFamilyPopup.removeAllItems()
        fontFamilyPopup.addItem(withTitle: "SF Mono (System Default)")
        let manager = NSFontManager.shared
        let monoFamilies = (manager.availableFontFamilies)
            .filter { family in
                // Collect traits for the first member of each family.
                guard let members = manager.availableMembers(ofFontFamily: family),
                      let first  = members.first,
                      let traits = first[3] as? UInt
                else { return false }
                // NSFontMonoSpaceTrait = 1024 (0x400).
                return (traits & NSFontTraitMask.fixedPitchFontMask.rawValue) != 0
            }
            .sorted()
        fontFamilyPopup.addItems(withTitles: monoFamilies)

        // Cursor
        cursorPopup.removeAllItems()
        cursorPopup.addItems(withTitles: cursorStyleKeys)

        // Renderer
        rendererPopup.removeAllItems()
        rendererPopup.addItems(withTitles: ["coretext", "metal"])
    }

    // MARK: - Factory helpers

    /// A horizontal stack that pairs a right-aligned 120pt label with a control.
    /// The control expands to fill the remaining width via a hugging-priority drop.
    func makeRow(label: String, control: NSView) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.alignment = .right
        lbl.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        lbl.widthAnchor.constraint(equalToConstant: 120).isActive = true

        control.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [lbl, control])
        row.orientation  = .horizontal
        row.alignment    = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Bold label acting as a visual section divider.
    private func makeSectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        // Add a small top margin between sections; handled by the stack spacing + this.
        label.translatesAutoresizingMaskIntoConstraints = false
        // Wrap in a container so we can add leading indent matching the rows above.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 128),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    /// Font-size field — fixed 60pt wide, with a "pt" suffix label.
    private func makeSizeContainer() -> NSView {
        fontSizeField.placeholderString = "14"
        fontSizeField.formatter = {
            let f = NumberFormatter()
            f.numberStyle = .none
            f.minimum = NSNumber(value: AppConfig.minFontSize)
            f.maximum = NSNumber(value: AppConfig.maxFontSize)
            return f
        }()
        fontSizeField.translatesAutoresizingMaskIntoConstraints = false
        fontSizeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        fontSizeField.target = self
        fontSizeField.action = #selector(saveValues)

        let suffix = NSTextField(labelWithString: "pt")
        let row = NSStackView(views: [fontSizeField, suffix])
        row.orientation = .horizontal
        row.alignment   = .centerY
        row.spacing     = 4
        return row
    }

    /// Scrollback field — fixed 80pt wide, with a "lines" suffix label.
    private func makeScrollbackContainer() -> NSView {
        scrollbackField.placeholderString = "1000"
        scrollbackField.formatter = {
            let f = NumberFormatter()
            f.numberStyle = .none
            f.minimum = 0
            f.maximum = 100_000
            return f
        }()
        scrollbackField.translatesAutoresizingMaskIntoConstraints = false
        scrollbackField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        scrollbackField.target = self
        scrollbackField.action = #selector(saveValues)

        let suffix = NSTextField(labelWithString: "lines")
        let row = NSStackView(views: [scrollbackField, suffix])
        row.orientation = .horizontal
        row.alignment   = .centerY
        row.spacing     = 4
        return row
    }

    /// Plain push-button wired to the given selector on self.
    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        return btn
    }
}
