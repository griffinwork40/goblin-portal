//
//  PaneDimming.swift
//  Foundation-only pure function that returns the effective unfocused-pane opacity.
//
//  **Pure and view-free — Foundation only, on purpose**, so `check-pane-dim.sh` can
//  compile it beside `ThemeValues.swift` and `ThemeContrast.swift` without linking
//  AppKit. Same pattern as `Renderer.swift`, `CursorStyle.swift`, `CommandOutcome.swift`.
//
//  WHY THIS EXISTS
//
//  `NSView.alphaValue` dims an unfocused split pane by compositing the pane's layer
//  over the `paddingBackdrop` behind it. `paddingBackdrop` is painted with
//  `config.effectiveBackground` (`DocumentAreaViewController.setTerminalPadding`,
//  called from `SpaceViewController.swift:199`), and `TerminalClipView` (the pane's
//  `documentView`) is also layer-backed (`wantsLayer = true`, `TerminalClipView.swift:39`)
//  filled with the same colour (`fillColor`, set in `TerminalPane.apply(config:):193`
//  from `view.nativeBackgroundColor`). So the entire pane layer — background, glyph
//  rendering, everything — composites at `alphaValue` over what is effectively the
//  terminal background colour again.
//
//  The pixel a reader sees for a foreground glyph is therefore:
//
//      dimmed_fg = opacity * fg + (1 − opacity) * bg
//
//  which is exactly `RGB.composited(over: bg, alpha: opacity)` from `ThemeContrast.swift`.
//
//  DEFECT CONFIRMED (measured, not inferred)
//
//  Under the default palette (`classic-repaired`, `Config.swift:260`), the terminal
//  foreground is `#8A8A8A` on `#000000` — APCA Lc 39.6, documented as PINNED in AFK.md
//  and ThemeContrast commentary. At the flat 0.7 default, dimming drops body text to
//  Lc 20.8, far below APCA's Lc 45 "readable at any size" floor the app already enforces
//  for syntax comments and the inactive tab-strip label (ThemeContrast.swift §5j,
//  `SyntaxPalette.readableFloor`). The same issue affects umber at 0.7 (Lc 51.4, only
//  6.4 Lc above the floor), and both afk-dark and tokyo-night sit exactly at the boundary.
//
//  THE RULE — two cases based on whether the user set the key
//
//  (A) USER ABSENT: binary-search the minimum opacity that keeps
//      `composited(fg, over: bg, alpha: opacity)` at APCA Lc ≥ 45, round up to the
//      nearest 0.01 (safer), then apply a 0.7 cap ONLY when that minimum is ≤ 0.7.
//      · minSafe ≤ 0.7 → return 0.7 (design-intent cap). High-contrast palettes like
//        afk-light (Lc 102.8 undimmed) could safely dim to ~0.38 but the intent is 0.7.
//      · minSafe > 0.7 → return minSafe verbatim (floor wins over cap). tokyo-night
//        needs 0.71 to clear Lc 45; returning 0.70 gives Lc 44.5 (violates the floor).
//        Legibility takes precedence over the dimming aesthetic.
//
//  (B) UNDIMMED ALREADY BELOW FLOOR (classic-repaired PINNED case): return 1.0 (no
//      dimming). The floor cannot be met; applying any opacity would only worsen it.
//      The ratio approach (floor = undimmed_Lc * k) was considered and rejected: it
//      endorses dimming an already-broken palette while measuring it against a softer
//      criterion than every other surface in the app. The honest answer is to not dim.
//
//  (C) USER EXPLICIT: honour the choice, but append a warning to `config.warnings` if
//      the resulting composited Lc falls below 45. Mirrors the tab-strip discovery:
//      the same floor applied consistently caught the 0.55→0.72 fix (ThemeContrast §5j).
//

import Foundation

enum PaneDimming {

    /// The APCA Lc floor that composited body text must meet in an unfocused pane.
    ///
    /// 45 is APCA's "readable at any size" tier — the same value `SyntaxPalette.readableFloor`
    /// uses for syntax comments and §5j uses for inactive tab labels. One number everywhere
    /// means a change to the app's legibility posture requires one edit, and a gate can assert
    /// that both surfaces share the same floor.
    static let dimFloor: Double = 45.0

