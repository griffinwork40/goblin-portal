// check-image-decode-sixel.swift — patch 0020 (bound sixel parsing, #280) cases for
// check-image-decode.sh, split from check-image-decode-harness.swift for the 350-LOC ceiling.
//
// Each case prints "BEGIN <case>" (flushed) before it runs. A trap in the vendored
// SixelDcsHandler kills the process, so the shell half uses that marker to tell "died in
// the declared case" (a real defect / a caught mutant) from an environmental failure.
// Every malformed case is followed by a VALID sixel: the parser must still be in sync.
import AppKit
@testable import SwiftTerm

func begin(_ name: String) { print("BEGIN \(name)"); fflush(stdout) }

func sixel(_ body: String) -> String { "\u{1b}Pq\(body)\u{1b}\\" }

/// 4x6 solid red, band closed with `-`: the positive oracle, also used as the follow-up.
let validSixel = sixel("#1;2;100;0;0#1~~~~-")

@MainActor func runSixel(_ want: (String) -> Bool) {
    let redLE: UInt32 = 0xFF00_00FF
    if want("sixel-valid") {
        begin("sixel-valid")
        // Without this every "dropped" case below could pass on a path that inserts nothing.
        // Raster attributes and a palette entry with missing fields ride along: both ignored.
        let (v, _) = makeView()
        v.feed(text: sixel("\"1;1;4;6#2;2;100#1;2;100;0;0#1~~~~-"))
        let imgs = images(v)
        let px = (imgs.first as? TerminalView.AppleImage).map { pixels(of: $0.image) } ?? []
        let hits = px.filter { $0 == redLE }.count
        check("sixel-valid", imgs.count == 1 && hits >= 24,
              "images=\(imgs.count) exact-red pixels=\(hits) of \(px.count) (want >=24)")
    }
    if want("sixel-unclosed") {
        begin("sixel-unclosed")
        // The #280 sequence verbatim: `!N` is a repeat introducer with no number, so the
        // repeat is ignored and `N`, `~` are two sixels in a band never closed by `$`/`-`.
        // Upstream sized a 0-byte bitmap and trapped (Index out of range). Now the open band
        // counts: a 2x6 image, then the follow-up.
        let (v, _) = makeView()
        v.feed(text: sixel("#0;2;100;0;0 #0 !N~"))
        v.feed(text: validSixel)
        let imgs = images(v)
        let w = (imgs.first as? TerminalView.AppleImage)?.image.size.width ?? -1
        check("sixel-unclosed", imgs.count == 2 && w == 2,
              "images=\(imgs.count) first width=\(w) (want 2 images, first 2 px wide)")
    }
    if want("sixel-overflow") {
        begin("sixel-overflow")
        // Numbers past Int.max in a colour register and in a repeat count: upstream's
        // `10 * existing + digit` trapped on overflow. Saturated, the repeat is over the
        // side cap and the image is dropped; the follow-up still inserts.
        let (v, _) = makeView()
        v.feed(text: sixel("#99999999999999999999;2;0;0;0#0!99999999999999999999~-"))
        v.feed(text: validSixel)
        check("sixel-overflow", images(v).count == 1, "images=\(images(v).count) (want 1: follow-up only)")
    }
    if want("sixel-oversize") {
        begin("sixel-oversize")
        // 15 bytes asking for 16384x6: 0018's side cap would drop the INSERT, but only
        // 0020 stops the bitmap being ALLOCATED from input. Drive the handler directly to
        // observe the allocation.
        let (v, _) = makeView()
        let h = SixelDcsHandler(terminal: v.getTerminal())
        h.hook(collect: [], parameters: .empty, flag: 0)
        h.put(data: Array("#0!8192~!8192~-".utf8)[...])
        h.unhook()
        v.feed(text: validSixel)
        check("sixel-oversize", h.pixels.isEmpty && images(v).count == 1,
              "allocated pixel bytes=\(h.pixels.count) images=\(images(v).count) (want 0, 1)")
    }
    if want("sixel-short-buffer") {
        begin("sixel-short-buffer")
        // 0018's `bytes.count >= width * height * 4` guard, reached directly (nothing in the
        // sixel path can produce a short buffer any more). NOT falsified: removing the guard
        // is an equivalent mutant — CGImage(width:height:...provider:) itself returns nil for
        // a provider shorter than height*bytesPerRow (measured: 4x4 with 0/1/48/63 bytes,
        // 100x100 with 39999, 8192x1 with 4), so the guard is defence in depth, not the stop.
        let (v, _) = makeView()
        let t = v.getTerminal()
        var short = [UInt8](repeating: 255, count: 4 * 4 * 4 - 1)
        v.createImageFromBitmap(source: t, bytes: &short, width: 4, height: 4)
        var ok = [UInt8](); for _ in 0..<16 { ok += [255, 0, 0, 255] }
        v.createImageFromBitmap(source: t, bytes: &ok, width: 4, height: 4)
        check("sixel-short-buffer", images(v).count == 1, "images=\(images(v).count) (want 1: short dropped)")
    }
}
