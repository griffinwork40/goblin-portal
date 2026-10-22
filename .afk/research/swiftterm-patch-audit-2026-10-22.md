# SwiftTerm patch audit: 0001–0019 against upstream main

**Audited:** 2026-10-22  
**Our base:** v1.15.0 + nineteen local patches  
**Upstream HEAD audited:** `c3436be32e3dc26d5e2181b1e451d91e21e50d53` (no tags on upstream main — latest tag absent; upstream is in a post-v1.99.x IO-rewrite state)  
**Upstream clone:** scratch clone at `/tmp/upstream-swiftterm` (gitignored, not committed)  
**Verified on HEAD:** `9828c1148905d97d26c185c9af05be750bb397ec`  
**Refs:** tracking issue #281

---

## Context: upstream's IO rewrite is a structural discontinuity

Before reading individual patch verdicts it is important to name the shape of upstream's
change since v1.15.0. Upstream merged a major IO rewrite (PR #627) that restructured the
Mac rendering path around a `FrameDriver` / `FrameDriverSignal` abstraction replacing the
old `asyncAfter`-based timer. The new `feedPrepareLocked()` in `AppleTerminalView.swift`
(line 4593) is a stub — `search.invalidate()` only, no selection clear — because selection
management moved into the locking machinery. `MacDisplayLinkPacer.swift` no longer exists
upstream; its role is absorbed by `FrameDriver`. This affects patches **0010** and **0016**
most severely: both target a file that is gone. All other patches touch files that still
exist, though the surrounding context has shifted.

---

## Patch verdicts

### 0001 — Ship Metal shader as `.copy` resource  
**File:** `Package.swift`  
**What it changes:** Changes `.process("Apple/Metal/Shaders.metal")` to `.copy(…)` so the
Metal compiler is not invoked at build time; the OS compiler compiles it at runtime on first
use.  
**Upstream state:** Upstream `Package.swift` still uses `.process("Apple/Metal/Shaders.metal")`
(confirmed: grep shows `"Apple/Metal/Shaders.metal"` under `exclude:` patterns and the
separate SwiftTermTests target uses `.copy` for fixtures, but the main target retains
`.process`).  
**Verdict:** STILL-NEEDED (machine-specific)  
**Evidence:** `upstream Package.swift` — no `.copy` for `Shaders.metal` in main target.
This patch is machine-specific: it exists because the build machine lacks the Metal offline
compiler (`metal` binary). A standard Xcode installation has it and uses `.process`
correctly. This patch must be evaluated at re-vendor time against the target build
environment. If the offline toolchain is installed, 0001 becomes unnecessary. If it is not,
0001 remains required verbatim.  
**Port complexity:** Trivial — one-line change in `Package.swift`, context is identical.  
**Gate:** `check-metal-renderer.sh`

---

### 0002 — `isWrapped` buffer-absolute index  
**File:** `Sources/SwiftTerm/Buffer.swift`  
**What it changes:** Fixes two sites where `_lines[_y].isWrapped = true` uses a
screen-relative `_y` when it should be `_lines[_y + _yBase].isWrapped = true`, silently
corrupting scrollback reflow.  
**Upstream state:** Upstream `Buffer.swift` at `c3436be` already uses `_lines[_y + _yBase]`
at all the analogous write sites (lines 1754, 1790, 1831, 1877 — confirmed by grep). The
reflow code was substantially rewritten as part of the IO rewrite; the old buggy sites no
longer exist in their original form.  
**Issue #494:** Confirmed open on upstream (`gh issue view 494 --repo migueldeicaza/SwiftTerm`
returns state: OPEN with 9 comments) but the underlying write-site bug is fixed in the
rewrite.  
**Verdict:** ALREADY-UPSTREAM  
**Evidence:** `Sources/SwiftTerm/Buffer.swift:1754,1790,1831,1877` — all use
`_lines[_y + _yBase]`. The specific two-site bug our patch addressed was fixed in the
rewrite even though the tracking issue remains open (likely for remaining reflow edge cases).  
**Port complexity:** None — do not carry this forward.  
**Gate:** `check-reflow.sh`

---

### 0003 — Trim lines on narrowing for all buffers  
**File:** `Sources/SwiftTerm/Buffer.swift`  
**What it changes:** Moves the narrowing trim loop out of the `isReflowEnabled` branch so it
runs for every buffer including the alt buffer, preventing stale cells bleeding across tmux
panes.  
**Upstream state:** Upstream `Buffer.swift:1016–1026` (confirmed by reading):

```swift
if isReflowEnabled {
    reflow (newCols, newRows)
    // Trim the end of the line off if cols shrunk
    if cols > newCols {
        for i in 0..<lines.count {
            lines[i].resize(cols: newCols, fill: defaultBlank)
        }
    }
}
```

