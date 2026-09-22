//
//  DiffViewerPane+Document.swift
//  `SpaceDocument` conformance for the diff viewer tab.
//
//  Follows the exact shape of `FileViewerPane+Document.swift`: all required
//  protocol members are listed explicitly here with no default-implementation
//  free rides. The comment beside `documentWillClose()` states the honest
//  answer — "nothing to release" — rather than leaving a blank method.
//
//  Font zoom follows the `FontZoom.override` pattern: ⌘+ / ⌘- / ⌘0 write to
//  the shared override so newly-opened tabs open at the same size, and
//  `apply(config:)` honours an already-live override exactly as `FileViewerPane`
//  does. The size is clamped to `[minFontSize, maxFontSize]` in `setFontSize`.
//

import AppKit

extension DiffViewerPane: SpaceDocument {
    // MARK: - Identity

    var documentView: NSView { containerView }

    /// Last component of the file path, suffixed to make diff tabs distinct from
    /// an open editor showing the same file in an adjacent tab.
    var documentTitle: String {
        let name = (filePath as NSString).lastPathComponent
        return "\(name) (Diff)"
    }

    /// SF Symbol chosen to distinguish diff tabs from terminals ("terminal") and
    /// file viewers ("doc.text") at tab size.
    var documentSymbolName: String { "plus.forwardslash.minus" }

    // MARK: - Focus

    /// Give the right text view first-responder status — ⌘C, ⌘F, and arrow-key
    /// scrolling all work without a stray click. Right side is preferred because
    /// "new content" is what the user came to read.
    func documentDidBecomeActive() {
        rightTextView.window?.makeFirstResponder(rightTextView)
    }

    // MARK: - Configuration

    /// Push a new (or reloaded) config into both text views and the header.
    ///
    /// `apply(config:)` deliberately re-renders the whole diff — a theme change
    /// means every line's background colour must be recomputed, and there is no
    /// incremental path shorter than a full re-render. The diff data is not
    /// cached (it may be megabytes), so we re-spawn the diff process instead of
    /// keeping an in-memory copy. The re-spawn is on a background queue and
    /// writes back to main, identical to the original `loadDiff()` call.
    func apply(config: AppConfig) {
        self.config = config
        applyTheme()
        // Re-resolve: editing font.size + ⌘R should take effect here exactly as it
        // does in a terminal. A live ⌘+ zoom still outranks the config value.
        setFontSize(FontZoom.override ?? config.font.pointSize, persist: false)
        // Full re-render so diff line colours pick up the new theme palette.
        loadDiff()
    }

    // MARK: - Font zoom

    var currentFontSize: CGFloat { fontSize }

    /// Clamp, store, and apply the new size to both text views.
    ///
    /// `persist: false` is for apply(config:) and zoom-mirroring across tabs;
    /// only a direct user gesture (⌘+ / ⌘-) should write `FontZoom.override`.
    func setFontSize(_ size: CGFloat, persist: Bool = true) {
        let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
        fontSize = clamped
        let font = AppConfig.resized(config.font, to: clamped)
        // The text views hold attributed strings whose font attributes control
        // rendering — setting `.font` on a text view only affects NEW text, not
        // existing attributed runs. Re-render via loadDiff so the new font is
        // picked up by `renderDiff`, which builds fresh attributed strings.
        // For a quick interim (while the re-render is in flight), push the
        // typing attributes so the placeholder text uses the new size.
        leftTextView.font  = font
        rightTextView.font = font
        if persist {
            FontZoom.override = clamped == config.font.pointSize ? nil : clamped
        }
    }

    /// ⌘0 — drop the stored zoom and return to the configured size.
    func resetFontSize() {
        FontZoom.override = nil
        setFontSize(config.font.pointSize, persist: false)
    }

    // MARK: - Lifecycle

    /// A diff viewer holds no process and no open file handle — git was spawned
    /// on a background queue and its output was read into memory before the
    /// process was released. There is nothing to explicitly free here beyond ARC.
    ///
    /// The protocol requires this member with no default precisely so that claim
    /// is written down by whoever knows it, rather than inferred from an absence.
    /// See the matching comment in `FileViewerPane+Document.swift:196`.
    func documentWillClose() {
        // The NotificationCenter observers added in `wireScrollSync()` are
        // registered with the default centre using self as the observer. Swift
        // does NOT remove them automatically on dealloc for non-NSObject-subclass
        // targets — but DiffViewerPane IS an NSObject subclass, so AppKit's
        // `-[NSObject dealloc]` path does clean them up. Belt-and-suspenders:
        // remove them explicitly here so the scroll-sync callbacks cannot fire
        // into a closing pane while the document list is still iterating.
        NotificationCenter.default.removeObserver(self,
            name: NSView.boundsDidChangeNotification,
            object: leftScroll.contentView)
        NotificationCenter.default.removeObserver(self,
            name: NSView.boundsDidChangeNotification,
            object: rightScroll.contentView)
    }
}
