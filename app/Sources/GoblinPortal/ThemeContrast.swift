//
//  ThemeContrast.swift
//  Measuring a palette: WCAG 2.1, APCA, OKLab distance, and dichromacy simulation.
//
//  **Pure and view-free — Foundation only, on purpose**, so `check-theme-contrast.sh`
//  can compile it beside `ThemeValues.swift` with no UI framework linked. That gate is
//  the only reason a theme in this repo can claim to be legible: there is no test target
//  and no CI, so an unmeasured palette is an opinion.
//
//  Separate from `Theme.swift` because that file is the AppKit *bridge* (it turns hex
//  into `NSColor` and hands it to two engines) and separate from `ThemeValues.swift`
//  because that file is data. One concern each — the split the repo asks for.
//
//  Why both WCAG and APCA, when they disagree:
//
//  WCAG 2.1's contrast ratio is the accessibility standard people cite and the one
//  `Config.lightChromeCutoff` is built on, so it stays. But it materially OVERSTATES
//  contrast on dark backgrounds — its own successor documentation says so — and every
//  colour in this app sits on a near-black background. Measured on the shipped palettes,
//  WCAG rates Tokyo Night's normal ANSI slots a comfortable 4.9–9.2:1 (all "AA pass")
//  while APCA puts the worst of them at Lc 49, below the readable floor. The APCA number
//  is the one that matched what the rendered previews actually looked like, so it is the
//  one the thresholds are written against. WCAG is reported alongside, not trusted alone.
//
//  APCA is implemented here as 0.98G-4g. It is a draft model, not a normative standard;
//  it is used as an internal design instrument, never as an accessibility claim.
//

import Foundation

// MARK: - sRGB

/// A colour as three sRGB channels in 0…1. Not `NSColor`: this file must not import
/// AppKit, and the parsing that produces one of these must be assertable by the gate.
struct RGB {
    let r: Double, g: Double, b: Double

    /// Parse `#rrggbb` / `rrggbb`, and the 3-digit shorthand. Returns nil on anything
    /// unparseable, mirroring `NSColor.fromHex` in `Theme.swift` so that a hex string
    /// accepted by one is accepted by the other — the gate asserts that agreement.
    init?(hex raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xff) / 255
        g = Double((v >> 8) & 0xff) / 255
        b = Double(v & 0xff) / 255
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// The inverse of `init?(hex:)`, mirroring `NSColor.hexString` in `Theme.swift`.
    ///
    /// Exists for *derived* colours — a composited comment colour or a lifted rail has no hex
    /// literal anywhere to name it, so a gate failure would otherwise have to report three
    /// Doubles. Clamped rather than trusted: compositing keeps values in 0…1, but a future
    /// caller doing arithmetic outside that range should produce a wrong colour name, not a
    /// crash inside a failure message.
    var hex: String {
        func channel(_ c: Double) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
    }

    /// `NSColor.blended(withFraction:of:)`, reproduced in pure arithmetic.
    ///
    /// Interpolates the GAMMA-ENCODED components, not linear light — that is what AppKit
    /// does, and matching it is the whole point: this exists so the tab strip's derived
    /// colours can be measured without linking AppKit. Getting the colour space wrong here
    /// would make the gate test a colour the app never draws.
    func blended(withFraction f: Double, toward other: RGB) -> RGB {
        RGB(r: r + (other.r - r) * f, g: g + (other.g - g) * f, b: b + (other.b - b) * f)
    }

    /// This colour drawn at `alpha` over an opaque `backdrop`. Source-over compositing,
    /// again on the encoded components, for the same reason as `blended`.
    func composited(over backdrop: RGB, alpha: Double) -> RGB {
        backdrop.blended(withFraction: alpha, toward: self)
    }

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)

    /// Gamma-expanded channels. Luminance is defined on linear light; skipping this
    /// misjudges mid-tones badly, which is the same note `NSColor.relativeLuminance`
    /// carries in `Theme.swift`.
    var linear: (Double, Double, Double) {
        func f(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return (f(r), f(g), f(b))
    }
}

// MARK: - WCAG 2.1

