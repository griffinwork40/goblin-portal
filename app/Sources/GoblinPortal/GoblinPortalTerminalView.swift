//
//  GoblinPortalTerminalView.swift
//  SwiftTerm's view, plus this app's own key handling and link policy.
//

import AppKit
import SwiftTerm

/// `LocalProcessTerminalView` with the mac line-editing keys wired up.
///
/// A subclass rather than a patch to `vendor/SwiftTerm`: the vendored copy
/// already carries one local patch (the Metal shader exclusion, see README), and
/// every additional one is future merge cost plus another step in the recreation
/// instructions. Key handling is this app's own opinion anyway, so it belongs
/// here — swapping back to the stock upstream package stays a one-line change in
/// `Package.swift`.
///
/// The hook is `performKeyEquivalent(with:)`, not `keyDown(with:)`. Two reasons,
/// in order of force:
///
/// 1. `keyDown` **cannot** be overridden from here — SwiftTerm declares it
///    `public`, not `open`, so overriding it outside its module is a compile
///    error ("overriding non-open instance method outside of its defining
///    module"). `performKeyEquivalent` is `NSView`'s own method, which SwiftTerm
///    does not touch, so it is open to us.
/// 2. It is also the right phase. AppKit offers a ⌘-modified key event to the key
///    window's view hierarchy *before* the main menu, so claiming these four
///    combos here is exactly how a view is supposed to take a ⌘ chord — and
///    returning false leaves every other ⌘ key (⌘C, ⌘T, ⌘+, …) to the menu,
///    untouched.
@MainActor
protocol GoblinPortalTerminalViewDelegate: AnyObject {
    /// The program in this terminal rang the bell (BEL / `\a`).
    func terminalViewDidRingBell(_ view: GoblinPortalTerminalView)
}

// MARK: - Private CoreGraphics API for font dilation
//
// `CGContextSetFontSmoothingStyle` is an undocumented CoreGraphics function used by
// Terminal.app, iTerm2, MacVim, and Emacs to control sub-pixel dilation on dark
// backgrounds. Declared here with `@_silgen_name` (the Swift ABI-stable way to bind
// a C symbol without a module header) rather than via a bridging header, which this
// SwiftPM package cannot use.
//
// Style values: 16 = thin, 32 = light, 48 = medium (Terminal.app default), 64 = heavy.
// Style 48 widens strokes approximately half a sub-pixel, which compensates for the
// anti-aliasing bleed direction on white-on-dark rendering that makes terminal text
// appear visually thinner than the same font on a light background.
//
// This function is PRIVATE API and may be removed by Apple without notice. Its
// presence on macOS 10.4+ through 26 is well-documented by open-source projects
// (iTerm2: PTYView.m:253, MacVim: MMBackend.m, Emacs: nsterm.m) but it is not in
// any public SDK header. The call is confined to `GoblinPortalTerminalView.draw(_:)` and
// guarded by the user's `fontThicken` preference, so it degrades to standard
// rendering if Apple removes the symbol (the linker would emit a missing-symbol error
// at build time, not a runtime trap — making the dependency visible immediately).
@_silgen_name("CGContextSetFontSmoothingStyle")
private func CGContextSetFontSmoothingStyle(_ context: CGContext, _ style: Int)

final class GoblinPortalTerminalView: LocalProcessTerminalView {
    // MARK: - Typography

    /// When true, `draw(_:)` applies medium font dilation (style 48) to the
    /// current graphics context before SwiftTerm draws glyphs, compensating for
    /// sub-pixel AA bleed on dark backgrounds. Mirrors Terminal.app's own smoothing
    /// style and Ghostty's `font-thicken`. Default: false.
    ///
    /// Set by `TerminalPane.applyTypography(_:)` on every `apply(config:)` call.
    /// The flag lives here (on the view) rather than being read directly from
    /// `AppConfig` so the draw path has one dependency: `self.fontThicken`.
    var fontThicken: Bool = false

    // MARK: - Smooth scrolling

