//
//  FileViewerPane.swift
//  A read-only look at one file, as a document in the Space's strip.
//

import AppKit

@MainActor
protocol FileViewerPaneDelegate: AnyObject {
    /// The unsaved-changes flag flipped — the Space repaints the tab's dot.
    func fileViewerDidChangeEditedState(_ pane: FileViewerPane)
}

/// The second `SpaceDocument` conformer — and deliberately the *cheap* one.
///
/// The file tree shipped before there was anywhere to open a file into, so
/// activating a row typed its path into the terminal and did nothing else: a
/// picker wired to a hole. This closes it with a plain `NSTextView` — editing,
/// undo, ⌘S, and regex-based syntax highlighting for the five roles
/// `SyntaxPalette` defines (keyword, string, number, type, comment). No
/// tree-sitter, no grammar bundles — a tokenizer that gets the easy 90% right
/// and stays auditable, which is the honest trade for a viewer.
///
/// **The hard part of editing here is not typing, it is the race.** This app's
/// premise is that an agent is rewriting these same files in the terminal next
/// door, so "the buffer and the disk disagree" is the normal case, not an edge
/// case. Two rules keep that from eating work, and they are the reason the code
/// below is longer than an editable text view has any right to be:
///
///  1. A dirty buffer is **never** auto-reloaded. `documentWindowDidBecomeKey`
///     re-reads only a clean one; on a dirty one it raises `hasExternalChange`
///     and leaves your text alone.
///  2. Saving over a file that moved under you **asks first**, and every close
///     path in the app funnels through `documentShouldClose()`.
///
/// The third rule is quieter: a *placeholder* body (binary, too large, unreadable)
/// is never editable. Without that, ⌘S on a clicked `.png` would write the string
/// "binary.png is a binary file." over the actual image.
@MainActor
final class FileViewerPane: NSObject {
    /// Exposed so `SpaceViewController` can reuse an already-open tab instead of
    /// stacking a twelfth copy of the same file (`openFile(url:)`).
    let url: URL

    weak var delegate: FileViewerPaneDelegate?

    // Why the state below is `internal` and not `private`: this class is split
    // across three files (`+Editing`, `+Document`) and Swift's `private` is
    // file-scoped, so the extensions cannot see it. `fileprivate` does not reach
    // across a file boundary either — internal is the narrowest level that
    // compiles. None of it is `public`; the module boundary still holds, and no
    // other type in the module has a reason to touch any of it. Where the only
    // writer stays in *this* file the setter stays private, so the promotion buys
    // read access and nothing more.
    var config: AppConfig
    let scrollView = NSScrollView()
    let textView = EditorTextView()

    var fontSize: CGFloat

    /// Unsaved edits live in the text view; this is the flag everything else reads.
    /// Writable module-wide only because `setDirty` — its single writer — lives in
    /// `+Editing`; that one-writer discipline is the real invariant, not the
    /// access level.
    var isDirty = false

    /// The body is an explanation ("…is a binary file."), not the file's contents.
    /// Gates editing — see rule 3 in the type comment.
    /// Writable module-wide because `reload` — its single writer — now lives in
    /// `+IO.swift` across a file boundary. The one-writer discipline is the real
    /// invariant, not the access level (same trade as `isDirty`/`setDirty`).
    var isPlaceholder = true

    /// Set when disk moved while the buffer was dirty. Not an error state: it means
    /// the next save has to ask before it overwrites someone else's work.
    /// All three files write it — cleared on load and after a save, raised on a
    /// refresh that finds a dirty buffer — so it cannot be `private(set)`.
    var hasExternalChange = false

    /// Re-entrancy guard for `shouldChangeTextIn:replacementString:`. When the
    /// delegate calls `textView.insertText(_:replacementRange:)` to inject a
    /// modified replacement (auto-indent, tab→spaces, auto-pair), AppKit re-enters
    /// `shouldChangeTextInRanges:replacementStrings:` — which calls our delegate
    /// method again. For Enter and Tab the re-entered replacement is the same
    /// single character (`"\n"` / `"\t"`), producing infinite recursion (11 110
    /// frames deep until the stack guard page is hit, SIGSEGV). For auto-pair the
    /// re-entered replacement is the pair string (two characters, e.g. `"()"`),
    /// which would not re-trigger the single-character guard at line 67 of
    /// SmartEditing — the flag is defensive completeness there, not strictly
    /// required for correctness today, but correct to keep given that the guard
    /// eliminates the class rather than each specific case individually.
    /// While this flag is true the delegate returns `true` immediately, letting
    /// AppKit process the already-transformed text without re-triggering smart editing.
    var isHandlingSmartEdit = false

    /// Resolved theme colours for each syntax role — computed once per config
    /// reload and reused on every keystroke. Nil until the first call to
    /// `syntaxColours()` and reset to nil by `apply(config:)` on theme change.
    /// Stored here (not in the extension) because extensions cannot hold stored properties.
    var cachedSyntaxColours: [SyntaxRole: NSColor]?

    /// The line-number gutter. Stored here because extensions cannot hold stored
    /// properties; created once in `init` and never recreated.
    var rulerView: LineNumberRulerView?

    /// Whether this document is currently soft-wrapping. Per-document runtime state
    /// (not persisted). Defaults from config + file extension in `applyWrapping()`.
    var isWrapping = false

