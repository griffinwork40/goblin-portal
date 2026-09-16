//
//  DocumentTabStrip+Mouse.swift
//  Tracking areas, hover state, and the three buttons' worth of clicking: select,
//  close, new document, overflow menu, and middle-click-to-close.
//
//  Its own file because this is the only concern that WRITES strip state. Hover is
//  the strip's sole piece of transient, event-driven state, and `mouseDown` /
//  `otherMouseUp` are the only paths that reach the delegate for the mouse. Keeping
//  them together means the answer to "what can change this view without the owner
//  asking?" is one file, and it is why drawing and the accessibility tree can be
//  read as strictly-reading siblings.
//
//  Hit-testing derives every rect from the same `layout`, `tabRect`, `closeRect`,
//  `newButtonRect` and `overflowButtonRect` that drawing uses — the invariant the
//  core file's "MARK: - Geometry" note argues for. No rect is recomputed here.
//
//  `showOverflowMenu` lives here rather than with drawing because it is an input
//  affordance, not a paint: `drawOverflowButton` draws the chevron, and this builds
//  the menu the chevron opens. The accessibility tree reaches it through
//  `accessibilityShowOverflowMenu`, which is why it is internal rather than private.
//

import AppKit

extension DocumentTabStrip {
    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = self.layout
        let tab = tabIndex(at: point, layout)
        let close = tab.flatMap { index -> Int? in
            guard let rect = tabRect(index, layout) else { return nil }
            return closeRect(rect).contains(point) ? index : nil
        }
        let newButton = newButtonRect(layout).contains(point)
        let overflow = overflowButtonRect(layout)?.contains(point) ?? false
        // Only repaint on an actual state change: mouseMoved fires continuously,
        // and the terminal underneath deserves the frames more than this rail does.
        guard tab != hoveredTab || close != hoveredClose || newButton != isHoveringNewButton
            || overflow != isHoveringOverflowButton
        else { return }
        hoveredTab = tab
        hoveredClose = close
        isHoveringNewButton = newButton
        isHoveringOverflowButton = overflow
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTab = nil
        hoveredClose = nil
        isHoveringNewButton = false
        isHoveringOverflowButton = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = self.layout
        if newButtonRect(layout).contains(point) {
            delegate?.tabStripDidRequestNewDocument(self)
            return
        }
        // Tested before tabs: the chevron is pinned to the right edge and the last
        // visible tab ends exactly where it starts, so a hit here is unambiguous.
        if let overflow = overflowButtonRect(layout), overflow.contains(point) {
            showOverflowMenu(from: overflow)
            return
        }
        guard let index = tabIndex(at: point, layout), let rect = tabRect(index, layout) else {
            return
        }
        // Close wins over select: the × sits inside the tab's own rect, so testing
        // it second would select the tab and never close it.
        if (index == activeIndex || hoveredTab == index), closeRect(rect).contains(point) {
            delegate?.tabStrip(self, didRequestClose: index)
        } else {
            delegate?.tabStrip(self, didSelect: index)
        }
    }

    /// Middle-click closes the tab under the cursor — the convention in every tabbed
    /// browser and in Ghostty/iTerm2, and nearly free here because `tabIndex(at:)`
    /// already resolves a point to an index for the left button.
    ///
    /// The index is captured on *down* and the close is issued on *up*, matching how
    /// a button behaves: pressing the middle button over a tab and releasing it
    /// elsewhere must not close anything, and `documentShouldClose()` in
    /// `SpaceViewController.closeDocument` may put up an unsaved-changes sheet — a
    /// sheet raised from a mouse-down while the button is still held is how you get a
    /// modal that swallows the matching mouse-up.
    ///
    /// Deliberately ignores `closeRect`: the whole tab is the target, so there is no
    /// select-versus-close ambiguity for this button and no reason to make the user
    /// aim at a 15pt box. Also ignores the "+" and the chevron, which have no
    /// middle-click meaning.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            // Anything past the middle button (thumb buttons, gesture-mapped extras)
            // is left to the responder chain rather than silently closing documents.
            super.otherMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        middleClickCandidate = tabIndex(at: point, layout)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        let candidate = middleClickCandidate
        // Cleared unconditionally, including on the miss paths below: a stale
        // candidate surviving to the next middle-click would close a tab the user
        // never pressed on.
        middleClickCandidate = nil
        let point = convert(event.locationInWindow, from: nil)
        guard let index = candidate, tabIndex(at: point, layout) == index else { return }
        // Re-checked against `items` because the strip can be reloaded between the
        // down and the up (a shell can exit on its own and `SpaceViewController`
        // removes the document), and `didRequestClose` is index-based.
        guard items.indices.contains(index) else { return }
        delegate?.tabStrip(self, didRequestClose: index)
    }

    /// Every document, hidden ones included, as a menu. This is the affordance that
    /// makes the overflow strategy safe: whatever the window is showing, one click
    /// reaches any document. Built fresh on each click because `items` is replaced
    /// wholesale by `reload` and a cached menu would go stale silently.
    // why internal, not `private`: `accessibilityShowOverflowMenu` in
    // `DocumentTabStrip+Accessibility.swift` opens the same menu, so VoiceOver and the
    // mouse reach ONE builder rather than each assembling a list that could disagree
    // about which documents exist.
    func showOverflowMenu(from rect: NSRect) {
        let menu = NSMenu()
        for index in items.indices {
            let entry = NSMenuItem(
                title: item(index).title, action: #selector(overflowMenuDidPick(_:)),
                keyEquivalent: "")
            entry.target = self
            entry.tag = index
            // `.on` rather than a custom glyph so VoiceOver and the menu's own
            // drawing both report the selection without extra work.
            entry.state = index == activeIndex ? .on : .off
            entry.image = NSImage(
                systemSymbolName: item(index).symbolName, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        // Anchored under the chevron so the menu visually belongs to the button that
        // opened it; `nil` event means AppKit synthesises the tracking for us.
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: self)
    }

    @objc private func overflowMenuDidPick(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        delegate?.tabStrip(self, didSelect: sender.tag)
    }
}