The trim is **still inside `isReflowEnabled`** upstream. `isReflowEnabled` is `hasScrollback`
(confirmed: `Buffer.swift:910`), and the alt buffer is constructed with `scrollback: nil`
(confirmed in our vendored tree; upstream matches). So the alt-buffer tmux bleed defect
is **not fixed** upstream.  
**Verdict:** STILL-NEEDED  
**Evidence:** `Sources/SwiftTerm/Buffer.swift:1016–1026` at `c3436be` — trim remains gated
on `isReflowEnabled`. The structural defect (alt buffer cells survive a narrowing) persists.  
**Port complexity:** Low — same file, same logical location. The surrounding reflow code
changed substantially, but the structural fix (move the trim outside the `if isReflowEnabled`
block) is the same one-level dedent.  
**Gate:** `check-altbuffer-resize.sh`

---

### 0004 — Gate resize post-condition behind `#if DEBUG`  
**File:** `Sources/SwiftTerm/Buffer.swift`  
**What it changes:** Wraps the ungated post-condition block (which calls `abort()` in
release) in `#if DEBUG`.  
**Upstream state:** Upstream changed `abort()` to `fatalError(...)` (`Buffer.swift:1038`
confirmed: `fatalError("A resized line is shorter than the buffer width")`), but the block
is **still ungated** — no `#if DEBUG` wrapper. A `fatalError` in release is as fatal as
`abort()`.  

```swift
// DEBUG: Post-condition
if lines.count > 0 {
    for i in 0..<lines.count {
        let line = lines[i]
        if line.count < newCols {
            print("stop here …")
            fatalError("A resized line is shorter than the buffer width")  // :1038, ungated
        }
    }
}
```

The cost (full scrollback walk on every resize) and crash-in-release hazard both remain.  
**Verdict:** STILL-NEEDED  
**Evidence:** `Sources/SwiftTerm/Buffer.swift:1028–1042` at `c3436be` — ungated
`fatalError` in the post-condition block.  
**Port complexity:** Trivial — same `#if DEBUG` / `#endif` wrap, different crash call
(`fatalError` instead of `abort()`).  
**Gate:** Covered implicitly by `check-reflow.sh` and `check-altbuffer-resize.sh` (release
build path). No dedicated gate for this patch; it is a release-safety guard.

---

### 0005 — DCS Ptmux passthrough  
**Files:** `Sources/SwiftTerm/EscapeSequenceParser.swift`, new `PtmuxDcsHandler.swift`  
**What it changes:** Adds a `PtmuxDcsHandler` that intercepts `DCS t` (the `tmux;` prefix),
un-doubles ESC bytes, and re-feeds the inner sequence, enabling tmux passthrough for OSC
1337 / Kitty images / etc.  
**Upstream state:** `grep -rn "PtmuxDcsHandler\|ptmux\|Ptmux"` across all upstream
`Sources/` returns nothing. `EscapeSequenceParser.dispatchDcs` dispatches DECRQSS and SixelDcsHandler; no tmux handler. Upstream does not implement DCS Ptmux passthrough.  
**Verdict:** STILL-NEEDED  
**Evidence:** `Sources/SwiftTerm/EscapeSequenceParser.swift` at `c3436be` — no Ptmux case.  
**Port complexity:** Medium. The `dispatchDcs` hook point still exists in
`EscapeSequenceParser.swift` (line 650 area); adding the case is the same pattern. The
`PtmuxDcsHandler.swift` file ports verbatim as a new source file. Main risk: verify the DCS
dispatch signature has not changed (upstream added `cmdXTVERSION` dispatch at line 650 via
`collect == [0x3e]` / `code == 0x71`, same pattern we use for Ptmux — compatible).  
**Gate:** No dedicated check gate; integration is tested via `check-image-decode.sh`'s
multipart cases (which use OSC 1337 inside a tmux passthrough in practice), and by
`check-primitives.sh`.

---

### 0006 — Gate linefeed selection-clear on mouse mode  
**File:** `Sources/SwiftTerm/Mac/MacTerminalView.swift`  
**What it changes:** Changes `if allowMouseReporting` to
`if allowMouseReporting && terminal.mouseMode != .off` in `linefeed()`, so the selection is
only cleared when a mouse-reporting program is active.  
**Upstream state:** The upstream `linefeed` function now reads (line 548 area, confirmed):

```swift
// …
selectNone()
```

