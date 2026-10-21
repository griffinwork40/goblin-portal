// Payloads for check-image-render.sh: one solid-colour image per protocol, built at run time
// from the grid the pane actually laid out, so every expected rectangle is derived, never
// typed in. Compiled beside check-image-render-harness.swift (main.swift) and the render-parity
// capture + metrics files it reuses unchanged.
//
// The colour is deliberately asymmetric (R 230, G 60, B 20): an RGB/BGR channel swap reads
// (20, 60, 230) and a premultiplication or gamma slip moves G by far more than the tolerance,
// so "the right colour" cannot be satisfied by a near miss of the wrong kind.
import AppKit

let imgESC = "\u{1b}"
let imgST = "\u{1b}\\"
let paint = (r: 230, g: 60, b: 20)
/// Home, clear, hide the cursor (a separate subview under Core Text, a quad under Metal),
/// then put the cursor at 0-based (row, col).
func at(_ row: Int, _ col: Int) -> String { "\(imgESC)[?25l\(imgESC)[2J\(imgESC)[H\(imgESC)[\(row + 1);\(col + 1)H" }

/// Where every image case draws: 0-based row 1, column 3.
let imgRow = 1, imgCol = 3

/// A solid PNG, w x h px, in `paint`, sRGB-tagged.
func solidPNG(w: Int, h: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: cs, components: [CGFloat(paint.r) / 255, CGFloat(paint.g) / 255,
                                                          CGFloat(paint.b) / 255, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let out = NSMutableData()
    guard let img = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
    return out as Data
}

/// OSC 1337 inline=1, 4 x 2 cells (Terminal.swift osciTerm2 -> TerminalView.createImage ->
/// insertImage). `inline` is a parameter so the falsification-free control (inline=0, a
/// download, must paint nothing) uses the same bytes.
func osc1337(cols: Int = 4, rows: Int = 2, inline: Int = 1) -> String {
    let b64 = solidPNG(w: 8, h: 4).base64EncodedString()
    return "\(imgESC)]1337;File=inline=\(inline);width=\(cols);height=\(rows);preserveAspectRatio=0:\(b64)\u{07}"
}

/// Sixel, w x (6 * bands) px of colour register 1 = `paint` in RGB percent (sixel's own unit).
/// At 2x an `auto`-sized sixel image of N px occupies exactly N device px (insertImage's
/// getPixels .auto divides by the display scale), so its expected rect needs no cell maths.
func sixel(w: Int, bands: Int) -> String {
    func pct(_ v: Int) -> Int { Int((Double(v) * 100 / 255).rounded()) }
    let band = "#1!\(w)~"
    let body = Array(repeating: band, count: bands).joined(separator: "-")
    return "\(imgESC)Pq#1;2;\(pct(paint.r));\(pct(paint.g));\(pct(paint.b))\(body)\(imgST)"
}

/// Kitty graphics APC G: a=T (transmit + display), f=32 raw RGBA, 8 x 4 px, c/r cells, q=2 quiet.
func kitty(cols: Int = 4, rows: Int = 2) -> String {
    var px = [UInt8]()
    for _ in 0..<(8 * 4) { px += [UInt8(paint.r), UInt8(paint.g), UInt8(paint.b), 255] }
    return "\(imgESC)_Ga=T,f=32,s=8,v=4,c=\(cols),r=\(rows),i=7,q=2;\(Data(px).base64EncodedString())\(imgST)"
}

/// A full block in a truecolour green: a cell whose colour is exact in both renderers (block
/// elements are geometry, not a font -- check-render-parity.sh measured them byte-identical).
let marker = "\(imgESC)[38;2;0;200;0m\u{2588}\(imgESC)[0m"
let markerRGB = (r: 0, g: 200, b: 0)