    /// Return the effective unfocused-pane opacity for this palette.
    ///
    /// This is the single source of truth for what `SplitContainerView.setFocusedChild`
    /// (and the per-leaf loop in `SpaceViewController+SplitPresentation.swift`) should pass
    /// as `opacity`. It is Foundation-only so `check-pane-dim.sh` can compile and assert it
    /// without linking AppKit — the same design that makes `Renderer.named` and
    /// `CursorStyle.named` gateable headlessly.
    ///
    /// - Parameters:
    ///   - background:   The palette's background hex string, e.g. `"#000000"`.
    ///   - foreground:   The palette's body-text foreground hex, e.g. `"#8A8A8A"`.
    ///   - userOpacity:  The value the user wrote in `config.json`, or `nil` if absent.
    ///   - warnings:     Mutated in-place when the user's explicit value would produce
    ///                   composited body text below APCA Lc 45.
    ///
    /// - Returns: Opacity in 0…1. `1.0` means no dimming.
    static func effectiveOpacity(
        background: String,
        foreground: String,
        userOpacity: Double?,
        warnings: inout [String]
    ) -> Double {

        // Parse the hex colours. On failure (caught independently by check-theme-contrast.sh
        // §1 and the palette parseability loop) fall through to the safe intent value.
        guard let bg = RGB(hex: background), let fg = RGB(hex: foreground) else {
            return userOpacity ?? 0.7
        }

        let undimmedLc = APCA.lc(text: fg, background: bg)

        // Case (C): user set the key explicitly.
        if let explicit = userOpacity {
            if explicit < 1.0 {
                let compositedLc = APCA.lc(text: fg.composited(over: bg, alpha: explicit), background: bg)
                if compositedLc < dimFloor {
                    // Fail-soft warn, not refuse — the user chose this value deliberately.
                    // Same shape as the out-of-range warning in Config+Load.swift:141.
                    warnings.append(
                        "unfocusedPaneOpacity \(String(format: "%.2f", explicit)) dims "
                        + "body text to APCA Lc \(String(format: "%.1f", compositedLc)) "
                        + "(floor \(Int(dimFloor))) — text in unfocused panes may be hard to read")
                }
            }
            return explicit
        }

        // Case (B): undimmed foreground already below the floor (the documented PINNED case
        // for classic-repaired: fg #8A8A8A on #000000 = Lc 39.6). No dimming amount can
        // help — return 1.0 so the window is at least not actively worsened.
        if undimmedLc < dimFloor {
            return 1.0
        }

        // Case (A): binary-search the minimum safe opacity.
        //
        // We want the MOST DIMMING (smallest opacity) that still keeps the composited
        // foreground at or above dimFloor. 60 iterations → 2^−60 ≈ 10^−18 precision —
        // far below any representable Double difference at this range.
        // After the search, `hi` is the minimum opacity that clears the floor.
        // Ceiling to the nearest 0.01 for conservatism (slightly more opaque = safer).
        // Cap at 0.7 so palettes with high inherent contrast (e.g. afk-light Lc 102.8)
        // still get the intended dimming effect rather than near-zero opacity.
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2.0
            let compositedLc = APCA.lc(text: fg.composited(over: bg, alpha: mid), background: bg)
            if compositedLc >= dimFloor { hi = mid } else { lo = mid }
        }
        // `hi` is the minimum opacity that clears the floor. Ceiling to the nearest 0.01 so
        // the gate can assert exact values without floating-point jitter, and so the result
        // always errs toward slightly more opaque (safer) rather than slightly more transparent.
        let minSafe = ceil(hi * 100) / 100

        // Apply the 0.7 cap ONLY when minSafe is ≤ 0.7 — meaning the palette has enough
        // inherent contrast that we can dim to 0.7 and still clear the floor. If minSafe is
        // ABOVE 0.7 (tokyo-night's case: binary-search gives 0.71, because 0.70 puts it at
        // Lc 44.5), we MUST return minSafe rather than 0.7, otherwise the constraint is
        // silently violated. The intent of the 0.7 cap is to avoid near-zero opacity on
        // high-contrast palettes (e.g. afk-light, which could dim to 0.38 and still clear
        // the floor) — not to override the floor.
        return minSafe <= 0.7 ? 0.7 : minSafe
    }
}