The upstream IO rewrite restructured `linefeed`. Looking at the call context (line 548):
`selectNone()` is called unconditionally in the font-reset path in `MacTerminalView.swift`,
not in `linefeed`. The actual `linefeed` delegate method in upstream's new architecture
calls `frameDriver.markDirty()` — it does not call `selectNone()` at all. The selection
management moved into the locking machinery.  
**Verdict:** OBSOLETE  
**Evidence:** `Sources/SwiftTerm/Mac/MacTerminalView.swift:548` — `selectNone()` is in
`set { … }` of `font`, not in `linefeed`. The `linefeed` delegate method no longer clears
selection. The structural defect our patch addressed (unconditional clear on every LF) does
not exist in the rewritten architecture.  
**Port complexity:** None — do not carry forward; verify in integration testing that
selection is preserved during streaming output.  
**Gate:** `check-display-link.sh` (indirectly); manual verification needed.

---

### 0007 — Gate feedPrepare selection-clear on mouse mode  
**File:** `Sources/SwiftTerm/Apple/AppleTerminalView.swift`  
**What it changes:** Changes `if allowMouseReporting` to
`if allowMouseReporting && terminal.mouseMode != .off` in `feedPrepare()`.  
**Upstream state:** `feedPrepareLocked()` at line 4593–4600 (confirmed):

```swift
func feedPrepareLocked() {
    terminal.terminalLock.preconditionLocked()
    search.invalidate()
}
```

No selection clear at all — the rewrite removed it entirely from this path.  
**Verdict:** OBSOLETE  
**Evidence:** `Sources/SwiftTerm/Apple/AppleTerminalView.swift:4593–4600` at `c3436be` —
`feedPrepareLocked` contains only `search.invalidate()`. The selection defect is gone from
this path in the IO rewrite.  
**Port complexity:** None — do not carry forward.  
**Gate:** Same as 0006.

---

### 0008 — Make `draw(_:)` open for subclass override  
**File:** `Sources/SwiftTerm/Mac/MacTerminalView.swift`  
**What it changes:** Changes `override public func draw(_:)` to `override open func draw(_:)`.  
**Upstream state:** `Sources/SwiftTerm/Mac/MacTerminalView.swift:1833` (confirmed):
`override public func draw (_ dirtyRect: NSRect)` — still `public`, not `open`.  
**Verdict:** STILL-NEEDED  
**Evidence:** `Sources/SwiftTerm/Mac/MacTerminalView.swift:1833` at `c3436be` — `public`,
not `open`. The Metal renderer draw path requires subclass override in
`GoblinPortalTerminalView`.  
**Port complexity:** Trivial — same one-word change, same line context.  
**Gate:** `check-metal-renderer.sh` (Metal path requires the open override).

---

### 0009 — Expose search-state-changed hook  
**Files:** `Sources/SwiftTerm/Mac/MacTerminalView.swift`,
`Sources/SwiftTerm/TerminalViewSearch.swift`  
**What it changes:** Adds `open func searchStateDidChange(term:options:)` callback and
`findAllMatchPositions(_:options:limit:)` public method for all-match highlight overlays.  
**Upstream state:** `grep -n "searchStateDidChange\|findAllMatchPositions"` across upstream
— neither symbol exists. `hideFindBar()` at line 3621 (confirmed) does not call any hook.
`handleFindBarSearchChanged` at line 3626 does not call any hook.  
**Verdict:** STILL-NEEDED  
**Evidence:** `Sources/SwiftTerm/Mac/MacTerminalView.swift:3621,3626` at `c3436be` — no
`searchStateDidChange` calls. The feature is Goblin Portal–specific (all-match highlight
overlay driven by `GoblinPortalTerminalView`).  
**Port complexity:** Medium. The `hideFindBar` and `handleFindBarSearchChanged` sites still
exist; the hook insertions are the same. `findAllMatchPositions` in `TerminalViewSearch`
needs re-checking against the search engine changes in the rewrite.  
**Gate:** No dedicated script gate; exercised by the find-bar path (`check-find-menu.sh`
structurally; full behaviour is daily-drive territory).

---

### 0010 — Pace redraws on `NSView.displayLink`  
**Files:** New `MacDisplayLinkPacer.swift`, `MacTerminalView.swift`, `AppleTerminalView.swift`  
**What it changes:** Replaces upstream's `asyncAfter`-based 16.67 ms timer with
`NSView.displayLink`, adding `MacDisplayLinkPacer` to pace redraws at vsync.  
**Upstream state:** `MacDisplayLinkPacer.swift` does not exist in upstream (confirmed: `ls
Sources/SwiftTerm/Mac/` — no such file). Upstream now uses a `FrameDriver` backed by
`NSView.displayLink(target:selector:)` (confirmed: `MacTerminalView.swift:972` — doc
comment: "The frame driver runs on `NSView.displayLink(target:selector:)…`"). Upstream's
rewrite independently converged on the same approach: display-link–driven frame pacing
through `FrameDriver` / `FrameDriverSignal`.  
**Verdict:** ALREADY-UPSTREAM (by convergence — different implementation, same mechanism)  
**Evidence:** `Sources/SwiftTerm/Mac/MacTerminalView.swift:972` and `FrameDriver` usage
throughout — upstream now drives frames from `NSView.displayLink`. The `asyncAfter` timer
is gone.  
**Port note:** Our `MacDisplayLinkPacer` and its `SWIFTTERM_DISPLAY_LINK` env-var escape
hatch will be **replaced** by upstream's `FrameDriver`. The re-vendor must verify that
`check-display-link.sh` passes against upstream's new frame driver. Patch 0016's adaptive
pause logic (which extends 0010) needs similar evaluation — see 0016.  
**Gate:** `check-display-link.sh`