    /// Set by `TerminalPane.apply(config:)`. When false, `scrollWheel` falls through
    /// to super, preserving the original line-by-line behaviour.
    var smoothScrollEnabled: Bool = true

    /// Holds all smooth-scroll state. Wired in `configureSmoothScroll()`.
    /// Internal (not private) so the `+SmoothScroll` extension file can access it.
    let smoothScroll = SmoothScroll()

    // MARK: - Search highlight overlay

    /// Transparent overlay that draws translucent rects at every search match.
    /// Lazily created on the first search; removed when the find bar is dismissed.
    private(set) var searchOverlay: SearchHighlightOverlay?

    /// Override `draw(_:)` only to inject font dilation before SwiftTerm's own
    /// glyph pass. Every actual drawing is done by `super.draw(dirtyRect)`.
    ///
    /// `CGContextSetFontSmoothingStyle` must be called on the SAME `CGContext` that
    /// SwiftTerm uses for its `CTLineDraw` calls — i.e. `NSGraphicsContext.current?.cgContext`
    /// at the moment the draw happens. Setting it before `super.draw()` means it is
    /// live when `drawTerminalContents` calls `context.setShouldSmoothFonts(true)` and
    /// then issues `CTLineDraw` (AppleTerminalView.swift:1505-1535). The style persists
    /// for the duration of the Core Graphics context, which is exactly this draw rect.
    ///
    /// When `fontThicken` is false this override is a no-op (super is called
    /// unconditionally), so it adds zero cost to the render path without thickening.
    override func draw(_ dirtyRect: NSRect) {
        if fontThicken, let ctx = NSGraphicsContext.current?.cgContext {
            CGContextSetFontSmoothingStyle(ctx, 48)  // 48 = medium dilation (Terminal.app default)
        }
        super.draw(dirtyRect)
        // Sync overlay geometry after every terminal redraw so scrolling,
        // new output, and selection changes are reflected without needing
        // a separate `selectionChanged` override (which has concurrency
        // issues — Terminal is not Sendable, and the inherited signature
        // is nonisolated while MacTerminalView is @MainActor).
        updateSearchOverlayGeometry()
    }

    // MARK: - Search state callback

    /// Called by SwiftTerm (patch 0009) whenever the find bar's search term or
    /// options change, or the find bar is dismissed.  Drives the all-match
    /// highlight overlay so every match is visible, not just the selected one.
    override func searchStateDidChange(term: String, options: SearchOptions) {
        if term.isEmpty {
            searchOverlay?.removeFromSuperview()
            searchOverlay = nil
            lastSearchTerm = ""
            lastSearchOptions = SearchOptions()
            return
        }

        lastSearchTerm = term
        lastSearchOptions = options

        let overlay = ensureSearchOverlay()
        let matches = findAllMatchPositions(term, options: options)
        let summary = searchMatchSummary(term, options: options)
        let terminal = getTerminal()

        overlay.cellSize = terminalCellSize
        overlay.scrollOffset = terminal.buffer.yDisp
        overlay.visibleRows = terminal.rows
        // searchMatchSummary returns 1-based index; convert to 0-based.
        overlay.activeMatchIndex = summary.index > 0 ? summary.index - 1 : -1
        overlay.matches = matches  // triggers needsDisplay
    }

    /// Remembered search state so `updateSearchOverlayGeometry` can refresh
    /// the active-match index after a scroll without re-querying the term.
    private var lastSearchTerm: String = ""
    private var lastSearchOptions: SearchOptions = SearchOptions()

