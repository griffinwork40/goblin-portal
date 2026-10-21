// check-image-decode-harness.swift — the assertions for check-image-decode.sh (patch 0018).
//
// Owns: feeding OSC 1337 / sixel / plain OSC bytes into a real, WINDOWLESS SwiftTerm
// TerminalView (AppKit NSView, never put on screen — no window server needed, the same
// object the app's GoblinPortalTerminalView subclasses) and asserting what landed in the
// buffer. Fixtures are built here with ImageIO so no binary blobs live in the repo.
// Prints "PASS <case>" / "FAIL <case>: why"; exit 0 all pass, 1 any failure. The shell
// half maps exits and runs falsification. Split from the .sh for the 350-LOC ceiling.
import AppKit
import ImageIO
@testable import SwiftTerm

final class Recorder: TerminalViewDelegate {
    var iterm: [String] = []
    var titles: [String] = []
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) { titles.append(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        iterm.append(String(decoding: content.prefix(64), as: UTF8.self))
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor func makeView() -> (TerminalView, Recorder) {
    let v = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let r = Recorder()
    v.terminalDelegate = r
    return (v, r)
}

@MainActor func images(_ v: TerminalView) -> [TerminalImage] {
    var out: [TerminalImage] = []
    let t = v.getTerminal()
    for row in 0..<t.buffer.lines.count { out += t.buffer.lines[row].images ?? [] }
    return out
}

func encode(_ w: Int, _ h: Int, type: String, rgba: (UInt8, UInt8, UInt8, UInt8)) -> Data {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for i in stride(from: 0, to: px.count, by: 4) {
        px[i] = rgba.0; px[i+1] = rgba.1; px[i+2] = rgba.2; px[i+3] = rgba.3
    }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = ctx.makeImage()!
    let out = NSMutableData()
    let dst = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
    return out as Data
}

func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes {
        c ^= UInt32(b)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
    }
    return ~c
}

/// A ~45-byte PNG whose IHDR claims 100000 x 100000 (40 GB RGBA if decoded) and has no
/// pixel data at all — the decompression-bomb header the size check must stop.
func forgedHugePNG() -> Data {
    func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let tb = Array(type.utf8) + body
        return be(UInt32(body.count)) + tb + be(crc32(tb))
    }
    let ihdr = be(100_000) + be(100_000) + [8, 6, 0, 0, 0]
    return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IEND", []))
}

func osc1337(_ payload: Data, inline: Int = 1, extra: String = "") -> String {
    "\u{1b}]1337;File=inline=\(inline)\(extra):\(payload.base64EncodedString())\u{07}"
}