    /// The status bar below the editor showing Ln/Col, language, encoding, indent.
    /// Stored here because extensions cannot hold stored properties.
    var statusBar: EditorStatusBar?

    /// Cached byte offsets of each line start (index 0 = line 1 = offset 0).
    /// Invalidated by `invalidateLineStartCache()` on every `textDidChange`, then
    /// rebuilt lazily by `updateStatusBar()`. Turns the O(n) line walk into an
    /// O(log n) binary search over an O(n)-once cache — the walk still happens once
    /// per edit, but not once per cursor movement or selection change.
    var lineStartCache: [Int]?

    /// Pending status bar update — cancelled and replaced on each rapid-fire
    /// selection change so the O(log n) lookup runs at most once per run-loop turn.
    var pendingStatusBarUpdate: DispatchWorkItem?

    /// Container view holding scroll view + status bar, so `documentView` returns
    /// one view for both. `SpaceDocument` expects a single `NSView`.
    let containerView = NSView()

    /// Currently folded regions, keyed by the storage offset of the "…" placeholder.
    /// Populated and maintained by `FileViewerPane+Folding.swift`. Cleared on reload
    /// (a fresh read always brings unfolded text from disk).
    var foldedRegions: [FoldRegion] = []

    /// The live ⌘⇧O symbol-outline panel, if one is open. Weak storage is not
    /// possible here because `SymbolOutlinePanel` is an `NSObject` subclass, not a
    /// protocol — we nil it out manually on dismiss and on reload.
    /// Stored here because extensions cannot hold stored properties.
    var symbolOutlinePanel: SymbolOutlinePanel?

    /// Write the file back as whatever it was read as. Re-encoding a Latin-1 or
    /// UTF-16 file to UTF-8 behind the user's back is a silent, whole-file diff.
    /// Settable because `+Editing` reassigns it when the user explicitly consents
    /// to a UTF-8 rewrite.
    var savedEncoding: String.Encoding = .utf8

    /// Identity of the bytes currently on screen, so `documentWindowDidBecomeKey`
    /// can re-read only when disk actually moved. Comparing content would mean
    /// reading the file on every window focus; comparing (mtime, size) is one stat.
    /// Re-stamped by `+Editing`'s `write()` as well, so the save we just performed
    /// is not read back as someone else's external change.
    var loadedStamp: (date: Date, size: Int)?

    /// Read by `setFontSize` in `+Document`, which does the clamping.
    static let minFontSize = CGFloat(AppConfig.minFontSize)
    static let maxFontSize = CGFloat(AppConfig.maxFontSize)

    /// Refuse rather than beachball. `NSTextView` lays out the whole string up
    /// front, so a multi-hundred-megabyte log — a genuinely likely thing to click
    /// in an agent workspace — would hang the app, not scroll slowly. 4 MiB is
    /// roughly 100k lines of source, far past anything worth reading in a viewer
    /// with no editor affordances.
    /// Visible to `+IO.swift` where `read()` lives. Same promotion reason as
    /// `isPlaceholder` — the reader crossed a file boundary.
    static let maxBytes = 4 << 20

    /// A NUL in the first block is the same heuristic `git diff` uses to call a
    /// file binary, and for the same reason: no text encoding this viewer can
    /// render puts one there.
    static let sniffBytes = 8 << 10

    init(config: AppConfig, url: URL, frame: NSRect) {
        self.config = config
        self.url = url
        self.fontSize = FontZoom.override ?? config.font.pointSize
        super.init()

        // Non-wrapping by default — the right choice for code, where soft-wrapping
        // re-flows indentation into nonsense. `setWrapping(_:)` toggles this for
        // markdown and prose; these constants set up the non-wrapping baseline.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Re-set per load: `reload` locks this back down for placeholder bodies.
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        // Plain-text editing conveniences that are actively wrong for code.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // ⌘F/⌘G come free. The Edit-menu items in `AppDelegate.buildMenu()` send
        // `performFindPanelAction:` down the responder chain with an `NSFindPanelAction`
        // tag — SwiftTerm implements that for terminals, and `NSTextView` implements
        // it natively, so the same three menu items drive both document kinds with
        // no branching. Without `usesFindBar` AppKit would try to open the ancient
        // modal find *panel* instead of the inline bar.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Status bar sits below the scroll view. Both live in a container so the
        // SpaceDocument protocol's `documentView` returns one view for both.
        let barHeight = EditorStatusBar.barHeight
        let bar = EditorStatusBar(frame: NSRect(
            x: 0, y: 0, width: frame.width, height: barHeight))
        bar.autoresizingMask = [.width, .maxYMargin]
        statusBar = bar

        scrollView.frame = NSRect(
            x: 0, y: barHeight, width: frame.width, height: frame.height - barHeight)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // Explicit, because `FileTreeViewController` sets the opposite on its own
        // scroll view to let the sidebar's vibrancy through. Here the theme
        // background is the point, so this view must actually paint it.
        scrollView.drawsBackground = true
        scrollView.autoresizingMask = [.width, .height]

        containerView.frame = frame
        containerView.autoresizingMask = [.width, .height]
        containerView.addSubview(scrollView)
        containerView.addSubview(bar)

        // Line-number gutter. Installed before `apply(config:)` so the first
        // `updateAppearance` call in `apply` has a ruler to reach.
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        rulerView = ruler

        apply(config: config)
        reload(preservingScroll: false)
    }
}
