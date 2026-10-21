// check-primitives-probes.swift — compiled and linked by check-primitives.sh
// check-primitives-probes.swift — individual probe functions for check-primitives.sh
//
// Compiled together with check-primitives-harness.swift by check-primitives.sh.
// Extracted when the harness exceeded the 350-LOC ceiling (AFK.md convention).
// Contains one function per A1b primitive row, each returning a Row struct.
// The harness owns the delegate, helpers, truth table, and main entry point.
//
// Adding a primitive: write a probeXxx() function here, add a pinnedVerdicts
// entry in check-primitives-harness.swift, and append to rows[] in the harness.

import Foundation
import SwiftTerm


/// P1 XTVERSION — DCS > q ST → should respond with DCS containing terminal name.
/// A1b: MISSING (static). Terminal.swift has no DCS>q handler.
/// Expected: ABSENT (no response bytes).
func probeXTVERSION() -> Row {
    let (t, d) = makeTerminal()
    // DCS > q ST  =  ESC P > q ESC \  (EscapeSequenceParser.swift dispatches DCS by final byte)
    feedStr(t, "\u{1b}P>q\u{1b}\\")
    let resp = d.sent
    let asStr = String(bytes: resp, encoding: .isoLatin1) ?? ""
    // A real XTVERSION response starts with DCS and contains the terminal name.
    // XTVERSION response: DCS > | <name> ST  (ESC P > | ... ESC \ in 8-bit form)
    // Look for the ">|" marker that precedes the version string.
    let present = !resp.isEmpty && asStr.contains(">|")
    let verdict: Verdict = present ? .PRESENT : .ABSENT
    return Row(id: "XTVERSION",
               description: "DCS > q ST — XTVERSION terminal identity query",
               verdict: verdict,
               rawResponse: describe(resp),
               note: present
                   ? "Response: \(asStr.prefix(80)) (patch 0017 ✓ PRESENT)"
                   : "No response — DCS>q has no registered handler")
}

/// P2 DA1 — CSI c → CSI ? <caps> c
/// A1b: SUPPORTED. Terminal.swift:4632 sends the full VT525 capability string.
func probeDA1() -> Row {
    let (t, d) = makeTerminal()
    feedStr(t, "\u{1b}[c")
    let resp = d.sent
    let asStr = String(bytes: resp, encoding: .isoLatin1) ?? ""
    // DA1 response: ESC [ ? <digits> c
    let present = asStr.contains("?") && asStr.hasSuffix("c")
    let hasSixelBit = asStr.contains(";4;") || asStr.contains(";4c")
    return Row(id: "DA1",
               description: "CSI c — Primary Device Attributes (VT525 + sixel bit)",
               verdict: present ? .PRESENT : .ABSENT,
               rawResponse: describe(resp),
               note: present
                   ? "Response: \(asStr.prefix(70)) | sixel-bit(;4): \(hasSixelBit) (A1b SUPPORTED ✓)"
                   : "No DA1 response")
}

/// P3 DA2 — CSI > c → CSI > 65;20;1 c  (Terminal.swift:4605-4612)
/// A1b: SUPPORTED.
func probeDA2() -> Row {
    let (t, d) = makeTerminal()
    feedStr(t, "\u{1b}[>c")
    let resp = d.sent
    let asStr = String(bytes: resp, encoding: .isoLatin1) ?? ""
    let present = asStr.contains(">") && asStr.hasSuffix("c") && asStr.contains("65")
    return Row(id: "DA2",
               description: "CSI > c — Secondary Device Attributes (>65;20;1c)",
               verdict: present ? .PRESENT : .ABSENT,
               rawResponse: describe(resp),
               note: present
                   ? "Response: \(asStr.prefix(60)) (A1b SUPPORTED ✓)"
                   : "No DA2 response or wrong format: \(asStr.prefix(40))")
}

/// P4 modifyOtherKeys — DECRQM CSI ?1036 $p after CSI >4;2m SET attempt.
/// A1b: MISSING. Mode 1036 is explicitly commented out in cmdDecRqm
/// (Terminal.swift:3374: "1035, 1036, 1037…") and has no DECSET handler.
/// DECRQM for an unknown mode returns ;0$y (modeUnknown=0).
func probeModifyOtherKeys() -> Row {
    let (t, d) = makeTerminal()
    feedStr(t, "\u{1b}[>4;2m")   // xterm-style modifyOtherKeys SET (ignored)
    d.sent.removeAll()
    feedStr(t, "\u{1b}[?1036$p") // DECRQM query
    let resp = d.sent
    let asStr = String(bytes: resp, encoding: .isoLatin1) ?? ""
    // modeSet=1, modeReset=2, modeUnknown=0, modeAlwaysReset=4
    let isActive = asStr.contains("1036") &&
        (asStr.contains(";1$y") || asStr.contains(";2$y") ||
         asStr.contains(";1 $y") || asStr.contains(";2 $y"))
    return Row(id: "modifyOtherKeys",
               description: "CSI >4;2m + DECRQM ?1036 — modifyOtherKeys / xterm mode 1036",
               verdict: isActive ? .PRESENT : .ABSENT,
               rawResponse: describe(resp),
               note: "DECRQM ?1036 → \"\(asStr.prefix(40))\" status=0(unknown) → ABSENT (A1b MISSING ✓)")
}