/// RGBA of every pixel of an inserted stripe, drawn into a known RGBA8 bitmap.
func pixels(of image: NSImage) -> [UInt32] {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
    var buf = [UInt32](repeating: 0, count: cg.width * cg.height)
    let ctx = CGContext(data: &buf, width: cg.width, height: cg.height, bitsPerComponent: 8,
                        bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return buf
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ why: @autoclosure () -> String) {
    if ok { print("PASS \(name)") } else { print("FAIL \(name): \(why())"); failures += 1 }
}

@MainActor func run() {
    let only = ProcessInfo.processInfo.environment["IMAGE_DECODE_ONLY"]
    func want(_ n: String) -> Bool { only == nil || only == n }
    let red: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 255)
    let png4 = encode(4, 4, type: "public.png", rgba: red)

    if want("png-inline") {
        // Case 1: the positive oracle — a 4x4 solid red PNG is decoded and inserted, and
        // its pixels are exactly red. Without this every "rejected" case could pass on a
        // path that inserts nothing at all.
        let (v, _) = makeView()
        v.feed(text: osc1337(png4))
        let imgs = images(v)
        let px = (imgs.first as? TerminalView.AppleImage).map { pixels(of: $0.image) } ?? []
        let redLE: UInt32 = 0xFF00_00FF  // bytes R,G,B,A = FF,00,00,FF in memory
        let hits = px.filter { $0 == redLE }.count
        check("png-inline", imgs.count == 1 && hits >= 16,
              "images=\(imgs.count) exact-red pixels=\(hits) of \(px.count) (want >=16)")
    }
    if want("inline0-iterm") {
        // Case 2: inline=0 is a download, not a display: it must reach iTermContent and
        // never createImage.
        let (v, r) = makeView()
        v.feed(text: osc1337(png4, inline: 0))
        check("inline0-iterm", images(v).isEmpty && r.iterm.count == 1,
              "images=\(images(v).count) iTermContent calls=\(r.iterm.count)")
    }
    if want("oversize-encoded") {
        // Case 3: a VALID PNG padded with trailing zeros (ImageIO ignores bytes after
        // IEND) to > 32 MiB encoded. Only the encoded-size cap can stop it.
        var big = png4
        big.append(Data(count: 25 * 1024 * 1024))
        let (v, _) = makeView()
        v.feed(text: osc1337(big))
        v.feed(text: osc1337(png4))  // parser + decoder still work afterwards
        check("oversize-encoded", images(v).count == 1,
              "images=\(images(v).count) (want 1: oversize dropped, follow-up inserted)")
    }
    if want("pdf-rejected") {
        // Case 4: PDF — NSImage(data:) renders it, ImageIO reports it with no pixel size.
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 32, height: 32)
        let c = CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &box, nil)!
        c.beginPDFPage(nil); c.setFillColor(.black); c.fill(box); c.endPDFPage(); c.closePDF()
        let decodable = NSImage(data: pdf as Data) != nil
        let (v, _) = makeView()
        v.feed(text: osc1337(pdf as Data))
        check("pdf-rejected", decodable && images(v).isEmpty,
              "NSImage decodes PDF=\(decodable) images=\(images(v).count)")
    }
    if want("type-allowlist") {
        // Case 5: a real raster outside the allowlist (TGA: ImageIO reports pixel size,
        // NSImage decodes it). Only the type allowlist can stop it.
        let tga = encode(4, 4, type: "com.truevision.tga-image", rgba: red)
        let decodable = NSImage(data: tga) != nil
        let (v, _) = makeView()
        v.feed(text: osc1337(tga))
        check("type-allowlist", decodable && images(v).isEmpty,
              "NSImage decodes TGA=\(decodable) images=\(images(v).count)")
    }
    if want("forged-huge-header") {
        // Case 6: 100000^2 claimed in a 45-byte header; must be dropped without a crash.
        let (v, _) = makeView()
        v.feed(text: osc1337(forgedHugePNG()))
        check("forged-huge-header", images(v).isEmpty, "images=\(images(v).count)")
    }
    if want("dimension-cap") {
        // Case 7: a REAL, decodable 8193x1 PNG (tiny file) — one pixel over the side cap.
        // Only the header dimension check can stop it.
        let wide = encode(8193, 1, type: "public.png", rgba: red)
        let decodable = NSImage(data: wide) != nil
        let (v, _) = makeView()
        v.feed(text: osc1337(wide))
        check("dimension-cap", decodable && images(v).isEmpty,
              "NSImage decodes=\(decodable) images=\(images(v).count)")
    }
    // NOT a case: sixel. Feeding `ESC P q #0;2;100;0;0 #0 !N~ ESC \\` traps inside the
    // vendored SixelDcsHandler (Index out of range) BEFORE createImageFromBitmap is reached,
    // independent of 0018 — a pre-existing upstream parser bug, recorded for a follow-up.
    // 0018's sixel side bound is therefore unexercised here.
    if want("osc-overlimit") {
        // Case 9: a non-1337 OSC (title) over the 65 MiB accumulation cap is dropped, and
        // the very next OSC still works — the parser consumed to the terminator in sync.
        let (v, r) = makeView()
        var bytes = Array("\u{1b}]2;".utf8)
        bytes += [UInt8](repeating: 0x78, count: EscapeSequenceParser.maximumOscBytes + 1024)
        bytes += Array("\u{07}\u{1b}]2;ok\u{07}".utf8)
        v.feed(byteArray: bytes[...])
        check("osc-overlimit", r.titles == ["ok"],
              "titles=\(r.titles.map { $0.count > 8 ? "<\($0.count) bytes>" : $0 })")
    }
}

MainActor.assumeIsolated { run() }
exit(failures == 0 ? 0 : 1)
