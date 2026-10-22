// check-image-decode-multipart.swift — patch 0019 cases for check-image-decode.sh.
//
// Owns: the OSC 1337 MultipartFile / FilePart / FileEnd assertions (iTerm2 3.5+, modern
// imgcat's default), compiled beside check-image-decode-harness.swift (which owns main,
// the fixtures and check()). Split out for the 350-LOC ceiling.
// The "imgcat-real" fixture (fixtures/imgcat-multipart-16x16.bin) is the VERBATIM stdout
// of https://iterm2.com/utilities/imgcat run on a 16x16 PNG under TERM=xterm-256color, no
// tmux: one MultipartFile header, 8 x 200-byte FilePart chunks, FileEnd.
import AppKit
@testable import SwiftTerm

func mpHeader(inline: Int = 1, extra: String = "") -> String {
    "\u{1b}]1337;MultipartFile=inline=\(inline)\(extra)\u{07}"
}
func mpPart(_ b64: Substring) -> String { "\u{1b}]1337;FilePart=\(b64)\u{07}" }
let mpEnd = "\u{1b}]1337;FileEnd\u{07}"

/// The whole transfer as one string, base64 split into `parts` near-equal chunks.
func multipart(_ payload: Data, parts: Int, inline: Int = 1, extra: String = "") -> String {
    let b64 = payload.base64EncodedString()
    let step = max(1, (b64.count + parts - 1) / parts)
    var out = mpHeader(inline: inline, extra: extra)
    var i = b64.startIndex
    while i < b64.endIndex {
        let j = b64.index(i, offsetBy: step, limitedBy: b64.endIndex) ?? b64.endIndex
        out += mpPart(b64[i..<j]); i = j
    }
    return out + mpEnd
}

@MainActor func runMultipart(_ want: (String) -> Bool, png4: Data) {
    if want("multipart-3part") {
        // Same PNG and params, single-shot vs 3-part multipart: the inserted image must be
        // identical (stripe count from the parsed width=2 cells, and pixels), proving FileEnd
        // reaches createImage with the header params.
        let (a, _) = makeView(); a.feed(text: osc1337(png4, extra: ";width=2"))
        let (b, _) = makeView(); b.feed(text: multipart(png4, parts: 3, extra: ";width=2"))
        let ia = images(a), ib = images(b)
        let pa = (ia.first as? TerminalView.AppleImage).map { pixels(of: $0.image) } ?? []
        let pb = (ib.first as? TerminalView.AppleImage).map { pixels(of: $0.image) } ?? []
        check("multipart-3part", ia.count >= 1 && ib.count == ia.count && !pb.isEmpty && pa == pb,
              "single images=\(ia.count) multipart images=\(ib.count) pixels equal=\(pa == pb)")
    }
    if want("multipart-overcap") {
        // A VALID PNG padded past 32 MiB encoded, sent in 1 MiB parts: no single part is
        // over the cap, only the CUMULATIVE size is. Dropped, no crash, and the next
        // transfer still lands.
        var big = png4
        big.append(Data(count: 25 * 1024 * 1024))
        let (v, _) = makeView()
        v.feed(text: multipart(big, parts: 34))
        let after1 = images(v).count
        v.feed(text: multipart(png4, parts: 3))
        check("multipart-overcap", after1 == 0 && images(v).count == 1,
              "after over-cap=\(after1) (want 0) after next=\(images(v).count) (want 1)")
    }
    if want("multipart-stray") {
        // FilePart / FileEnd with no MultipartFile: ignored (no image, not handed to
        // iTermContent either), and a FileEnd closes the transfer so a second FileEnd is
        // stray too. A real transfer afterwards still works.
        let b64 = png4.base64EncodedString()
        let (v, r) = makeView()
        v.feed(text: mpPart(b64[...]) + mpEnd)
        v.feed(text: multipart(png4, parts: 2) + mpEnd)
        check("multipart-stray", images(v).count == 1 && r.iterm.isEmpty,
              "images=\(images(v).count) (want 1) iTermContent calls=\(r.iterm.count)")
    }
    if want("multipart-inline0") {
        // inline=0 is a download: never buffered, never reaches createImage.
        let (v, _) = makeView()
        v.feed(text: multipart(png4, parts: 3, inline: 0))
        check("multipart-inline0", images(v).isEmpty, "images=\(images(v).count)")
    }
    if want("multipart-reset") {
        // RIS mid-transfer abandons it: the remaining parts + FileEnd are stray.
        let b64 = png4.base64EncodedString()
        let half = b64.index(b64.startIndex, offsetBy: b64.count / 2)
        let (v, _) = makeView()
        v.feed(text: mpHeader() + mpPart(b64[..<half]) + "\u{1b}c" + mpPart(b64[half...]) + mpEnd)
        check("multipart-reset", images(v).isEmpty, "images=\(images(v).count)")
    }
    if want("multipart-stale") {
        // #283: a transfer that stops getting FileParts is dropped and its buffer freed by
        // the inactivity watchdog alone — nothing else is fed while it waits (the exact
        // unterminated case). Window shortened from 120 s; the late parts + FileEnd that
        // follow are stray, so no image.
        let b64 = png4.base64EncodedString()
        let half = b64.index(b64.startIndex, offsetBy: b64.count / 2)
        let (v, _) = makeView(); let t = v.getTerminal()
        t.iTermMultipartInactivitySeconds = 0.3
        v.feed(text: mpHeader() + mpPart(b64[..<half]))
        let held = t.iTermMultipart?.encoded.count ?? 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let freed = t.iTermMultipart == nil
        v.feed(text: mpPart(b64[half...]) + mpEnd)
        check("multipart-stale", held > 0 && freed && images(v).isEmpty,
              "held=\(held) freed after idle=\(freed) images=\(images(v).count) (want >0, true, 0)")
    }
    if want("multipart-slow-alive") {
        // #283 control: a SLOW but live sender (a part every 0.12 s, ~0.72 s in total, window
        // 0.5 s) must NOT be dropped — FilePart refreshes the activity stamp.
        let b64 = png4.base64EncodedString(); let n = 6
        let step = (b64.count + n - 1) / n
        let (v, _) = makeView(); let t = v.getTerminal()
        t.iTermMultipartInactivitySeconds = 0.5
        v.feed(text: mpHeader())
        var i = b64.startIndex
        while i < b64.endIndex {
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            let j = b64.index(i, offsetBy: step, limitedBy: b64.endIndex) ?? b64.endIndex
            v.feed(text: mpPart(b64[i..<j])); i = j
        }
        v.feed(text: mpEnd)
        check("multipart-slow-alive", images(v).count == 1, "images=\(images(v).count) (want 1)")
    }
    if want("imgcat-real") {
        // The captured byte stream of the real modern imgcat (see header).
        let path = ProcessInfo.processInfo.environment["IMAGE_DECODE_FIXTURE"] ?? ""
        guard let bytes = FileManager.default.contents(atPath: path), bytes.count > 1000 else {
            check("imgcat-real", false, "fixture missing at \(path)"); return
        }
        let (v, _) = makeView()
        v.feed(byteArray: [UInt8](bytes)[...])
        let px = (images(v).first as? TerminalView.AppleImage).map { pixels(of: $0.image) } ?? []
        check("imgcat-real", images(v).count == 1 && px.count >= 256,
              "images=\(images(v).count) pixels=\(px.count) (want 1 image, >=256 px)")
    }
}
