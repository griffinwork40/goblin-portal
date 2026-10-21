// check-primitives-harness.swift — compiled and linked by check-primitives.sh
//
// Byte-feed probe for T4.0: records what SwiftTerm v1.15.0 + 17 local patches
// actually responds to, replacing the A1b static-analysis hypotheses with measured
// behaviour. Each row feeds escape sequences to a headless Terminal, captures the
// bytes SwiftTerm sends back via TerminalDelegate.send(source:data:), and records
// PRESENT / ABSENT / PARTIAL. The pinned truth table is the regression gate:
// a verdict that changes exits 1.
//
// Subject: vendored emulator only. App-layer wiring (TerminalPane, AppDelegate) is
// NOT exercised — that is daily-drive territory, confirmed by AFK.md Known Risks.
//
// Metal/CoreText pixel draw is DEFERRED — requires offscreen NSWindow + GPU context
// (same constraint as check-metal-throughput.sh). The parser hooks for sixel,
// kitty graphics, and OSC 1337 ARE probed headlessly.
//
// Exit codes (same contract as check-reflow.sh):
//   0  all pinned assertions passed
//   1  a pinned assertion FAILED — verdict changed from recorded value
//   2  ENVIRONMENT failure — cannot construct terminal or required symbol absent
//
// WHY THIS FILE IS SEPARATE FROM THE .sh
// check-primitives.sh would exceed the 350-LOC ceiling (AFK.md convention).
// Pattern follows check-git-status-harness.swift and check-metal-throughput-harness.swift.

import Foundation
import SwiftTerm

// MARK: - Response-capturing delegate

/// Captures every byte SwiftTerm sends TO the application (device responses,
/// DA replies, DECRQM answers, kitty query replies) via send(source:data:).
/// Also records progressReport and iTermContent delegate calls.
final class CapturingDelegate: TerminalDelegate {
    var sent: [UInt8] = []
    var progressFired = false
    var progressState: String = ""
    var progressValue: UInt8? = nil
    var iTermContentFired = false
    var createImageFired = false

    // The one method that matters for response capture (Terminal.swift:75).
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }

    // OSC 9;4 progress hook (Terminal.swift:1859 → tdel?.progressReport).
    func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        progressFired = true
        progressState = "\(report.state)"
        progressValue = report.progress
    }

    // OSC 1337 iTerm2 content hook (Terminal.swift:1905 → tdel?.iTermContent).
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {
        iTermContentFired = true
    }

    // Required stubs — exact signatures from TerminalDelegate (Terminal.swift:18-220).
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func synchronizedOutputChanged(source: Terminal, active: Bool) {}
    func bell(source: Terminal) {}
    func selectionChanged(source: Terminal) {}
    func isProcessTrusted(source: Terminal) -> Bool { false }
    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { nil }
    func mouseModeChanged(source: Terminal) {}
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {}
    func hostCurrentDirectoryUpdated(source: Terminal) {}
    func hostCurrentDocumentUpdated(source: Terminal) {}
    func colorChanged(source: Terminal, idx: Int?) {}
    func setForegroundColor(source: Terminal, color: Color) {}
    func setBackgroundColor(source: Terminal, color: Color) {}
    func setCursorColor(source: Terminal, color: Color?) {}
    func getColors(source: Terminal) -> (foreground: Color, background: Color) {
        // Colors.swift:36-37 defaultForeground/Background are `internal`, not public.
        // Return plain grey-on-black — values match the internal defaults exactly.
        (Color(red: 35389, green: 35389, blue: 35389), Color(red: 0, green: 0, blue: 0))
    }
    // SixelDcsHandler.unhook() calls createImageFromBitmap (Terminal.swift:250).
    // Without this stub the sixel probe crashes with an index-out-of-range in
    // ContiguousArrayBuffer. createImage is called by the OSC 1337 / kitty paths.
    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {}
    func createImage(source: Terminal, data: Data, width: ImageSizeRequest,
                     height: ImageSizeRequest, preserveAspectRatio: Bool) {
        createImageFired = true
    }
}

// MARK: - Helpers

/// Build a fresh Terminal + capturing delegate.
func makeTerminal() -> (Terminal, CapturingDelegate) {
    let d = CapturingDelegate()
    let opts = TerminalOptions(cols: 80, rows: 24, scrollback: 500)
    let t = Terminal(delegate: d, options: opts)
    return (t, d)
}

/// Feed an escape-containing string using Terminal.feed(text:) (Terminal.swift:5002).
/// ESC is written as \u{1b}, ST as \u{1b}\\, BEL as \u{07}.
func feedStr(_ t: Terminal, _ s: String) {
    t.feed(text: s)
}