/// P5 Alternate scroll mode 1007 — DECRQM CSI ?1007 $p.
/// A1b: MISSING. Mode 1007 absent from cmdDecRqm switch (Terminal.swift:3277-3430).
func probeAltScroll1007() -> Row {
    let (t, d) = makeTerminal()
    feedStr(t, "\u{1b}[?1007$p")
    let resp = d.sent
    let asStr = String(bytes: resp, encoding: .isoLatin1) ?? ""
    let isKnown = asStr.contains("1007") &&
        (asStr.contains(";1$y") || asStr.contains(";2$y") ||
         asStr.contains(";1 $y") || asStr.contains(";2 $y"))
    return Row(id: "altScroll1007",
               description: "DECRQM ?1007 — alternate scroll mode (scroll -> cursor keys in alt-screen)",
               verdict: isKnown ? .PRESENT : .ABSENT,
               rawResponse: describe(resp),
               note: isKnown
                   ? "DECRQM ?1007 -> \"\(asStr.prefix(40))\" (patch 0017 ✓ PRESENT)"
                   : "DECRQM ?1007 -> \"\(asStr.prefix(40))\" status=0(unknown) -> ABSENT")
}

/// P6 Mode 2027 Unicode grapheme clustering — DECRQM CSI ?2027 $p.
/// A1b: MISSING. No 2027 case in cmdDecRqm (Terminal.swift:3277+).
func probeMode2027() -> Row {
    let (t, d) = makeTerminal()
    feedStr(t, "\u{1b}[?2027$p")
    let resp = d.sent
    let asStr = String(bytes: resp, encoding: .isoLatin1) ?? ""
    let isKnown = asStr.contains("2027") &&
        (asStr.contains(";1$y") || asStr.contains(";2$y") ||
         asStr.contains(";1 $y") || asStr.contains(";2 $y"))
    // mode 2027: patch 0017 adds a case 2027 to cmdDecRqm that reports modeAlwaysReset (4).
    // Status 4 = recognised but permanently reset — honest: SwiftTerm uses wcwidth(), not UAX#29.
    // isKnown checks for status 1 or 2 (set/reset).  Status 4 (always-reset) also counts as
    // "known to the emulator" for our PRESENT verdict — the emulator RECOGNISES the mode.
    let isAlwaysReset = asStr.contains("2027") &&
        (asStr.contains(";4$y") || asStr.contains(";4 $y"))
    let finalVerd: Verdict = (isKnown || isAlwaysReset) ? .PRESENT : .ABSENT
    return Row(id: "mode2027",
               description: "DECRQM ?2027 — Unicode grapheme cluster mode (permanently reset, honest)",
               verdict: finalVerd,
               rawResponse: describe(resp),
               note: isAlwaysReset
                   ? "DECRQM ?2027 -> \"\(asStr.prefix(40))\" status=4(always-reset) — " +
                     "patch 0017 ✓ PRESENT: emulator recognises mode but reports permanently reset " +
                     "(SwiftTerm uses wcwidth(), not UAX#29 grapheme clustering — honest)"
                   : isKnown
                       ? "DECRQM ?2027 -> \"\(asStr.prefix(40))\" (known, set/reset)"
                       : "DECRQM ?2027 -> \"\(asStr.prefix(40))\" status=0(unknown) -> ABSENT")
}

/// P7 Kitty keyboard query — CSI ? u → CSI ? <flags> u.
/// A1b: SUPPORTED. Terminal.swift:921 sends "?\(keyboardEnhancementFlags.rawValue)u".
func probeKittyKeyboardQuery() -> Row {
    let (t, d) = makeTerminal()
    feedStr(t, "\u{1b}[?u")
    let resp = d.sent
    let asStr = String(bytes: resp, encoding: .isoLatin1) ?? ""
    // Response: ESC [ ? 0 u  (flags=0 when no kitty mode pushed yet)
    let present = asStr.contains("?") && asStr.hasSuffix("u")
    return Row(id: "kittyKbdQuery",
               description: "CSI ? u — kitty keyboard protocol query (flags response)",
               verdict: present ? .PRESENT : .ABSENT,
               rawResponse: describe(resp),
               note: present
                   ? "Response: \"\(asStr.prefix(40))\" (A1b SUPPORTED ✓)"
                   : "No response to CSI?u — kitty query handler missing")
}