---

### 0011 — Cache empty glyphs and font names  
**File:** `Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift`  
**What it changes:** Adds `emptyGlyphs: Set<GlyphKey>` to cache zero-bounds rasterizer
misses (space glyph), and `fontNameCache` to avoid calling `CTFontCopyPostScriptName`
per glyph.  
**Upstream state:** Upstream has restructured the glyph cache substantially. A
`GlyphBitmapCacheLookup` enum with a `.permanentEmpty` case exists
(`MetalTerminalRenderer.swift:286–319`, confirmed), and `storePermanentEmpty` /
`cachePermanentEmpty` are present (line 3184). The `GlyphKey` struct is redesigned with
`rasterFontToken` instead of `fontName+size`. `postScriptName` caching: the `ShaperKey`
still calls `CTFontCopyPostScriptName` (line 3598) but the raster key path uses font tokens
instead.  
**Verdict:** ALREADY-UPSTREAM (by convergence — different design, same intent)  
**Evidence:** `Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift:286–328` —
`PermanentEmptyGlyphCache` with LRU eviction, `storePermanentEmpty`, `lookup` returning
`.permanentEmpty`. This is a more sophisticated version of our `emptyGlyphs: Set<GlyphKey>`.  
**Port note:** The upstream implementation supersedes ours. `GlyphKey` no longer uses
`fontName: String` + `size: CGFloat` — the re-vendor must drop our `emptyGlyphs` and
`fontNameCache` additions and rely on upstream's `PermanentEmptyGlyphCache`. The
`backingScale` field we added to `GlyphKey` for patch 0012 needs re-evaluation (see 0012).  
**Gate:** `check-metal-renderer.sh`, `check-metal-throughput.sh`

---

### 0012 — Rasterize colour glyphs at logical size  
**Files:** `Sources/SwiftTerm/Apple/Metal/CoreTextGlyphRasterizer.swift`,
`Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift`  
**What it changes:** Adds `backingScale` to `CoreTextGlyphRasterizer`; for colour glyphs
(`kCTFontTraitColorGlyphs`) rasterizes the logical-size font under a scaled CTM, matching
Core Text's own recipe, fixing ~20% size error and positional offset for Apple Color Emoji
(N4).  
**Upstream state:** `CoreTextGlyphRasterizer.swift` in upstream has a completely different
API — `rasterize(font:glyph:)` returns `GlyphRasterizationResult` (not `GlyphBitmap?`),
and takes an optional `metrics: GlyphMetrics` parameter (lines 18–26, confirmed). No
`backingScale` property, no `ctmScale`, no `traitColorGlyphs` branch visible in the
rasterizer.  
**Verdict:** STILL-NEEDED (UNVERIFIED for whether upstream fixed emoji sizing independently)  
**Evidence:** `Sources/SwiftTerm/Apple/Metal/CoreTextGlyphRasterizer.swift:18–26` —
`backingScale` absent. The upstream rasterizer API changed substantially; whether the emoji
sizing fix was independently addressed is **UNVERIFIED** — the rasterizer's full body was
not read due to the API change making line-level comparison unreliable. The fix should be
re-verified visually after re-vendor.  
**Port complexity:** High. Both the rasterizer API and the `GlyphKey` structure changed.
The fix logic (detect `traitColorGlyphs`, rebuild logical font, scale CTM) must be
reimplemented against the new rasterizer shape. The `backingScale` field on `GlyphKey`
(added by 0012) needs to move into whatever key mechanism upstream now uses.  
**Gate:** `check-render-parity.sh` (emoji cases — case (d))

---

