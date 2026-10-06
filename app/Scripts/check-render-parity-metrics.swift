// Pixel metrics for check-render-parity.sh — compiled beside check-render-parity-harness.swift
// (copied to main.swift) and check-render-parity-capture.swift. Foundation + CoreGraphics only,
// so the gate needs no python/PIL: the measurements the 2026-10-05 rendering audit took with
// diff.py / shift.py (.afk/research/rendering-audit-2026-10-05.md, P1) are re-derived here.
//
// Every metric works on an RGBA8 sRGB buffer and a pixel Region, and every threshold is the
// one the audit used: a pixel "differs" when any channel moves by more than 8 (diff.py's
// `v>8`), and a pixel is "ink" when any channel sits more than 8 from the background.
import CoreGraphics
import ImageIO
import Foundation

/// An RGBA8 sRGB image, row 0 at the TOP (CGContext memory order).
struct Img {
    let w: Int
    let h: Int
    var px: [UInt8]

    @inline(__always) func chan(_ x: Int, _ y: Int, _ c: Int) -> Int { Int(px[(y * w + x) * 4 + c]) }

    /// Largest per-channel distance between two pixels (diff.py's `lighter(r,g,b)` of |A-B|).
    @inline(__always) func delta(_ o: Img, _ x: Int, _ y: Int, dx: Int = 0, dy: Int = 0) -> Int {
        let i = (y * w + x) * 4, j = ((y + dy) * o.w + (x + dx)) * 4
        return max(abs(Int(px[i]) - Int(o.px[j])), abs(Int(px[i + 1]) - Int(o.px[j + 1])),
                   abs(Int(px[i + 2]) - Int(o.px[j + 2])))
    }

    /// Distance of one pixel from the background colour: the "ink" at that pixel.
    @inline(__always) func inkAt(_ x: Int, _ y: Int, bg: (Int, Int, Int)) -> Int {
        max(abs(chan(x, y, 0) - bg.0), abs(chan(x, y, 1) - bg.1), abs(chan(x, y, 2) - bg.2))
    }
}

/// A half-open pixel rectangle [x0, x1) x [y0, y1).
struct Region: CustomStringConvertible {
    var x0, y0, x1, y1: Int
    var description: String { "x\(x0)-\(x1 - 1) y\(y0)-\(y1 - 1)" }
    func contains(_ o: Region) -> Bool { o.x0 >= x0 && o.y0 >= y0 && o.x1 <= x1 && o.y1 <= y1 }
}

let differThreshold = 8
let inkThreshold = 8

struct DiffStats {
    var count = 0
    var maxDelta = 0
    var bbox: Region?
}

/// diff.py, in Swift: how many pixels differ by more than 8 in any channel, the largest
/// delta, and the bounding box of the differing pixels.
func diff(_ a: Img, _ b: Img, in r: Region) -> DiffStats {
    var s = DiffStats()
    for y in r.y0..<r.y1 {
        for x in r.x0..<r.x1 {
            let d = a.delta(b, x, y)
            s.maxDelta = max(s.maxDelta, d)
            guard d > differThreshold else { continue }
            s.count += 1
            if var bb = s.bbox {
                bb.x0 = min(bb.x0, x); bb.y0 = min(bb.y0, y)
                bb.x1 = max(bb.x1, x + 1); bb.y1 = max(bb.y1, y + 1)
                s.bbox = bb
            } else {
                s.bbox = Region(x0: x, y0: y, x1: x + 1, y1: y + 1)
            }
        }
    }
    return s
}

struct InkStats {
    var total = 0          // sum over the region of per-pixel ink (0...255)
    var bbox: Region?      // bounding box of pixels whose ink exceeds the threshold
}

func ink(_ img: Img, bg: (Int, Int, Int), in r: Region) -> InkStats {
    var s = InkStats()
    for y in r.y0..<r.y1 {
        for x in r.x0..<r.x1 {
            let v = img.inkAt(x, y, bg: bg)
            s.total += v
            guard v > inkThreshold else { continue }
            if var bb = s.bbox {
                bb.x0 = min(bb.x0, x); bb.y0 = min(bb.y0, y)
                bb.x1 = max(bb.x1, x + 1); bb.y1 = max(bb.y1, y + 1)
                s.bbox = bb
            } else {
                s.bbox = Region(x0: x, y0: y, x1: x + 1, y1: y + 1)
            }
        }
    }
    return s
}

/// Largest disagreement, in pixels, between two ink bounding boxes along any edge.
/// nil-vs-nil is 0 (both blank); nil-vs-something is "infinitely" far apart.
func bboxEdgeError(_ a: Region?, _ b: Region?) -> Int {
    switch (a, b) {
    case (nil, nil): return 0
    case let (a?, b?): return max(abs(a.x0 - b.x0), abs(a.y0 - b.y0), abs(a.x1 - b.x1), abs(a.y1 - b.y1))
    default: return Int.max
    }
}

/// shift.py, in Swift: the integer (dx, dy) in [-r, r]^2 that best aligns B onto A, by sum of
/// absolute channel difference over the region inset by r. Ties go to the smaller shift, so a
/// pair that is already aligned reports (0, 0) rather than an arbitrary equal-cost neighbour.
func bestShift(_ a: Img, _ b: Img, in reg: Region, radius r: Int = 2) -> (dx: Int, dy: Int) {
    let inner = Region(x0: max(reg.x0, r), y0: max(reg.y0, r), x1: min(reg.x1, a.w - r), y1: min(reg.y1, a.h - r))
    var best = (cost: Int.max, mag: Int.max, dx: 0, dy: 0)
    for dy in -r...r {
        for dx in -r...r {
            var cost = 0
            for y in inner.y0..<inner.y1 { for x in inner.x0..<inner.x1 { cost += a.delta(b, x, y, dx: dx, dy: dy) } }
            let mag = abs(dx) + abs(dy)
            if cost < best.cost || (cost == best.cost && mag < best.mag) { best = (cost, mag, dx, dy) }
        }
    }
    return (best.dx, best.dy)
}

/// Differing pixels that are NOT anti-aliasing fringe. A differing pixel is fringe when it
/// sits on a colour transition in BOTH images: its 3x3 neighbourhood holds some pixel more than
/// 8 away from it, in A and in B. That is where two rasterizers legitimately disagree about
/// coverage. A difference where EITHER image is locally flat is a real defect: a stray mark on
/// open background (flat in the clean image), a missing or wrongly-coloured stroke (flat in the
/// other), a shifted glyph (its newly exposed interior is flat). Deliberately independent of
/// the background colour, so inverse video and coloured backgrounds are judged the same way.
func nonFringeDiffs(_ a: Img, _ b: Img, in r: Region) -> Int {
    func flat(_ img: Img, _ x: Int, _ y: Int) -> Bool {
        for yy in max(0, y - 1)...min(img.h - 1, y + 1) {
            for xx in max(0, x - 1)...min(img.w - 1, x + 1) where img.delta(img, x, y, dx: xx - x, dy: yy - y) > differThreshold {
                return false
            }
        }
        return true
    }
    var n = 0
    for y in r.y0..<r.y1 {
        for x in r.x0..<r.x1 where a.delta(b, x, y) > differThreshold {
            if flat(a, x, y) || flat(b, x, y) { n += 1 }
        }
    }
    return n
}

/// Write an Img as PNG (debug only: `dump=<dir>`). ImageIO ships with macOS.
func writePNG(_ img: Img, to path: String) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    var bytes = img.px
    bytes.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: img.w, height: img.h, bitsPerComponent: 8,
                                  bytesPerRow: img.w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