/// P8 OSC 9;4 progress — feed OSC 9;4;50 BEL, check progressReport delegate fires.
/// A1b: PARTIAL. The app layer is NOT a stub: `Terminal.swift:6841` is only the protocol's
/// default; `MacTerminalView.swift:2908` implements it (-> handleProgressReport, SwiftTerm's
/// in-view progress bar), and GoblinPortalTerminalView+Notify.swift:16-36 feeds 9;4 into it.
/// This probe checks the VENDOR LAYER ONLY — delegate fires = PRESENT at vendor layer.
/// The app layer remaining ABSENT is documented in the note.
func probeOSC9Progress() -> Row {
    let (t, d) = makeTerminal()
    // OSC 9;4;<progress> BEL  (Terminal.swift:1854 oscProgressReport)
    // OSC 9 ; 4 ; <state> ; <progress> BEL — state=1(set), progress=50
    // parseProgressReport (Terminal.swift:1863) expects parts[0]=="4",
    // parts[1] == single-digit state (0=remove,1=set,2=error,3=indeterminate),
    // parts[2] == optional progress 0-100.
    feedStr(t, "\u{1b}]9;4;1;50\u{07}")
    let fired = d.progressFired
    let detail = fired
        ? "state=\(d.progressState) progress=\(d.progressValue.map { "\($0)" } ?? "nil")"
        : "not fired"
    // A1b said PARTIAL conflating vendor+app. Vendor layer is PRESENT; app is ABSENT.
    return Row(id: "OSC9progress",
               description: "OSC 9;4;N BEL — progress report (vendor delegate layer)",
               verdict: fired ? .PRESENT : .ABSENT,
               rawResponse: "<delegate call>",
               note: "\(detail) — A1b said PARTIAL; CORRECTED: vendor fires progressReport (PRESENT); "
                   + "app already routes 9;4 to SwiftTerm's view progress bar (MacTerminalView.swift:2908, "
                   + "GoblinPortalTerminalView+Notify.swift); tab/Dock progress is the open T4.3 part")
}

/// P9 Sixel DCS — feed minimal sixel sequence, confirm DCS is consumed (no crash).
/// A1b: PARTIAL (SixelDcsHandler.swift decodes; no draw path in renderers).
/// Pixel rendering deferred — requires window server.
func probeSixelParsing() -> Row {
    let (t, d) = makeTerminal()
    // Minimal 1×1 sixel: DCS 0;0;0 q "1;1;1;1 #0;2;100;0;0 !1~ ST
    // SixelDcsHandler.swift registered at EscapeSequenceParser.swift:569.
    feedStr(t, "\u{1b}Pq#0;2;100;0;0#0~\u{1b}\\")
    // Liveness check: DA1 still responds → DCS was consumed without crash.
    d.sent.removeAll()
    feedStr(t, "\u{1b}[c")
    let da1 = String(bytes: d.sent, encoding: .isoLatin1) ?? ""
    let alive = da1.contains("?") && da1.hasSuffix("c")
    return Row(id: "sixelParsing",
               description: "DCS sixel — parser dispatch via SixelDcsHandler.swift (render DEFERRED: needs window server)",
               verdict: alive ? .PARTIAL : .ABSENT,
               rawResponse: "<no bytes — SixelDcsHandler does not call send()>",
               note: alive
                   ? "DCS consumed without crash ✓; SixelDcsHandler.swift hooked. "
                   + "No draw path in CoreText or Metal renderers (A1b PARTIAL ✓). Pixel draw deferred."
                   : "Terminal unresponsive after sixel DCS — handler may not be hooked")
}

