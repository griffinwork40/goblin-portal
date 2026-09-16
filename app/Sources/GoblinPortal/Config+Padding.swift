//
//  Config+Padding.swift
//  Turning a config file's `padding` value into resolved terminal insets, fail-soft.
//
//  Its own file for the same reason as `Config+Theme.swift` and `Config+Editor.swift`:
//  `Config.swift` is near the 350-line ceiling and this is a clean seam. Everything
//  here is one question — "given an optional padding value a user typed, what insets
//  do we apply?" — and answering it needs none of the font/theme/engine machinery.
//
//  Two accepted config forms:
//    "padding": 4             → uniform 4px on all sides
//    "padding": { "x": 8, "y": 4 }  → separate horizontal / vertical
//
//  Why x/y and not top/bottom/left/right:
//    Terminal layouts are symmetric. A terminal with asymmetric left/right padding
//    would be visually off-balance, and the cost in columns is the same either side.
//    x/y is the minimal orthogonal representation for symmetric padding — two numbers
//    rather than four, and each maps cleanly to the axis it describes.
//
//  Why terminals only, not the editor:
//    `FileViewerPane` uses `NSTextView.textContainerInset`, which is the AppKit-native
//    way to pad a text view and respects the glyph layout. Applying a frame inset on
//    the editor's container view would add padding *outside* the text container's own
//    margins, double-dipping. The editor's own defaults are already tuned separately.
//
//  Why 4px default:
//    4px is barely perceptible on a standard display but lifts text off the window
//    edge, which reduces the cognitive friction of a full-screen terminal. At common
//    terminal widths (80–132 columns at 14pt SF Mono), 4px horizontal padding drops
//    roughly 0.2 columns — well within one character's width and therefore invisible
//    to most column-alignment-sensitive TUIs. Raising it to 8px or more starts trading
//    visible columns; the config is the right place to make that trade explicitly.
//
//  THE INVARIANT THIS FILE OWNS: `applyPadding` never throws. A bad value costs that
//  field and appends one warning. Preserve that — `AppConfig.load()` has no error path.
//

import CoreGraphics

extension AppConfig {
    /// Resolve the `padding` value from config primitives, fail-soft.
    ///
    /// Called from `AppConfig.load()` when a `padding` key is present. Mutates `self`
    /// directly and appends to `warnings` for any degradations — same contract as
    /// `applyEditor` and the theme resolver.
    ///
    /// Validation rules:
    ///   - Negative values are floored to 0: a negative inset would expand the terminal
    ///     view *outside* its container frame, clipping against the window edge.
    ///   - Values > 100 are rejected with a warning and default to 4. 100px padding is
    ///     already extravagant — a 13" MacBook at 14pt would lose ~6 terminal columns —
    ///     and a value above it almost certainly reflects a unit confusion (e.g. "em"
    ///     intended, px applied) rather than intentional configuration.
    mutating func applyPadding(x: CGFloat, y: CGFloat) {
        let px = max(0, x), py = max(0, y)
        if px > 100 || py > 100 {
            warnings.append(
                "padding values (\(x), \(y)) exceed the 100px cap — using default 4")
        } else {
            terminalPadding = (x: px, y: py)
        }
    }
}
