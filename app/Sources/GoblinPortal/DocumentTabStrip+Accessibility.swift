//
//  DocumentTabStrip+Accessibility.swift
//  The strip's accessibility tree: the tab-group overrides, the per-tab and per-button
//  proxy elements, and the actions they route back to the strip.
//
//  Its own file because this is the bill for hand-rolling the document tab level — a
//  whole parallel presentation of the same layout, for a client that cannot see the
//  drawing (the MARK note below argues it in full). It reads exactly what drawing
//  reads (`item(_:)`, `activeIndex`, `tabRect`, `newButtonRect`, `overflowButtonRect`)
//  and writes nothing, so the spoken strip and the drawn strip cannot disagree about
//  which tabs exist or where they are.
//
//  `TabProxy` and `ActionProxy` live here rather than beside the class they report
//  for: they exist only to be handed to an assistive client by `accessibilityChildren`,
//  they are useless to any other concern, and reading this file top to bottom is the
//  complete story of what VoiceOver sees. They are `private` to this file, which is
//  what keeps them from being mistaken for real subviews elsewhere.
//

import AppKit

extension DocumentTabStrip {
    // MARK: - Accessibility
    //
    // This is the bill for hand-rolling the document tab level (see the file header:
    // native window tabs were spent on Spaces, so they were not available here).
    // Native NSTabView / NSWindow tabs ship their accessibility tree for free; a
    // single NSView with `draw(_:)` and rect hit-testing ships *nothing* — before
    // this, VoiceOver saw one unlabelled group with no tabs, no titles, no selection
    // and no close buttons, and there was no way to reach a document without a mouse
    // or the ⌘1–9 chords in `KeyBindings.swift`.
    //
    // Modelled as a tab group whose children are radio-button-role tabs, which is the
    // shape AppKit's own NSTabView reports and therefore the one VoiceOver already
    // knows how to narrate ("tab 2 of 5, selected"). The children are proxy elements
    // (`NSAccessibilityElement`) rather than real subviews on purpose: adding per-tab
    // subviews is exactly the teardown churn the file header rejects, since the shell
    // rewrites titles constantly via OSC 0/2.
    //
    // Only the *visible* window of tabs gets a child element, matching what the
    // overflow layout actually presents; the documents the window is not showing are
    // reachable through the overflow chevron's own menu, which AppKit makes
    // accessible for free (NSMenu is a real menu, and the picked item carries
    // `.on` state).

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }

    override func accessibilityLabel() -> String? { "Document tabs" }

    /// The active document's title, so a VoiceOver user who lands on the group hears
    /// what is selected without having to walk into the children.
    override func accessibilityValue() -> Any? {
        guard items.indices.contains(activeIndex) else { return nil }
        return item(activeIndex).title
    }

    override func accessibilityChildren() -> [Any]? {
        let layout = self.layout
        var children: [Any] = layout.visible.compactMap { tabElement($0, layout) }
        if let overflow = overflowButtonRect(layout) {
            children.append(
                buttonElement(
                    rect: overflow, label: "All documents",
                    help: "Shows every open document, including tabs that do not fit.",
                    action: #selector(accessibilityShowOverflowMenu)))
        }
        children.append(
            buttonElement(
                rect: newButtonRect(layout), label: "New document",
                help: "Opens a new terminal in this Space.",
                action: #selector(accessibilityRequestNewDocument)))
        return children
    }

    /// Rebuilt on demand rather than cached: `reload` swaps `items` wholesale and the
    /// layout window follows `activeIndex`, so a cached tree would go stale on every
    /// selection change and every title repaint. Cheap — the strip holds a handful of
    /// tabs, and AppKit only asks while an assistive client is actually attached.
    private func tabElement(_ index: Int, _ layout: Layout) -> NSAccessibilityElement? {
        guard let rect = tabRect(index, layout) else { return nil }
        let element = TabProxy()
        element.strip = self
        element.index = index
        element.setAccessibilityRole(.radioButton)
        // `.radioButton` inside a `.tabGroup` is the NSTabView shape: subrole
        // `.tabButtonSubrole` is what makes VoiceOver say "tab" and announce the
        // "n of m" position instead of reading it as a lone radio button.
        element.setAccessibilitySubrole(.tabButtonSubrole)
        // Status rides in the LABEL, not the help or the value. The value slot is
        // spoken for by the selection state the radio-button role requires (below), and
        // help is announced late and can be suppressed — a tab that is blocked on input
        // has to be heard on the same breath as its title. Which is the point: the
        // coloured dot in `drawTab` is the visual channel and this is the spoken one,
        // so the single shared affordance is never colour-only information.
        //
        // Appended to the existing label rather than vended as a new child element:
        // the tree this joins is already the NSTabView shape VoiceOver knows how to
        // narrate, and a parallel status element would be a second thing to walk past.
        if let spoken = item(index).status.accessibilityDescription {
            element.setAccessibilityLabel("\(item(index).title), \(spoken)")
        } else {
            element.setAccessibilityLabel(item(index).title)
        }
        // Value carries selection because that is where AXRadioButton publishes it;
        // `setAccessibilitySelected` alone is not narrated on this role.
        element.setAccessibilityValue(index == activeIndex ? 1 : 0)
        element.setAccessibilitySelected(index == activeIndex)
        if item(index).isEdited {
            // The unsaved dot in `drawTab` is purely visual, so it is invisible to
            // VoiceOver unless it is said out loud somewhere. Help rather than the
            // label because, unlike a status, unsaved work is not time-sensitive —
            // the same ranking `drawTab` applies when the two contend for the box.
            element.setAccessibilityHelp("Has unsaved changes.")
        }
        element.setAccessibilityParent(self)
        element.setAccessibilityFrameInParentSpace(rect)
        return element
    }

    private func buttonElement(
        rect: NSRect, label: String, help: String, action: Selector
    ) -> NSAccessibilityElement {
        let element = ActionProxy()
        element.strip = self
        element.pressAction = action
        element.setAccessibilityRole(.button)
        element.setAccessibilityLabel(label)
        element.setAccessibilityHelp(help)
        element.setAccessibilityParent(self)
        element.setAccessibilityFrameInParentSpace(rect)
        return element
    }

    // Targets for the proxy elements' actions. They live on the strip rather than on
    // the proxies so the proxies stay dumb rects and there is one place that talks to
    // the delegate — the same reasoning as `mouseDown` being the only mouse path.

    fileprivate func accessibilitySelectTab(_ index: Int) {
        guard items.indices.contains(index) else { return }
        delegate?.tabStrip(self, didSelect: index)
    }

    fileprivate func accessibilityCloseTab(_ index: Int) {
        guard items.indices.contains(index) else { return }
        delegate?.tabStrip(self, didRequestClose: index)
    }

    @objc fileprivate func accessibilityRequestNewDocument() {
        delegate?.tabStripDidRequestNewDocument(self)
    }

    @objc fileprivate func accessibilityShowOverflowMenu() {
        guard let rect = overflowButtonRect(layout) else { return }
        showOverflowMenu(from: rect)
    }
}

// MARK: - Accessibility elements

/// One tab, as far as an assistive client is concerned. Holds only an index and a
/// weak strip reference; every question about geometry or state is answered by the
/// strip, so there is no second copy of the layout to disagree with `draw`.
@MainActor
private final class TabProxy: NSAccessibilityElement {
    weak var strip: DocumentTabStrip?
    var index: Int = 0

    /// `accessibilityPerformPress` is what VoiceOver's ⌃⌥space and Full Keyboard
    /// Access both route to, so select has to be press — not a custom action.
    ///
    /// `NSAccessibilityElement`'s action methods are not `@MainActor` in the SDK, so
    /// under Swift 6 the override is nonisolated and cannot touch this type's stored
    /// properties directly. `assumeIsolated` rather than a hop: AppKit dispatches
    /// accessibility actions on the main thread, and hopping would make the return
    /// value a lie — the client reads `Bool` synchronously to decide whether to
    /// announce the action as performed.
    override nonisolated func accessibilityPerformPress() -> Bool {
        // `nonisolated(unsafe) let` on the self copy is what lets a non-Sendable
        // element cross into the closure: without it Swift 6 region isolation reports
        // "sending 'self' risks causing data races". Safe here for the reason above —
        // the only caller is AppKit's accessibility dispatch, which is main-thread.
        nonisolated(unsafe) let element = self
        return MainActor.assumeIsolated {
            guard let strip = element.strip else { return false }
            strip.accessibilitySelectTab(element.index)
            return true
        }
    }

    /// Close is exposed as the standard "delete" action rather than a bespoke one:
    /// VoiceOver offers it in the actions menu (⌃⌥⌘space) with wording the user has
    /// already learned elsewhere, and Safari's tabs use the same mapping.
    override nonisolated func accessibilityPerformDelete() -> Bool {
        nonisolated(unsafe) let element = self
        return MainActor.assumeIsolated {
            guard let strip = element.strip else { return false }
            strip.accessibilityCloseTab(element.index)
            return true
        }
    }
}

/// The "+" and the overflow chevron. Same proxy trick as `TabProxy`, but the press
/// target is a selector on the strip because these two do not carry an index.
@MainActor
private final class ActionProxy: NSAccessibilityElement {
    weak var strip: DocumentTabStrip?
    var pressAction: Selector?

    /// Nonisolated + `assumeIsolated` for the same reason as `TabProxy`'s overrides.
    override nonisolated func accessibilityPerformPress() -> Bool {
        nonisolated(unsafe) let element = self
        return MainActor.assumeIsolated {
            guard let strip = element.strip, let action = element.pressAction else {
                return false
            }
            // `perform(_:)` rather than a stored closure: a closure capturing the
            // strip would need `@Sendable` reasoning, and AFK.md's conventions rule
            // out adding `Sendable` annotations to this codebase.
            strip.perform(action)
            return true
        }
    }
}