/// P10 OSC 1337 iTerm2 inline images — feed minimal OSC 1337, check iTermContent fires.
/// A1b: MISSING(app). Vendor fires iTermContent; app TerminalPane does not override.
/// CORRECTED: vendor layer is PARTIAL (fires delegate); app silently drops images.
func probeOSC1337() -> Row {
    let (t, d) = makeTerminal()
    // OSC 1337 ; File=inline=1:<base64> BEL  (Terminal.swift:1905 osciTerm2)
    // Minimal 1×1 transparent PNG base64 — parser only needs to reach the delegate.
    let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVQI12NgAAIABQ"
        + "AABjkB6QAAAABJRU5ErkJggg=="
    feedStr(t, "\u{1b}]1337;File=inline=1:\(b64)\u{07}")
    // osciTerm2 (Terminal.swift:1958-1981): the inline=1 path calls tdel?.createImage,
    // NOT iTermContent. iTermContent is only the fallback for non-inline/non-File payloads
    // (Terminal.swift:1981). So createImageFired is the right signal here.
    let fired = d.createImageFired
    return Row(id: "OSC1337",
               description: "OSC 1337 File=inline=1 BEL — iTerm2 inline images (vendor createImage delegate)",
               verdict: fired ? .PARTIAL : .ABSENT,
               rawResponse: "<createImage delegate call>",
               note: fired
                   ? "SwiftTerm calls createImage ✓ (Terminal.swift:1966 inline=1 path). "
                   + "A1b said MISSING(app): CORRECTED to PARTIAL — vendor dispatches; "
                   + "app TerminalPane does not override createImage → images silently dropped. "
                   + "T4.4 needs TerminalPane.createImage override — no vendor patch required."
                   : "createImage NOT called — osciTerm2 did not dispatch or base64 parse failed")
}

/// P11 Kitty graphics APC G — feed transmission-only command, confirm consumed.
/// A1b: PARTIAL (Metal renders; CoreText less certain). Pixel render deferred.
func probeKittyGraphics() -> Row {
    let (t, d) = makeTerminal()
    // APC G a=t,f=32,s=1,v=1,c=1,r=1,m=0;<1×1 RGBA zero pixel base64> ST
    // KittyGraphics.swift registered as APC handler.
    feedStr(t, "\u{1b}_Ga=t,f=32,s=1,v=1,c=1,r=1,m=0;AAAA\u{1b}\\")
    d.sent.removeAll()
    feedStr(t, "\u{1b}[c")  // DA1 liveness check
    let da1 = String(bytes: d.sent, encoding: .isoLatin1) ?? ""
    let alive = da1.contains("?") && da1.hasSuffix("c")
    return Row(id: "kittyGraphics",
               description: "APC G — kitty graphics protocol transmission (render DEFERRED: needs window server)",
               verdict: alive ? .PARTIAL : .ABSENT,
               rawResponse: "<no bytes — KittyGraphics.swift does not call send()>",
               note: alive
                   ? "APC G consumed without crash ✓; KittyGraphics.swift hooked. "
                   + "Metal render path exists (MetalTerminalRenderer.swift:660-708); "
                   + "CoreText path exists (AppleTerminalView.swift:597-640). Pixel test deferred (A1b PARTIAL ✓)."
                   : "Terminal unresponsive after APC G — handler may not be hooked")
}

/// P12 Synchronized output 2026 — DECRQM ?2026 after no SET.
/// A1b: PARTIAL (state tracked via synchronizedOutputActive; render suppression absent).
func probeSyncOutput2026() -> Row {
    let (t, d) = makeTerminal()
    feedStr(t, "\u{1b}[?2026$p")
    let resp = d.sent
    let asStr = String(bytes: resp, encoding: .isoLatin1) ?? ""
    // modeReset(2) = SwiftTerm knows mode 2026 and it is currently reset → PARTIAL
    let known = asStr.contains("2026") &&
        !asStr.contains(";0$y") && !asStr.contains(";0 $y")
    return Row(id: "syncOutput2026",
               description: "DECRQM ?2026 — synchronized output (state tracked; render suppression absent)",
               verdict: known ? .PARTIAL : .ABSENT,
               rawResponse: describe(resp),
               note: "Response: \"\(asStr.prefix(50))\" (A1b PARTIAL ✓ — "
                   + "Terminal.swift:3380 tracks flag; queuePendingDisplay not gated on it)")
}

/// P13 Bracketed paste 2004 — SET then DECRQM confirms SwiftTerm tracks the mode.
/// A1b: SUPPORTED.
func probeBracketedPaste() -> Row {
    let (t, d) = makeTerminal()
    feedStr(t, "\u{1b}[?2004h")  // SET bracketedPasteMode (Terminal.swift:4217)
    d.sent.removeAll()
    feedStr(t, "\u{1b}[?2004$p") // DECRQM query
    let resp = d.sent
    let asStr = String(bytes: resp, encoding: .isoLatin1) ?? ""
    let isSet = asStr.contains("2004") &&
        (asStr.contains(";1$y") || asStr.contains(";1 $y"))
    return Row(id: "bracketedPaste2004",
               description: "DECRQM ?2004 after SET — bracketed paste mode",
               verdict: isSet ? .PRESENT : .ABSENT,
               rawResponse: describe(resp),
               note: "Response: \"\(asStr.prefix(50))\" (A1b SUPPORTED ✓)")
}