### 0013 — Fix combining mark after wide char  
**Files:** `Sources/SwiftTerm/Apple/AppleTerminalView.swift`,
`Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift`  
**What it changes:** Detects zero-advance combining glyphs (advance < 0.5 × cellWidth) in
wide-char segments and pins them to the previous glyph's column instead of advancing by
`columnWidth`, fixing misplaced combining marks after CJK chars (F10, #151).  
**Upstream state:** Both files restructured. `AppleTerminalView.swift:3608,3623,3675`
(confirmed) has new comments mentioning "combining marks" and "same-cell glyphs" in the
glyph positioning loop. `MetalTerminalRenderer.swift:2097,2142` similarly mentions
"combining marks". The surrounding code appears to handle this case.  
**Verdict:** PARTIAL — UNVERIFIED  
**Evidence:** `AppleTerminalView.swift:3608,3623` at `c3436be` — combining-mark comments
present in the glyph positioning code. Whether the fix is semantically equivalent to ours
or uses a different approach is **UNVERIFIED** without reading the full loop body. The
presence of the combining-mark comments is a strong signal of independent coverage, but
must be confirmed by running `check-render-parity.sh` (F10 case) against upstream.  
**Port complexity:** If upstream already handles this: None. If not: Medium — same
detection logic, different loop structure.  
**Gate:** `check-render-parity.sh` (F10 correctness assertion)

---

### 0014 — Disable ligatures in both renderers  
**Files:** `Sources/SwiftTerm/Mac/MacTerminalView.swift`,
`Sources/SwiftTerm/Apple/AppleTerminalView.swift`,
`Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift`  
**What it changes:** Adds `open var disableLigatures: Bool` to the terminal view, injects
`kCTLigatureAttributeName: 0` in Core Text attributes, and adds `disableLigatures` to
`ShaperKey` for the Metal path.  
**Upstream state:** `grep -n "disableLigatures\|kCTLigatureAttribute"` across both upstream
files returns nothing. `ShaperKey` at line 3550 has `fontName`, `fontSize`, `text` — no
`disableLigatures` field (confirmed). No ligature-disable API exists upstream.  
**Verdict:** STILL-NEEDED  
**Evidence:** `MetalTerminalRenderer.swift:3550` and `AppleTerminalView.swift` at
`c3436be` — no ligature control. This is a Goblin Portal feature wired via
`AppConfig.ligatures → TerminalPane.applyLigatures(_:)`.  
**Port complexity:** Medium-High. The `ShaperKey` struct changed (uses `fontName` string at
line 3598 still — same pattern). The Core Text attribute injection point in
`getAttributes(_:withUrl:)` needs locating in the rewritten `AppleTerminalView`. The stored
property trick (`_disableLigatures` in `MacTerminalView`, property in the extension) is a
Swift limitation that persists.  
**Gate:** `check-render-parity.sh` (ligature cases)

---

### 0015 — Proportional scrollbar thumb  
**File:** `Sources/SwiftTerm/Apple/AppleTerminalView.swift`  
**What it changes:** Replaces the `max(proportion, 0.01)` floor with
`max(proportion, 1.0/CGFloat(rows))` so the thumb tracks position at any scrollback depth.  
**Upstream state:** `scrollThumbsizeLocked()` at line 4415–4422 (confirmed):

```swift
return max(CGFloat(displayBuffer.rows) / CGFloat(displayBuffer.lines.count), 0.01)
```

Still uses `0.01` hardcoded floor.  
**Verdict:** STILL-NEEDED  
**Evidence:** `Sources/SwiftTerm/Apple/AppleTerminalView.swift:4422` at `c3436be` — `0.01`
floor unchanged.  
**Port complexity:** Trivial — same file, same function, same one-expression change. The
function was renamed from `scrollThumbsize` to `scrollThumbsizeLocked` upstream; the fix
applies to the `Locked` variant.  
**Gate:** No dedicated gate; covered by daily-drive scrollbar behaviour.

---

### 0016 — Pause sooner for slow producers  
**File:** `Sources/SwiftTerm/Mac/MacDisplayLinkPacer.swift`  
**What it changes:** Adds adaptive pause logic to `MacDisplayLinkPacer`: when the gap since
the previous paint exceeded the idle window, pause after ONE idle tick instead of
`idleTicksBeforePause` (8). Adds `adaptiveIdlePauseEnabled` / `SWIFTTERM_ADAPTIVE_PAUSE`.  
**Upstream state:** `MacDisplayLinkPacer.swift` does not exist (confirmed — see 0010). The
`FrameDriver` in upstream runs `NSView.displayLink`; its idle/pause behaviour is not
analysed in detail, but the file is gone.  
**Verdict:** STILL-NEEDED (as a concept; needs reimplementation against `FrameDriver`)  
**Evidence:** No `MacDisplayLinkPacer.swift` in upstream `Sources/SwiftTerm/Mac/`. The
adaptive pause optimisation (2160 → 480 ticks for a 12 Hz spinner at 144 Hz) addresses a
real measured cost (`.afk/research/metal-idle-encode-2026-10-18.md`). Whether upstream's
`FrameDriver` has equivalent idle-pause logic is **UNVERIFIED** and must be measured.  
**Port complexity:** High. The entire `MacDisplayLinkPacer.swift` file must be replaced or
its logic ported into upstream's `FrameDriver` extension point. The `SWIFTTERM_ADAPTIVE_PAUSE`
env var and `adaptiveIdlePauseEnabled` static need new homes.  
**Gate:** `check-display-link.sh` (case 9 — adaptive pause falsification)

---

### 0017 — XTVERSION, alt-scroll mode 1007, mode 2027  
**Files:** `Sources/SwiftTerm/Terminal.swift`,
`Sources/SwiftTerm/EscapeSequenceParser.swift`,
`Sources/SwiftTerm/Mac/MacTerminalView.swift`,
new `XtVersionDcsHandler.swift`  
**What it changes:** Three additions — (a) XTVERSION (`DCS > q`), (b) alternate scroll mode
1007 as a real DECSET/DECRST property (`altScrollMode`), (c) mode 2027 reports
`modeAlwaysReset`.  

**Upstream state — XTVERSION:** Upstream has `cmdXTVERSION` dispatched from
`EscapeSequenceParser` at line 650, handled in `Terminal.swift:5249–5276` (confirmed).
The response uses `SwiftTermBuildInfo.tag/branch/version` to build an identity string —
it always reports "SwiftTerm" plus its own build tag, not the host app's version. Our
`XtVersionDcsHandler.swift` + `Terminal.xtVersion` let the host app set the identity.  
**Upstream state — mode 1007:** Upstream has `alternateScrollMode: Bool = true` at
`Terminal.swift:700` (confirmed), with DECSET/DECRST wired at lines 6445/6685. The
`scrollWheel` in `MacTerminalView.swift:4471` reads `terminal.alternateScrollMode`
(confirmed). This is the same semantics as our `altScrollMode`.  
**Upstream state — mode 2027:** `grep -n "2027" Sources/SwiftTerm/Terminal.swift` —
UNVERIFIED whether upstream reports `modeAlwaysReset` for 2027 or ignores it.  
**Verdict:** PARTIAL  
- XTVERSION dispatch: ALREADY-UPSTREAM (upstream dispatches it). **However**, upstream
  always identifies as "SwiftTerm"; our `Terminal.xtVersion` setter that lets the host
  override is STILL-NEEDED for Goblin Portal to report its own name.  
  Evidence: `Terminal.swift:5249–5258` — identity is `SwiftTermBuildInfo`-based only.
- Mode 1007: ALREADY-UPSTREAM. Evidence: `Terminal.swift:691–700`, `6445`, `6685`; 
  `MacTerminalView.swift:4471`. Our `altScrollMode` property merges into upstream's
  `alternateScrollMode`.
- Mode 2027: UNVERIFIED — needs line-level check of upstream's DECRQM table for case 2027.  
**Port complexity:** Low for 1007 (rename `altScrollMode` → `alternateScrollMode`). For
XTVERSION: add only the `xtVersion` override property and wire it into upstream's existing
`cmdXTVERSION` (one property + one line in the identity builder). `XtVersionDcsHandler.swift`
is not needed — upstream already handles the DCS dispatch; just extend the identity method.  
**Gate:** `check-primitives.sh` (XTVERSION row, 1007 round-trip, 2027 reporting)

---

### 0018 — Bound inline-image payloads  
**Files:** `Sources/SwiftTerm/EscapeSequenceParser.swift`, `Sources/SwiftTerm/Terminal.swift`,
`Sources/SwiftTerm/Apple/AppleTerminalView.swift`  
**What it changes:** Three guards — (a) OSC accumulation cap at 65 MiB
(`_oscLimitExceeded`), (b) 32 MiB encoded payload cap before base64 decode, (c) ImageIO
header check (type allowlist + 8192 px side limit) in `createImage` and
`createImageFromBitmap`.  

**Upstream state — OSC cap:** Upstream `EscapeSequenceParser` has `_oscLimitExceeded`
(confirmed at lines 491, 500, 515, 561, 566) with `maximumOscBytes = 65 * 1024 * 1024`
(line 515). The implementation is more sophisticated than ours: per-instance configurable
via `init(maximumOscBytes:)`, with `resetOsc` helpers. The issue body correctly noted this
convergence.  
**Upstream state — payload cap + createImage guard:** `Terminal.swift` — no
`maximumInlineImageEncodedBytes`. `AppleTerminalView.swift:4856–4858` shows
`createImage` with no ImageIO header check — just `guard let img = TTImage(data: data)`.
`createImageFromBitmap:4830` has no dimension bounds check.  
**Verdict:** PARTIAL  
- OSC cap: ALREADY-UPSTREAM. Evidence: `EscapeSequenceParser.swift:515`.
- Encoded payload cap (32 MiB in `osciTerm2`): STILL-NEEDED. Evidence: `Terminal.swift`
  — no `maximumInlineImageEncodedBytes`. `createImage` in `AppleTerminalView.swift:4856`
  calls `TTImage(data:)` directly.
- ImageIO type/dimension guard in `createImage` and `createImageFromBitmap`: STILL-NEEDED.
  Evidence: `AppleTerminalView.swift:4830–4858` — no `CGImageSourceCopyPropertiesAtIndex`
  call, no type allowlist, no side-limit check.  
**Port complexity for carried portions:** Medium. The `osciTerm2` function in `Terminal.swift`
may have moved or been renamed in the IO rewrite — needs location check. The `createImage`
and `createImageFromBitmap` changes are self-contained guard blocks at the function entry
and port cleanly once the function signatures are confirmed.  
**Gate:** `check-image-decode.sh` (cases for oversize payload, bad type, forged dimensions)

---

### 0019 — OSC 1337 multipart file (MultipartFile/FilePart/FileEnd)  
**Files:** `Sources/SwiftTerm/Terminal.swift`  
**What it changes:** Adds `ITermMultipartTransfer` state and three new `osciTerm2` cases
(`MultipartFile`, `FilePart`, `FileEnd`) to handle iTerm2 3.5+ chunked image transfers,
which modern `imgcat` sends by default.  
**Upstream state:** `grep -n "MultipartFile\|FilePart\|FileEnd\|iTermMultipart"` across
upstream `Sources/` returns nothing (confirmed). Upstream does not implement multipart
OSC 1337.  
**Verdict:** STILL-NEEDED  
**Evidence:** `Sources/SwiftTerm/Terminal.swift` at `c3436be` — no multipart iTerm2 state
or cases. The issue body confirms: "upstream does NOT parse OSC 1337 MultipartFile/FilePart/FileEnd".  
**Port complexity:** Medium-High. The `osciTerm2` function needs locating in the rewritten
`Terminal.swift` (it may be reorganised under the IO rewrite). The `ITermMultipartTransfer`
struct and the three new `switch` cases port verbatim in logic, but the surrounding
`osciTerm2` context must be re-read. The `insertInlineImage` helper (refactored from
single-shot `File=` as part of 0019) needs to survive as a shared path.  
**This is the highest-priority upstream PR candidate** (see below).  
**Gate:** `check-image-decode.sh` (multipart cases, real `imgcat` stream fixture)

---

## Summary table

| # | Patch | Files touched (upstream) | Verdict | Port effort |
|---|-------|--------------------------|---------|-------------|
| 0001 | Metal shader as `.copy` | `Package.swift` | **STILL-NEEDED** (machine-specific) | Trivial |
| 0002 | `isWrapped` buffer-absolute | `Buffer.swift` | **ALREADY-UPSTREAM** | None |
| 0003 | Alt-buffer narrowing trim | `Buffer.swift` | **STILL-NEEDED** | Low |
| 0004 | `#if DEBUG` resize guard | `Buffer.swift` | **STILL-NEEDED** | Trivial |
| 0005 | DCS Ptmux passthrough | `EscapeSequenceParser.swift` + new file | **STILL-NEEDED** | Medium |
| 0006 | Linefeed selection-clear gate | `MacTerminalView.swift` | **OBSOLETE** | None |
| 0007 | feedPrepare selection-clear gate | `AppleTerminalView.swift` | **OBSOLETE** | None |
| 0008 | `draw(_:)` open | `MacTerminalView.swift` | **STILL-NEEDED** | Trivial |
| 0009 | Search-state hook | `MacTerminalView.swift` + search file | **STILL-NEEDED** | Medium |
| 0010 | DisplayLink pacing | `MacDisplayLinkPacer.swift` (gone upstream) | **ALREADY-UPSTREAM** (converged) | Must verify FrameDriver |
| 0011 | Empty-glyph + font-name cache | `MetalTerminalRenderer.swift` | **ALREADY-UPSTREAM** (converged) | None |
| 0012 | Colour emoji logical-size raster | `CoreTextGlyphRasterizer.swift`, `MetalTerminalRenderer.swift` | **STILL-NEEDED** (UNVERIFIED if upstream fixed independently) | High |
| 0013 | Combining mark after wide char | `AppleTerminalView.swift`, `MetalTerminalRenderer.swift` | **PARTIAL** (UNVERIFIED — combining-mark comments present) | Low–Medium |
| 0014 | Disable ligatures | `MacTerminalView.swift`, `AppleTerminalView.swift`, `MetalTerminalRenderer.swift` | **STILL-NEEDED** | Medium-High |
| 0015 | Proportional scrollbar thumb | `AppleTerminalView.swift` | **STILL-NEEDED** | Trivial |
| 0016 | Adaptive display-link pause | `MacDisplayLinkPacer.swift` (gone upstream) | **STILL-NEEDED** (needs FrameDriver port) | High |
| 0017 | XTVERSION + mode 1007 + 2027 | `Terminal.swift`, `EscapeSequenceParser.swift`, `MacTerminalView.swift` | **PARTIAL** (1007 already-upstream; XTVERSION dispatch up; xtVersion override needed; 2027 UNVERIFIED) | Low |
| 0018 | Bound inline-image payloads | `EscapeSequenceParser.swift`, `Terminal.swift`, `AppleTerminalView.swift` | **PARTIAL** (OSC cap upstream; payload cap + createImage guards still-needed) | Medium |
| 0019 | OSC 1337 multipart | `Terminal.swift` | **STILL-NEEDED** | Medium-High |

### Counts
- **ALREADY-UPSTREAM:** 0002, 0010 (by convergence), 0011 (by convergence) — **3**
- **OBSOLETE:** 0006, 0007 — **2**
- **STILL-NEEDED (full):** 0001, 0003, 0004, 0005, 0008, 0009, 0014, 0015, 0019 — **9**
- **STILL-NEEDED (partial):** 0012, 0016 — **2**
- **PARTIAL (mixed):** 0013, 0017, 0018 — **3**

---

## Recommended upstream PR candidates

These are **candidates only** — no PRs opened.

| Priority | Patch(es) | Rationale |
|----------|-----------|-----------|
| 1 | 0019 (multipart OSC 1337) | Modern `imgcat` sends this by default; upstream has zero support. High user impact, self-contained addition. |
| 2 | 0018 (payload cap + `createImage` guards) | Security/robustness fix. The OSC cap is already upstream; only the inline-image guards need PR. |
| 3 | 0003 (alt-buffer narrowing trim) | Correctness fix for a real tmux defect; entirely general. Issue #494 still open. |
| 4 | 0004 (`#if DEBUG` resize guard) | Low-risk cleanup; `fatalError` ungated in release is hostile to terminal apps hosting long-running agents. |
| 5 | 0005 (Ptmux passthrough) | Widely useful; iTerm2, Ghostty, Kitty, WezTerm all implement it. Self-contained. |
| 6 | 0015 (scrollbar thumb floor) | Trivial fix with clear rationale; easily reviewed. |
| 7 | 0002 (isWrapped) | Already upstream by rewrite, but the tracking issue #494 remains open — a comment noting closure would help. |

Patches 0001, 0008, 0009, 0012, 0013, 0014, 0016 are Goblin Portal–specific features or
machine-specific workarounds not appropriate for upstream PRs.

---

## Port-order recommendation

Ordered by dependency and risk:

1. **Baseline:** Re-vendor against `c3436be` (or the next tagged release once upstream tags).
   Run all existing gates; record which fail before any patches are applied.

2. **Drop immediately (no action):** 0006, 0007 (obsolete), 0002, 0011 (already upstream).

3. **Trivial carries (apply first, lowest risk):** 0004, 0008, 0015.

4. **Low-effort, high-value:** 0003, 0017 (just the `xtVersion` override + 2027 DECRQM
   check). Both are small and well-understood.

5. **Medium effort:** 0005, 0009, 0018 (partial — only payload cap + `createImage` guards),
   0019. These are self-contained additions; port once the surrounding `osciTerm2` /
   `Terminal.swift` layout is confirmed.

6. **High effort / needs measurement first:** 0010/0016 (FrameDriver integration — measure
   idle CPU against `check-display-link.sh` before writing any code; upstream's FrameDriver
   may already be adequate), 0012 (rasterizer API changed; re-measure emoji pixel metrics
   against `check-render-parity.sh` before porting).

7. **Verify, then decide:** 0013 (run `check-render-parity.sh` F10 case against upstream
   unpatched; if green, drop; if red, port).

8. **Machine-specific:** 0001 — apply only if the Metal offline compiler is absent. Make the
   decision explicit in `bootstrap-vendor.sh`.

9. **Feature flag:** 0014 (ligatures) — port last; it touches the most files and is a
   Goblin Portal–specific user preference, not a correctness fix.

---

## UNVERIFIED items requiring follow-up

- **0012 (colour emoji):** Whether upstream's rasterizer rewrite independently fixed the
  logical-size bug. Run `check-render-parity.sh` emoji case against unpatched upstream.
- **0013 (combining mark):** Whether upstream's new glyph loop handles zero-advance glyphs.
  Run `check-render-parity.sh` F10 case against unpatched upstream.
- **0016 (adaptive pause):** Whether upstream's `FrameDriver` has equivalent idle-pause
  behaviour. Run `check-display-link.sh` case 9 and `measure-metal-idle-encode.sh` against
  upstream.
- **0017 (mode 2027):** Whether upstream's DECRQM table reports `modeAlwaysReset` for 2027.
  One grep of the DECRQM switch in `Terminal.swift` resolves this.
- **0001 (Metal shader):** Whether the build machine at re-vendor time has the Metal offline
  compiler. Run `swift build` and observe.
