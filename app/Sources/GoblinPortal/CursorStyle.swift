//
//  CursorStyle.swift
//  What the caret looks like, and how a config string becomes that choice.
//
//  Its own file, Foundation-only, for the same reason as `Renderer.swift`,
//  `KeyBindings.swift` and `ShellDirectory.swift`: the *decision* is a pure mapping from a
//  user-supplied string to a case, and a pure mapping can be read — and compiled into a
//  check — without a terminal view in scope. *Acting* on it is per-engine and lives with
//  each pane.
//
//  IT ALSO REMOVES A REAL COUPLING. Until 2026-07-31 `AppConfig.cursorStyle` was typed as
//  **SwiftTerm's** `CursorStyle`, which is why `Config.swift` carried `import SwiftTerm`
//  while using exactly one symbol from it. That made the app-wide configuration type
//  depend on the emulator: a second engine-backed pane could not read the cursor style
//  without importing SwiftTerm too, and deleting SwiftTerm at Step 2 of
//  `.afk/plans/libghostty-swap-sequencing-2026-07-28.md` would have broken `Config.swift`
//  — a file with nothing to do with either engine. The enum is redeclared here with the
//  same six cases and the same spellings, so nothing user-visible changes.
//
//  Note that `TerminalPane` never called a SwiftTerm *API* with the old type anyway; it
//  converted it to a DECSCUSR code and fed the escape sequence (`TerminalPane.applyCursorStyle`).
//  So the dependency was purely nominal — the worst kind, because it cost a real import
//  and bought nothing.
//

import Foundation

/// The shape and blink state of the caret.
///
/// Six cases rather than a shape-plus-a-Bool because that is exactly what DECSCUSR encodes
/// (`CSI Ps SP q`, values 1–6) and what the config file has always accepted. Engines that
/// model cursor style as shape + blink separately decompose it on the way out via `blinks`
/// and `shape` below, rather than making every call site carry two values.
enum CursorStyle: CaseIterable {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar

    /// Matches the previous hard-coded default in `AppConfig.defaults()`.
    static let `default`: CursorStyle = .blinkBlock

    /// Map a config string onto a case, or `nil` if it names nothing.
    ///
    /// Spellings are generous on purpose and are preserved **verbatim** from the switch
    /// this replaced, including `"underline-bar"` as a synonym for `.blinkBar`. That one
    /// looks like a typo for `"underline"` and probably is, but it has been accepted since
    /// the config file existed, and silently dropping an accepted spelling would turn a
    /// working config into a warning on upgrade — the exact failure `AppConfig.load()`'s
    /// per-field fail-soft contract exists to avoid.
    static func named(_ raw: String) -> CursorStyle? {
        switch raw.lowercased() {
        case "block": return .blinkBlock
        case "block-steady", "steady-block": return .steadyBlock
        case "bar", "underline-bar": return .blinkBar
        case "bar-steady", "steady-bar": return .steadyBar
        case "underline": return .blinkUnderline
        case "underline-steady", "steady-underline": return .steadyUnderline
        default: return nil
        }
    }

    /// The DECSCUSR parameter — `CSI <n> SP q`. This is how the style reaches SwiftTerm,
    /// which exposes no setter for it: `TerminalPane.applyCursorStyle` writes the sequence
    /// into the emulator the same way any program would.
    var decscusrCode: Int {
        switch self {
        case .blinkBlock: return 1
        case .steadyBlock: return 2
        case .blinkUnderline: return 3
        case .steadyUnderline: return 4
        case .blinkBar: return 5
        case .steadyBar: return 6
        }
    }

    /// Whether the caret blinks. Split out for engines that take shape and blink as two
    /// separate settings rather than a single combined value.
    var blinks: Bool {
        switch self {
        case .blinkBlock, .blinkUnderline, .blinkBar: return true
        case .steadyBlock, .steadyUnderline, .steadyBar: return false
        }
    }

    /// The shape, without the blink state. Returned as this project's own three-case enum
    /// rather than any engine type, so this file stays Foundation-only and compilable on
    /// its own — the property that makes a pure-mapping check possible.
    var shape: Shape {
        switch self {
        case .blinkBlock, .steadyBlock: return .block
        case .blinkUnderline, .steadyUnderline: return .underline
        case .blinkBar, .steadyBar: return .bar
        }
    }

    enum Shape {
        case block
        case underline
        case bar
    }
}
