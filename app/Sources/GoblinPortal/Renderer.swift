//
//  Renderer.swift
//  Which drawing back end a terminal uses, and how a config string becomes that choice.
//
//  Its own file, and deliberately view-free (Foundation only), for the same reason
//  `KeyBindings.swift` and `ShellDirectory.swift` are: the *decision* is a pure mapping
//  from a user-supplied string to a case, and a pure mapping can be read — and compiled
//  into a check — without an NSView in scope. *Acting* on the decision needs a live
//  SwiftTerm view and lives in `TerminalPane+Renderer.swift`. Keeping them apart is also
//  what stops `Config.swift` (306 lines — under the 350-line ceiling, with 44 to spare)
//  from growing an enum it does not own.
//

import Foundation

/// The drawing back end for a terminal document.
///
/// Both cases are SwiftTerm's; neither is written here. The choice matters because the two
/// paths have very different per-frame costs:
///
/// * `.coreText` — `drawTerminalContents` (`Apple/AppleTerminalView.swift:1255`) rebuilds
///   an attributed string per row (`:1364`) and a `CTLine` per segment (`:1400`) on every
///   draw, with **no per-row cache on macOS** — the `attrStrBuffer: CircularList<ViewLineInfo>`
///   cache exists only in the iOS view (`iOS/iOSTerminalView.swift:237`). The per-line
///   "skip rows outside the dirty rect" optimisation is present but compiled out under
///   `#if false` (`:1352-1362`), and damage is tracked as a min/max **span**
///   (`Terminal.swift:5035`, `:5107`), so two scattered dirty rows rebuild everything
///   between them. Draws are throttled to 60fps (`:1912`), which bounds the cost at
///   re-shape-the-visible-grid sixty times a second.
///
/// * `.metal` — a CoreText-rasterised glyph atlas plus GPU quads
///   (`Apple/Metal/MetalTerminalRenderer.swift`), whose default `.perRowPersistent`
///   buffering mode "caches per-row vertex data and only rebuilds dirty rows"
///   (`Mac/MacTerminalView.swift:245`). That is precisely the cache the Core Text path
///   lacks.
enum Renderer: String, CaseIterable {
    case coreText
    case metal

    /// `.coreText`, and this is a deliberately conservative default rather than an
    /// endorsement.
    ///
    /// The GPU path is measurably reachable and structurally better shaped for fast
    /// scrolling, but three things are true at once: its speed advantage here has **not
    /// been measured** (see `.afk/research/performance-audit-2026-07-31.md` §1, which says
    /// so at length), upstream labels it *"Experimental GPU path… image caching is basic;
    /// GPU path is still evolving"* (`Mac/MacTerminalView.swift:217`), and this project has
    /// no test target — so a rendering regression would be found by the user, in use, not
    /// by a check. Opting in is one config line and ⌘R; flipping this default should follow
    /// real use, the same way G6 (the multi-hour soak) is the only thing that can retire
    /// itself.
    static let `default`: Renderer = .coreText

    /// Map a config string onto a case, or `nil` if it names nothing.
    ///
    /// Spellings are generous on purpose — this is a hand-edited JSON file, and the
    /// failure mode of a strict match is a silently ignored setting, which
    /// `AppConfig.load()` treats as a bug everywhere else in the file. `nil` here becomes
    /// a `warnings` entry there rather than a throw, so a typo degrades to the default and
    /// says why.
    static func named(_ raw: String) -> Renderer? {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "coretext", "core-text", "cpu", "cg", "coregraphics", "core-graphics":
            return .coreText
        case "metal", "gpu":
            return .metal
        default:
            return nil
        }
    }

    /// The spellings `AppConfig.load()` names in a warning when it rejects a value.
    /// Derived from `allCases` rather than written out, so adding a case cannot leave the
    /// user-facing message behind.
    static var configNames: String {
        allCases.map(\.configName).joined(separator: ", ")
    }

    /// The canonical spelling to write in a config file.
    var configName: String {
        switch self {
        case .coreText: return "coretext"
        case .metal: return "metal"
        }
    }
}
