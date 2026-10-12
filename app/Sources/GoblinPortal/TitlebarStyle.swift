//
//  TitlebarStyle.swift
//  The `titlebar` config field ("standard" | "compact") and the pure rule that decides how
//  much of the titlebar band the document area may take.
//
//  Its own file, Foundation-only, for the same reason `ShellExitPolicy.swift` is: the
//  spelling table, the fail-soft warning and the inset arithmetic are pure functions, so
//  `check-titlebar-layout.sh` compiles this file alone with swiftc and table-tests them with
//  no window server. `Config.swift` sits at the ceiling and only gains the stored fields.
//  Window-side application lives in `SpaceWindowController+Titlebar.swift`; the consumer is
//  `DocumentAreaViewController+SafeArea.swift`. Evidence: `.afk/plans/titlebar-reclaim-scope.md`.
//

import Foundation

/// How a Space window draws its titlebar.
///
/// `standard` (default) is the opaque title row every release before this one shipped,
/// byte-for-byte. `compact` extends the content view under a transparent, title-less
/// titlebar (`.fullSizeContentView`) so the terminal takes the title row wherever no
/// window control sits above it — +2 rows at 1100x680 with the sidebar showing (measured).
enum TitlebarStyle: String {
    case standard
    case compact

    /// Config spellings, for warnings and the gate's drift check.
    static let configNames = "standard | compact"

    /// Case-insensitive; nil when unrecognised (the caller warns).
    static func named(_ raw: String) -> TitlebarStyle? {
        switch raw.lowercased() {
        case "standard": return .standard
        case "compact":  return .compact
        default:         return nil
        }
    }

    /// Fail-soft parse used by the loader: an absent key keeps `fallback`, an unknown value
    /// keeps `fallback` and appends one warning (same shape as `closeOnShellExit`).
    static func parse(_ raw: String?, fallback: TitlebarStyle, warnings: inout [String]) -> TitlebarStyle {
        guard let raw else { return fallback }
        if let style = named(raw) { return style }
        warnings.append(
            "titlebar '\(raw)' unrecognised (expected one of: \(configNames)) — using \(fallback.rawValue)")
        return fallback
    }

    /// Points the document area must leave at its top (the controls-aware rule, scope §1c).
    ///
    /// - full: how far `contentLayoutRect` sits below the view's top (32pt for the bare
    ///   title row on macOS 27, 68pt with the native Space tab bar or a `.bottom` accessory).
    /// - titleRow: the bare title row's height (frame height minus the content height the
    ///   same frame would have WITHOUT `.fullSizeContentView`).
    /// - viewMinX / controlsMaxX: window x of the view's left edge, and the rightmost edge of
    ///   anything AppKit draws in the title row on the left (traffic lights, `.left` accessories).
    /// - allowBand: the window is in the compact style (transparent titlebar).
    ///
    /// The title row is given up only when it is the WHOLE inset (no tab bar / banner below
    /// it — those would sit over the terminal) and nothing is drawn above the view's left edge.
    static func topInset(
        full: CGFloat, titleRow: CGFloat, viewMinX: CGFloat, controlsMaxX: CGFloat, allowBand: Bool
    ) -> CGFloat {
        let full = max(0, full)
        let clearOfControls = viewMinX >= controlsMaxX + controlsClearance
        guard allowBand, clearOfControls, full <= titleRow + 0.5 else { return full }
        return max(0, full - titleRow)
    }

    /// Gap kept between the last titlebar control and content that enters the band.
    static let controlsClearance: CGFloat = 8
}