enum WCAG {
    /// Relative luminance, 0…1. Must agree with `NSColor.relativeLuminance`
    /// (`Theme.swift`) — the gate asserts it, because `Config.appearance` derives the
    /// window's light/dark chrome from that one and the thresholds here from this one.
    static func luminance(_ c: RGB) -> Double {
        let (r, g, b) = c.linear
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Contrast ratio, 1…21. AA wants 4.5:1 for body text, 3:1 for large.
    /// Convenience overloads, so the two gates can assert the SAME formula the app uses
    /// without each rebuilding an `RGB` first. `luminance(hex:)` returns nil on
    /// unparseable input rather than trapping — a gate wants to report a bad hex, not die.
    static func luminance(hex: String) -> Double? { RGB(hex: hex).map(luminance) }
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        luminance(RGB(r: red, g: green, b: blue))
    }

    /// The background luminance above which the app dresses its window chrome LIGHT —
    /// `AppConfig.appearance` (`Config.swift`) compares this to the effective background
    /// and returns `.aqua` or `.darkAqua`.
    ///
    /// It lives HERE, beside the formula it is compared against, and not in `Config.swift`,
    /// for one reason: `Config.swift` imports AppKit, so a cutoff declared there cannot be
    /// linked by either gate and the number the app actually branches on would go
    /// unasserted. Both `check-theme-contrast.sh` and `check-light-theme.sh` compile this
    /// file, so both test the real symbol instead of a copy of its value. `Config.swift:176`
    /// is the sole call site and converts at the comparison — there is deliberately no
    /// `Config`-side alias, because a second name for one number is how the two `0.179`s
    /// this consolidation removed came to exist in the first place.
    ///
    /// 0.179 is the midpoint of the sRGB range in *perceived* terms (the luminance of
    /// 50% grey is 0.216, and #767676 — the classic "mid" web grey — is 0.179), which is
    /// why it beats a naive 0.5 on the raw component.
    static let lightChromeCutoff: Double = 0.179

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

// MARK: - APCA 0.98G-4g

/// Lightness contrast, reported as absolute Lc 0…~108.
///
/// Thresholds used by the gate, from APCA's own guidance: 90 preferred body text,
/// 75 minimum body text, 60 minimum readable non-body, 45 large/headline minimum,
/// 30 absolute floor, 15 the invisibility threshold for non-text.
///
/// Note the `loClip`: below roughly Lc 10 the model deliberately reports exactly 0,
/// because it is a *text readability* model and there is no meaningful readability left.
/// That is why ANSI 0 must never be judged by this function — it is a surface a hair
/// above the background, so its Lc is 0 by construction and a threshold on it is
/// unsatisfiable. It is judged by `OKLab.distance` from the background instead. This
/// exact mistake silently flattened the first palette search; see the design doc.
enum APCA {
    private static let trc = 2.4, blkThrs = 0.022, blkClmp = 1.414
    private static let normBG = 0.56, normTXT = 0.57, revTXT = 0.62, revBG = 0.65
    private static let scale = 1.14, offset = 0.027, loClip = 0.1, deltaYmin = 0.0005

    private static func y(_ c: RGB) -> Double {
        // APCA uses a simple power curve, NOT the sRGB piecewise transfer function.
        let v = 0.2126729 * pow(c.r, trc) + 0.7151522 * pow(c.g, trc) + 0.0721750 * pow(c.b, trc)
        return v < blkThrs ? v + pow(blkThrs - v, blkClmp) : v
    }

    static func lc(text: RGB, background: RGB) -> Double {
        let yt = y(text), yb = y(background)
        guard abs(yb - yt) >= deltaYmin else { return 0 }
        let out: Double
        if yb > yt {                                    // dark text on a light background
            let s = (pow(yb, normBG) - pow(yt, normTXT)) * scale
            out = s < loClip ? 0 : s - offset
        } else {                                        // light text on a dark background
            let s = (pow(yb, revBG) - pow(yt, revTXT)) * scale
            out = s > -loClip ? 0 : s + offset
        }
        return abs(out * 100)
    }
}

// MARK: - OKLab

/// Perceptual distance and lightness. Used for three questions WCAG and APCA cannot
/// answer: is ANSI 0 visible against the background without becoming a second
/// background; is a bright slot actually distinguishable from its normal counterpart;
/// and do two colours still differ once a colour-blind reader's cones have collapsed
/// them. Matrices are Ottosson's (bottosson.github.io/posts/oklab).
enum OKLab {
    static func from(_ c: RGB) -> (L: Double, a: Double, b: Double) {
        let (r, g, bl) = c.linear
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    /// dE-OK. Read as: ≥ 0.10 clearly different, 0.05–0.10 marginal, < 0.05 a collision.
    static func distance(_ x: RGB, _ y: RGB) -> Double {
        let a = from(x), b = from(y)
        return sqrt(pow(a.L - b.L, 2) + pow(a.a - b.a, 2) + pow(a.b - b.b, 2))
    }

    static func lightness(_ c: RGB) -> Double { from(c).L }
}

// MARK: - Colour-vision deficiency

/// Dichromacy simulation, Viénot–Brettel–Mollon (1999) via an LMS projection.
///
/// This matters more for a terminal than for most apps: red–green deficiency affects
/// roughly 8% of men, and red-versus-green is the exact axis `git diff`, test results
/// and error-versus-success output ride on. Protanopia and deuteranopia both collapse
/// that axis, which is why the shipped palette staggers lightness across the ring —
/// lightness is the only channel that survives, so it has to carry the signal.
enum CVD {
    enum Kind: String, CaseIterable { case protanopia, deuteranopia }