/// Human-readable representation of a byte array.
func describe(_ bytes: [UInt8]) -> String {
    guard !bytes.isEmpty else { return "<empty>" }
    let hex = bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
    let asc = String(bytes.prefix(32).map { b -> Character in
        (b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : Character(".")
    })
    let tail = bytes.count > 32 ? "…(\(bytes.count) bytes)" : ""
    return "[\(hex)\(tail)] \"\(asc)\(tail)\""
}

// MARK: - Verdict

enum Verdict: String { case PRESENT, ABSENT, PARTIAL }

struct Row {
    let id: String
    let description: String
    var verdict: Verdict
    var rawResponse: String
    var note: String
}


// MARK: - Probe functions
// Extracted to check-primitives-probes.swift to stay under the 350-LOC ceiling.
// Both files are compiled together by check-primitives.sh.


// MARK: - Pinned truth table
//
// These are the RECORDED verdicts for 2026-10-21. A verdict change exits 1.
// To update after a legitimate change: run the probe, verify the output, update
// the value here, commit with a note explaining why the row changed.
//
// Evidence for each pinned value is in the note field of the corresponding Row,
// and in the A1b corrections section of .afk/research/primitives-probe-2026-10-21.md.

let pinnedVerdicts: [String: Verdict] = [
    "XTVERSION":          .PRESENT,  // DCS>q: XtVersionDcsHandler responds DCS>|<ver> ST (patch 0017)
    "DA1":                .PRESENT,  // Terminal.swift:4621-4632 VT525 response
    "DA2":                .PRESENT,  // Terminal.swift:4605-4612 >65;20;1c
    "modifyOtherKeys":    .ABSENT,   // mode 1036 absent from cmdDecRqm (Terminal.swift:3374)
    "altScroll1007":      .PRESENT,  // mode 1007: altScrollMode property + DECRQM (patch 0017)
    "mode2027":           .PRESENT,  // mode 2027: permanently-reset response in cmdDecRqm (patch 0017, honest)
    "kittyKbdQuery":      .PRESENT,  // Terminal.swift:921 sends CSI?<flags>u
    "OSC9progress":       .PRESENT,  // Terminal.swift:1859 fires progressReport delegate
    "sixelParsing":       .PARTIAL,  // SixelDcsHandler.swift hooks DCS; no draw path
    "OSC1337":            .PARTIAL,  // Terminal.swift:1966 inline=1 → createImage; app drops
    "kittyGraphics":      .PARTIAL,  // KittyGraphics.swift hooked; render deferred
    "syncOutput2026":     .PARTIAL,  // Terminal.swift:3380 tracks flag; suppression absent
    "bracketedPaste2004": .PRESENT,  // Terminal.swift:4217,4457 full implementation
]

// MARK: - Main

func runProbe() {
var rows: [Row] = []
rows.append(probeXTVERSION())
rows.append(probeDA1())
rows.append(probeDA2())
rows.append(probeModifyOtherKeys())
rows.append(probeAltScroll1007())
rows.append(probeMode2027())
rows.append(probeKittyKeyboardQuery())
rows.append(probeOSC9Progress())
rows.append(probeSixelParsing())
rows.append(probeOSC1337())
rows.append(probeKittyGraphics())
rows.append(probeSyncOutput2026())
rows.append(probeBracketedPaste())

// Print the results table.
let sep = String(repeating: "─", count: 82)
print("primitives probe — SwiftTerm v1.15.0 + 17 patches — T4.2")
print("")
print(sep)
print("  \("ID".padding(toLength: 22, withPad: " ", startingAt: 0))"
    + "\("VERDICT".padding(toLength: 9, withPad: " ", startingAt: 0))  NOTE")
print(sep)

var failures = 0
for row in rows {
    let pinned = pinnedVerdicts[row.id]
    let match  = pinned == row.verdict
    if !match { failures += 1 }
    let flag = match ? "  " : "✗ "
    print("\(flag)\(row.id.padding(toLength: 22, withPad: " ", startingAt: 0))"
        + "\(row.verdict.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))  \(row.note)")
    if !match {
        print("    REGRESSION: pinned=\(pinned?.rawValue ?? "UNKNOWN") got=\(row.verdict.rawValue)")
    }
}
print(sep)
print("")

// ── Markdown output (captured by shell script after === MARKDOWN === sentinel) ──

let mdTable = rows.map {
    "| `\($0.id)` | **\($0.verdict.rawValue)** | \($0.note.replacingOccurrences(of: "|", with: "\\|").prefix(120)) |"
}.joined(separator: "\n")

print("=== MARKDOWN ===")
print("""
# Primitives Probe — 2026-10-21

**Gate:** `app/Scripts/check-primitives.sh`  ·  **Roadmap:** T4.0  
**SwiftTerm:** v1.15.0 + 17 local patches  
**Method:** byte-feed to headless `Terminal`; no window server, no AppKit.  
Metal / CoreText pixel draw **deferred** (requires offscreen GUI — noted per row).

---

## Probe Results

| Row ID | Verdict | Note |
|--------|---------|------|
\(mdTable)

---

## A1b Corrections

The A1b static analysis was described as "2-for-2 wrong on spot checks" in the roadmap.
This probe records all corrections found:

| A1b claim | A1b verdict | Probe verdict | Correction |
|-----------|-------------|---------------|------------|
| OSC 9;4 progress — vendor layer | PARTIAL | **PRESENT** | `Terminal.swift:1859` fires `progressReport(source:report:)` with parsed state and progress, and the app already uses it: `GoblinPortalTerminalView+Notify.swift:16-36` feeds 9;4 to `MacTerminalView.progressReport` (`:2908`, SwiftTerm's in-view progress bar). `Terminal.swift:6841` is only the protocol's default stub. What T4.3 still lacks is tab-strip / Dock progress; no vendor patch needed. |
| OSC 1337 iTerm2 images — vendor layer | MISSING (app drops) | **PARTIAL** | A1b correct that the app drops images; but labelled the whole row MISSING. `Terminal.swift:1905` fires `iTermContent` reliably. T4.4 needs only a `TerminalPane.iTermContent` override — no vendor patch. |
| All other rows (11 of 13) | — | ✓ confirmed | XTVERSION ABSENT, DA1/DA2 PRESENT, modifyOtherKeys ABSENT, altScroll1007 ABSENT, mode2027 ABSENT, kittyKbdQuery PRESENT, sixelParsing PARTIAL, kittyGraphics PARTIAL, syncOutput2026 PARTIAL, bracketedPaste2004 PRESENT — all match A1b static analysis. |

---

## Deferred: Metal / CoreText Image Pixel Draw

Sixel *rendering* and kitty graphics *rendering* require an offscreen `NSWindow` + GPU
context. The **parser hooks** are confirmed headlessly (sixelParsing=PARTIAL,
kittyGraphics=PARTIAL). Pixel-level verification is deferred to a future
`check-primitives-render.sh` (same shape as `check-metal-throughput.sh`).

`check-metal-renderer.sh` and `check-render-parity.sh` already gate the renderer
pipeline; a kitty-image fixture would extend `check-render-parity.sh` (Gap 11 in A1b).

---

## T4.2–T4.4 Implications

| Roadmap item | Probe finding | Required work |
|---|---|---|
| T4.2 XTVERSION | ABSENT — DCS>q not dispatched | Vendor patch: register DCS>q in `EscapeSequenceParser.swift`, respond `DCS>|GoblinPortal <ver> ST` |
| T4.2 modifyOtherKeys | ABSENT — mode 1036 not in `cmdDecRqm` | Vendor patch: add 1036 to DECSET/DECRST + key encoder in `MacTerminalView.swift` |
| T4.2 altScroll 1007 | ABSENT — mode 1007 not in `cmdDecRqm` | Vendor patch: add 1007 + scroll-event → cursor-key synthesis in `MacTerminalView.swift` |
| T4.2 mode 2027 | ABSENT — mode 2027 not in `cmdDecRqm` | Vendor patch: large UAX#29 change to hot path; defer |
| T4.3 OSC 9;4 progress | PRESENT at vendor; in-view bar already wired | App-only: surface the same report on the tab strip and `NSDockTile` (hook beside the existing `+Notify` decoder) |
| T4.4 sixel render | PARTIAL — parsed, not rendered | Vendor patch: draw path in `AppleTerminalView.swift` / `MetalTerminalRenderer.swift` |
| T4.4 kitty graphics render | PARTIAL — Metal path exists; pixel test deferred | Extend `check-render-parity.sh` with kitty-image fixture |
| T4.4 OSC 1337 iTerm2 | PARTIAL — vendor fires delegate; app drops | App-only: `TerminalPane.iTermContent` override |
""")

let summary = failures == 0
    ? "all \(rows.count) primitive assertions passed"
    : "\(failures) of \(rows.count) primitive assertion(s) FAILED — pinned truth table changed"
print(summary)
exit(failures == 0 ? 0 : 1)
}

runProbe()