    /// Cell size derived from view bounds and grid dimensions.
    /// `cellDimension` on `MacTerminalView` is internal, so we compute it.
    var terminalCellSize: CGSize {
        let terminal = getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return .zero }
        return CGSize(
            width: bounds.width / CGFloat(terminal.cols),
            height: bounds.height / CGFloat(terminal.rows)
        )
    }

    /// Update the overlay geometry after a scroll or resize.  The overlay is
    /// a sibling view drawn independently, so it must be told when the
    /// viewport moves.  Called by `selectionChanged(source:)` below — which
    /// fires on every scroll and selection change — and by `layout()`.
    func updateSearchOverlayGeometry() {
        guard let overlay = searchOverlay, !overlay.matches.isEmpty else { return }
        let terminal = getTerminal()
        overlay.scrollOffset = terminal.buffer.yDisp
        overlay.visibleRows = terminal.rows
        overlay.cellSize = terminalCellSize
        if !lastSearchTerm.isEmpty {
            let summary = searchMatchSummary(lastSearchTerm, options: lastSearchOptions)
            overlay.activeMatchIndex = summary.index > 0 ? summary.index - 1 : -1
        }
        overlay.frame = bounds
        overlay.needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateSearchOverlayGeometry()
        // Sync SmoothScroll cell height (cellDimension is internal to SwiftTerm).
        let t = getTerminal()
        if t.rows > 0 { smoothScroll.configure(view: self, cellHeight: bounds.height / CGFloat(t.rows)) }
    }

    private func ensureSearchOverlay() -> SearchHighlightOverlay {
        if let existing = searchOverlay { return existing }
        let overlay = SearchHighlightOverlay(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        searchOverlay = overlay
        return overlay
    }

    // MARK: - Initialisation

    /// Overrides the super's designated initialiser so we can set Goblin Portal's link
    /// policy once, at construction time, rather than requiring `TerminalPane` to
    /// reach into the view's properties after the fact.
    ///
    /// `super.init(frame:)` calls `setup()` (`MacLocalTerminalView.swift:73`), which
    /// sets `terminalDelegate = self` and creates the `LocalProcess`. Both must exist
    /// before link detection can run — specifically, the `terminal` property (a
    /// `Terminal` instance) is created inside `TerminalView.init`, which `super` delegates
    /// to — so setting these properties after the `super` call is required, not optional.
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Detect OSC 8 hyperlinks AND plain-text URLs via `.implicit`. The plain-text
        // detector (`ghosttyImplicitLinkRegex`, `Terminal.swift:6204`) matches many
        // schemes from raw output — https, mailto, ftp, file, ssh, git, tel, magnet,
        // and more — not only http(s). Safety for every detected link is enforced
        // downstream by `openSafeURL`'s scheme allow-list (see `TerminalPane+Links.swift`).
        // Set explicitly rather than relying on the SwiftTerm default so a future upstream
        // change to that default cannot silently disable URL clicking.
        // Source: `Mac/MacTerminalView.swift:889-890`.
        linkReporting = .implicit
        // Underline only on ⌘+hover; activate only when highlighted. This is the
        // standard macOS convention (Terminal.app, iTerm2, Ghostty all use it):
        // plain clicks stay free for text selection and mouse reporting, and ⌘ is
        // the intentional "I want the link" gesture. Source: `Mac/MacTerminalView.swift:893`.
        linkHighlightMode = .hoverWithModifier
        // Wire smooth-scroll callbacks. `scrollUp/Down` are public on AppleTerminalView.
        smoothScroll.onScrollLines = { [weak self] lines in
            guard let self else { return }
            if lines > 0 { self.scrollUp(lines: lines) }
            else { self.scrollDown(lines: -lines) }
        }
        smoothScroll.onOffsetChanged = { [weak self] offset in
            self?.layer?.setAffineTransform(
                offset == 0 ? .identity : CGAffineTransform(translationX: 0, y: offset))
        }
    }

    /// Required companion to the frame-based initialiser above.
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GoblinPortalTerminalView: use init(frame:)") }

    // MARK: - Link activation

    /// Route through `openSafeURL(_:)` (scheme allow-list + GOBLIN_PORTAL_DIAG logging).
    /// Overrides rather than reassigning `terminalDelegate` — see `TerminalPane+Links.swift`.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openSafeURL(link)
    }

    /// Bell not on `LocalProcessTerminalViewDelegate` (4 members, no bell). The safe hook
    /// is override `bell(source: Terminal)` — reassigning `terminalDelegate` is warned
    /// against upstream (`MacLocalTerminalView.swift:59-64`). Full rationale in TerminalPane.
    weak var bellDelegate: GoblinPortalTerminalViewDelegate?

    /// `bell(source: Terminal)` rather than `bell(source: TerminalView)`: the former is
    /// the `TerminalDelegate` method `TerminalView` declares `open`, and it is what
    /// `EscapeSequenceParser.swift:362` calls on receiving byte 0x07.
    ///
    /// `nonisolated` + `assumeIsolated` for the same reason as the accessibility
    /// overrides in `DocumentTabStrip`: SwiftTerm predates Swift concurrency, so the
    /// inherited signature is non-isolated. It is safe here because SwiftTerm's own
    /// pty reads are dispatched to `DispatchQueue.main` by default
    /// (`LocalProcess.swift:127`), so the parse that raises this is already on the
    /// main thread — the same runtime-check-over-compile-error trade `TerminalPane`
    /// documents on its `@preconcurrency` conformance.
    override nonisolated func bell(source: Terminal) {
        MainActor.assumeIsolated {
            // Reproduces SwiftTerm's own default rather than calling `super`: `Terminal`
            // is not `Sendable`, so `source` cannot cross into an isolated block, and
            // the default is exactly this one line — `bell(source: Terminal)` forwards
            // to `terminalDelegate?.bell(source: self)` (`MacTerminalView.swift:2870`),
            // which for a `LocalProcessTerminalView` is itself, inheriting
            // `NSSound.beep()` (`MacTerminalView.swift:3032-3035`).
            //
            // Kept because it is behaviour we already shipped: the strip's marker says
            // *which* tab wants you, but the sound is what makes you look at all.
            NSSound.beep()
            bellDelegate?.terminalViewDidRingBell(self)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let bytes = MacLineEditing.controlBytes(
            keyCode: event.keyCode, modifiers: event.modifierFlags)
        else { return super.performKeyEquivalent(with: event) }

        // Every view in the key window is offered the equivalent, not just the
        // focused one. Today there is one pane per window so this is moot; once
        // splits exist it is what keeps ^U out of the pane you are not typing in.
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }

        // A program that turned on the kitty keyboard protocol (`CSI > 1 u`)
        // explicitly asked to receive modifiers itself, and SwiftTerm will encode
        // ⌘ for it as `super`. Rewriting ⌘⌫ to ^U in that state would silently
        // take a binding away from an editor that asked for the raw keystroke, so
        // hand it back to the normal path. Neovim and Helix enable it; afk's REPL
        // never does (plan §4.1: "kitty keyboard protocol — OPTIONAL, never
        // enabled"), so the translation stays live for the case this app exists
        // to host.
        guard getTerminal().keyboardEnhancementFlags.isEmpty else {
            return super.performKeyEquivalent(with: event)
        }

        send(bytes)
        return true
    }

    /// Event monitor handle for smooth scroll interception -- see
    /// `GoblinPortalTerminalView+SmoothScroll.swift` for the wiring.
    var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installScrollMonitor() } else { removeScrollMonitor() }
    }

    /// Cancel in-flight momentum before text selection begins.
    override func mouseDown(with event: NSEvent) {
        smoothScroll.snapToGrid()
        super.mouseDown(with: event)
    }

    // MARK: - Paste guard

    /// Intercept ⌘V to guard against accidental multi-line or large pastes.
    ///
    /// SwiftTerm inherits NSView's paste action through the responder chain. The
    /// default path reads the pasteboard and writes every byte to the pty, executing
    /// newline-terminated lines immediately when bracketed paste (DECSET 2004) is not
    /// active. This override shows a confirmation dialog when the clipboard content
    /// exceeds safety thresholds — the same guard iTerm2 and WezTerm ship.
    ///
    /// Bracketed paste is NOT checked here on purpose: even with it active, a
    /// surprising large paste deserves a heads-up, and the dialog is cheap.
    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string),
              PasteGuard.confirmIfNeeded(text, in: self) else {
            return  // User cancelled or nothing on clipboard
        }
        super.paste(sender as Any)
    }

    // Clip the parent so a sub-cell pixel offset doesn't reveal a gap at the edges.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        superview?.wantsLayer = true; superview?.layer?.masksToBounds = true
    }
}