    static func simulate(_ c: RGB, _ kind: Kind) -> RGB {
        let (r, g, b) = c.linear
        var l = 17.8824 * r + 43.5161 * g + 4.11935 * b
        var m = 3.45565 * r + 27.1554 * g + 3.86714 * b
        let s = 0.0299566 * r + 0.184309 * g + 1.46709 * b
        switch kind {
        case .protanopia:   l = 2.02344 * m - 2.52581 * s
        case .deuteranopia: m = 0.494207 * l + 1.24827 * s
        }
        let lr =  0.080944 * l - 0.130504 * m + 0.116721 * s
        let lg = -0.0102485 * l + 0.0540194 * m - 0.113615 * s
        let lb = -0.000365294 * l - 0.00412163 * m + 0.693513 * s
        func enc(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return RGB(r: enc(lr), g: enc(lg), b: enc(lb))
    }

    /// The worst separation across both dichromacies — the number a threshold is set
    /// against, since a palette is only as safe as its weaker case.
    static func worstDistance(_ x: RGB, _ y: RGB) -> Double {
        Kind.allCases.map { OKLab.distance(simulate(x, $0), simulate(y, $0)) }.min() ?? 0
    }
}

// MARK: - SelectionPairing

/// Whether a selection highlight can be painted *under* a given foreground at all.
///
/// A selection background is the one theme colour that is never seen alone: it is always
/// read through the text sitting on it, so the only question worth asking about it is a
/// question about a PAIR. §5h of the harness has asked exactly that since the palettes
/// landed — but only of `umber`, and only of a pair both halves of which come from the same
/// palette. Neither restriction survives contact with a config file.
///
/// `Config+Theme.swift` lets a user override `background` and `foreground` and gives them no
/// way to override `selection` (the one `ThemePalette` field with no override — issue #29).
/// So `{"theme": {"background": "#FFFFFF", "foreground": "#1A1A1A"}}` bases on `umber`,
/// replaces two fields, and keeps `#453021` — a near-black selection under near-black text,
/// measuring **APCA Lc 0.0**. Not "degraded": invisible. That configuration is expressible
/// today and documented as such (`Config.appearance` derives `.aqua` above
/// `lightChromeCutoff` precisely because a light user background is expressible), so the
/// pairing has to be decided at runtime rather than asserted once for the shipped presets.
///
/// Pure and Foundation-only like the rest of this file, so `check-theme-contrast.sh` holds
/// the rule to a number while the AppKit half stays a three-line lookup in the pane.
enum SelectionPairing {
    /// The floor a foreground must clear when read against a selection highlight.
    ///
    /// 60, not `SyntaxPalette.readableFloor`'s 45, and the gap is deliberate: 45 is APCA's
    /// "resolvable at any size" floor for a glyph you are merely reading, while selected text
    /// is text you are reading *and acting on* — the number §5h has asserted for umber since
    /// the palettes landed. Declared here rather than in the harness because a threshold that
    /// lives only in the test is a threshold the app cannot honour; the gate now reads this
    /// one instead of holding its own copy.
    static let readableFloor: Double = 60

    /// Is `foreground` readable when drawn on a `selection` highlight?
    ///
    /// Answering false does not mean the theme is broken — it means this particular pair is,
    /// and the caller should fall back to the system pair rather than install half of a
    /// measured one.
    static func isReadable(foreground: RGB, on selection: RGB) -> Bool {
        APCA.lc(text: foreground, background: selection) >= readableFloor
    }
}
