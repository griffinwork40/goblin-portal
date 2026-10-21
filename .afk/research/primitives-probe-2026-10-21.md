# Primitives Probe — 2026-10-21

**Gate:** `app/Scripts/check-primitives.sh`  ·  **Roadmap:** T4.0  
**SwiftTerm:** v1.15.0 + 16 local patches  
**Method:** byte-feed to headless `Terminal`; no window server, no AppKit.  
Metal / CoreText pixel draw **deferred** (requires offscreen GUI — noted per row).

---

## Probe Results

| Row ID | Verdict | Note |
|--------|---------|------|
| `XTVERSION` | **ABSENT** | No response — DCS>q has no registered handler (A1b MISSING ✓ confirmed) |
| `DA1` | **PRESENT** | Response: [?65;4;1;2;6;21;22;17;28c \| sixel-bit(;4): true (A1b SUPPORTED ✓) |
| `DA2` | **PRESENT** | Response: [>65;20;1c (A1b SUPPORTED ✓) |
| `modifyOtherKeys` | **ABSENT** | DECRQM ?1036 → "[?1036;0$y" status=0(unknown) → ABSENT (A1b MISSING ✓) |
| `altScroll1007` | **ABSENT** | DECRQM ?1007 → "[?1007;0$y" status=0(unknown) → ABSENT (A1b MISSING ✓) |
| `mode2027` | **ABSENT** | DECRQM ?2027 → "[?2027;0$y" status=0(unknown) → ABSENT (A1b MISSING ✓) |
| `kittyKbdQuery` | **PRESENT** | Response: "[?0u" (A1b SUPPORTED ✓) |
| `OSC9progress` | **PRESENT** | state=set progress=50 — A1b said PARTIAL; CORRECTED: vendor fires progressReport (PRESENT); app TerminalPane stub empty  |
| `sixelParsing` | **PARTIAL** | DCS consumed without crash ✓; SixelDcsHandler.swift hooked. No draw path in CoreText or Metal renderers (A1b PARTIAL ✓). |
| `OSC1337` | **PARTIAL** | SwiftTerm calls createImage ✓ (Terminal.swift:1966 inline=1 path). A1b said MISSING(app): CORRECTED to PARTIAL — vendor  |
| `kittyGraphics` | **PARTIAL** | APC G consumed without crash ✓; KittyGraphics.swift hooked. Metal render path exists (MetalTerminalRenderer.swift:660-70 |
| `syncOutput2026` | **PARTIAL** | Response: "[?2026;2$y" (A1b PARTIAL ✓ — Terminal.swift:3380 tracks flag; queuePendingDisplay not gated on it) |
| `bracketedPaste2004` | **PRESENT** | Response: "[?2004;1$y" (A1b SUPPORTED ✓) |

---

## A1b Corrections

The A1b static analysis was described as "2-for-2 wrong on spot checks" in the roadmap.
This probe records all corrections found:

| A1b claim | A1b verdict | Probe verdict | Correction |
|-----------|-------------|---------------|------------|
| OSC 9;4 progress — vendor layer | PARTIAL (app stub empty) | **PRESENT** | A1b conflated the app stub with the vendor delegate. `Terminal.swift:1859` fires `progressReport(source:report:)` with parsed state and progress. T4.3 needs only a `TerminalPane` override — no vendor patch. |
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
| T4.3 OSC 9;4 progress | PRESENT at vendor; app stub empty | App-only: `TerminalPane` override of `progressReport`, update `NSDockTile` |
| T4.4 sixel render | PARTIAL — parsed, not rendered | Vendor patch: draw path in `AppleTerminalView.swift` / `MetalTerminalRenderer.swift` |
| T4.4 kitty graphics render | PARTIAL — Metal path exists; pixel test deferred | Extend `check-render-parity.sh` with kitty-image fixture |
| T4.4 OSC 1337 iTerm2 | PARTIAL — vendor fires delegate; app drops | App-only: `TerminalPane.iTermContent` override |
all 13 primitive assertions passed
