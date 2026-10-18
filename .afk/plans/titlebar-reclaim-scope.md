# Titlebar reclaim — scope (2026-10-12)

Goal (operator): in a NORMAL (windowed) window, use as much of the screen as possible by
reclaiming the titlebar band. Scoping only — no shipped code was changed. Everything below
marked **MEASURED** came from a throwaway offscreen harness (`/tmp/gp-tb/h1/main.swift`,
`@testable import GoblinPortal`, same link recipe as `check-first-window.sh`), run on
**macOS 27.0.1 (26A434)**, harness linked with `sdk 27.0` (so Liquid Glass is ON, matching
the shipped bundle whose `-platform_version macos 14.0 <sdk>` also turns glass on; `swift run`
would be compat-mode). Candidate fixes were applied to an **APFS clone** (`cp -c -R app vendor
patches /tmp/gp-tb/clone/`), never to shipped files. Nothing on macOS 14/15 was measured.

---

## 1. Root cause — MEASURED

### 1a. The recorded cause is wrong (on macOS 27 at least)

`LiquidGlass.swift:22-30` and AFK.md ("Liquid Glass is ADOPTED" bullet) say
*"NSSplitViewController does not propagate safeAreaInsets.top to DocumentAreaViewController."*
**Refuted.** With `.fullSizeContentView` on a real `SpaceWindowController`, the document area's
`view.safeAreaInsets.top` is **32.0** (68.0 when the native Space tab bar or a `.bottom`
accessory is showing), and `safeAreaRect` is exactly `contentLayoutRect`. The inset IS
propagated; `DocumentAreaViewController.viewDidLayout` (`:144-166`) simply lays out against
`view.bounds` and never reads it. The real cause is "manual frame layout ignores the safe area
it is given", which is a one-function fix.

Also stale: `SpaceWindowController.swift:166-169` claims macOS 26 uses
fullSizeContentView + transparent titlebar "and safe-area insets prevent the clipping".
Neither is true: `LiquidGlass.configureWindow` only sets `titlebarSeparatorStyle = .none`
(`LiquidGlass.swift:105-107`) and nothing reads safe area. The band is also **32pt** on
macOS 27, not the 28pt the `:130-141` comment measured on an earlier OS.

### 1b. Numbers (window 1100x712 frame, default config: 14pt font, padding 4/4, sidebar 250pt)

`TERM-TOP Δ` = terminal view's top (window coords) − `contentLayoutRect.maxY`. > 0 ⇒ row 0 is
under the titlebar.

| Scenario | contentView h | contentLayoutRect h | docArea safeArea.top | sidebar safeArea.top | terminal frame (window) | rows×cols | TERM-TOP Δ |
|---|---|---|---|---|---|---|---|
| **Control (today)** | 680 | 680 | 0 | 0 | y4 h672 maxY676 | **39×91** | −4 |
| FSC, opaque titlebar, no fix | 712 | 680 | 32 | 42 | y4 h704 maxY708 | 41×91 | **+28** (the bug) |
| FSC + transparent, no fix | 712 | 680 | 32 | 42 | maxY708 | 41×91 | **+28** |
| FSC + transparent + titleVisibility .hidden, no fix | 712 | 680 | 32 | 42 | maxY708 | 41×91 | **+28** |
| FSC, fix = inset by `view.safeAreaInsets.top` | | | | | maxY676 | 39×91 | −4 (== control) |
| FSC, fix = inset by `contentLayoutRect` converted to view | | | | | maxY676 | 39×91 | −4 (== control) |
| FSC, fix = **"controls-aware"** (below), sidebar visible | | | | | y4 h704 maxY708 | **41×91 (+2)** | +28 (intended: band right of sidebar, x≥254 vs controls maxX 106) |
| FSC, controls-aware, sidebar **collapsed** | | | | | x4 h672 maxY676 | 39×119 | −4 (band withheld: traffic lights over terminal) |
| Control, 2 docs (strip visible) | | | | | strip y650-680; term h642 | 37×91 | −34 |
| FSC, controls-aware, 2 docs | | | | | **strip y682-712 (in band)**; term h674 | **39×91 (+2)** | −2 (below strip) |
| FSC, controls-aware, 2 docs, sidebar collapsed | | | | | strip y650-680 | 37×119 (+0) | −34 |
| Control, 2 Spaces (native tab bar) | 644 | 644 | 0 | 0 | h636 | 37×91 | −4 |
| FSC, 2 Spaces, controls-aware **without KVO** | 712 | 644 | 68 | 42 | h704 maxY708 | 41 | **+64 (stale! under tab bar)** |
| FSC, 2 Spaces, controls-aware **with KVO** on `contentLayoutRect` | | 644 | 68 | | h636 maxY640 | 37×91 (+0) | −4 |
| FSC, `.bottom` banner accessory (36pt), without KVO | | 644 | 68 | | maxY708 | 41 | **+64 (stale)** |
| FSC, banner, with KVO | | 644 | | | maxY640 | 37 | −4 |

Other measured facts:

- **Native tab bar** (2+ Spaces) is a `.bottom` titlebar accessory, 36pt, at y644-680. Under
  FSC it spans only x250-1100 (the sidebar runs full height under it). `tabGroup.isTabBarVisible
  = true`; it still appears with `titleVisibility = .hidden` / transparent titlebar. Space tabs
  are unaffected — **they keep working** in every FSC variant measured.
- **`contentLayoutRect` changes do NOT trigger `DocumentAreaViewController.viewDidLayout`**
  (the view's bounds don't change — it is full-height under FSC), so any fix that reads the
  layout rect needs a KVO observer on `window.contentLayoutRect` → `view.needsLayout = true`.
  KVO fires (measured 1 fire for tab-bar-appears, 1 for banner).
- **`.fullSizeContentView` changes `NSWindow.frameRect(forContentRect:styleMask:)`**:
  1100x680 → frame h**680** (vs 712 without). `SpaceWindowController.defaultFrame` passes
  `window.styleMask`, so under FSC the first window would open **32pt shorter**, and
  `repairPoisonedSavedFrame` (`+InitialFrame.swift:79-86`, reads `contentRect(forFrameRect:)`)
  would read a poisoned 500x532 frame as 500x532 content and **miss the repair**.
  `check-first-window.sh` case 1 would still pass (content == frame under FSC) — a blind spot.
- **Sidebar content collides with the traffic lights under FSC.** `FileTreeViewController`'s
  root `NSStackView` (`FileTreeViewController.swift:156-182`, autoresizing, `edgeInsets.top`
  2/4pt) ignores its 42pt safe area: the filter `NSSearchField` lands at y688-708 while the
  close/zoom buttons sit at y689-703 x9-69. `hitTest` at (150,700) returns the search field.
  `allowsFullHeightLayout = false` on the sidebar item did NOT change this (still 712 tall).
- **macOS 27 `NSScrollPocket`**: under FSC a 14pt `NSScrollPocket` appears at the sidebar
  scroll view's top (y670-684); in control it is a 1100x32 strip at the titlebar. Ghostty hides
  it on 27 because it covered terminal content (`HiddenTitlebarTerminalWindow.swift`, issue
  ghostty#13390). Here it sits over the sidebar only — risk, not a blocker.
- **Hit-testing the band**: control → `NSTitlebarView`/`NSTextField` (title), drag works.
  FSC+hidden, 1 doc → `GoblinPortalTerminalView` (mouseDown = text selection, **no window
  drag, no double-click-zoom** there). FSC, 2 docs → `DocumentTabStrip` (mouseDown = select
  tab / nothing on empty area; **no drag** today). FSC + opaque/visible title → `NSTitlebarView`
  wins hit-testing over content (so "opaque titlebar + FSC" reclaims nothing usable).

### 1c. The "controls-aware" inset used above (clone-only prototype)

```
full = docArea.maxY − convert(window.contentLayoutRect).maxY      // 32, or 68 with tab bar/banner
band = frameHeight − contentRect(frame, mask − .fullSizeContentView).height   // the bare title row
ctlMaxX = max over visible traffic lights + .left/.leading accessories of maxX (window coords)
inset = (docArea.minX < ctlMaxX + 8 || full > band) ? full : full − band
```
i.e. the document area takes the title row only where nothing AppKit draws is above it, and
only when no tab bar/banner sits below the title row. Plus KVO on `contentLayoutRect`.

---

## 2. Design options

Default font: `AppConfig.defaultFontSize = 14` (`Config.swift:246`); measured cell ≈ 17.2pt
(672pt / 39 rows). Reclaimable band = **32pt ≈ 1.86 rows** → +1 or +2 rows depending on the
fractional remainder at a given window height (+2 measured at 1100x680).

### (A) FSC + transparent + title hidden, terminal enters the band only where clear — RECOMMENDED core
- Gain (measured): **+2 rows** with sidebar visible (1 or 2+ docs); **+0** with sidebar
  collapsed, with 2+ Spaces (tab bar), with config banner, and (UNVERIFIED) in full screen.
- With 2+ docs and the sidebar visible, the strip lands in the band automatically
  (y682-712, x250+) — that is option B for free in the common case.
- Dragging: band over the doc area becomes terminal/strip → needs an explicit drag surface:
  (i) the sidebar's top safe-area band (0…250pt, Finder-style, once the stack honours safe
  area), (ii) empty strip area → `window.performDrag(with:)`, double-click →
  `AppleActionOnDoubleClick` (zoom/minimize) like the system titlebar. Single doc + sidebar
  visible: drag only from the sidebar band. Single doc + sidebar collapsed: band is withheld,
  the real titlebar still drags.
- Title: `titleVisibility = .hidden` hides "project — subtitle" with 1 Space (2+ Spaces: native
  tabs still show titles). Window title remains for Mission Control / Window menu / AX.
- SidebarToggleAccessory (.left, x78-106 in band): unchanged, still in band, gate unaffected.
- ConfigWarningBanner (.bottom): shrinks contentLayoutRect → handled by KVO (measured).
- Liquid Glass 26+: sidebar becomes full-height glass under the band (Apple's intended Tahoe
  look). 14/15: transparent titlebar shows `window.backgroundColor` (already the theme bg) —
  UNVERIFIED visually.
- Full screen: AppKit hides the titlebar in FS; contentLayoutRect should equal bounds → inset
  0. UNVERIFIED; KVO covers the enter/exit transition. Ghostty re-applies its style on FS exit
  because "macOS breaks it usually" — add a `windowDidExitFullScreen` reapply.
- Split panes: unaffected (SplitContainerView is laid out inside the container frame).
- Sidebar under titlebar like Finder: yes — that's what FSC already does (measured); the fix
  is making the sidebar's stack respect `safeAreaInsets.top` so its controls start below the
  traffic lights.

### (B) Document tab strip in the titlebar band (Ghostty `macos-titlebar-style = tabs` analogue)
- Sidebar visible: falls out of A (measured +2 rows at 2 docs).
- Sidebar collapsed: strip would need a leading inset = ctlMaxX + 8 (≈114pt) inside the band;
  saves 30pt ≈ +1-2 rows at 2+ docs. Computed, UNVERIFIED. Strip needs a `leadingInset`
  in `DocumentTabStrip.Layout`.
- Ghostty prior art: `TitlebarTabsTahoeTerminalWindow.swift` puts the **native** NSTabBar into
  an `NSToolbar` (`toolbarStyle = .unifiedCompact`) by re-parenting private views found via
  `firstDescendant(withClassName: "NSTitlebarAccessoryClipView")` and
  `"NSTitlebarAccessoryContainerView"` — the class name changed between macOS 26 and 27 beta 2
  (their own comment, lines 167-169). Moving **Spaces'** native tab bar into the title row is
  the only way to gain with 2+ Spaces; it is private-API surgery and needs a toolbar
  (already rejected). **Not recommended** (call it Option D, out of scope).

### (C) Ghostty "hidden" (title row gone, traffic lights hidden)
- Ghostty's `HiddenTitlebarTerminalWindow.swift`: FSC + transparent + `.hidden` title + hides
  all three traffic lights + **`tabbingMode = .disallowed`** ("disallow tabbing if the titlebar
  is hidden, since that will also hide the tab bar") + hides `NSTitlebarContainerView` + hides
  `NSScrollPocket` on 27 + overrides `contentLayoutRect` to full height + reapplies on every
  `title` set and on FS exit.
- That **disables native tabs = Spaces** → violates the load-bearing constraint. A variant
  that keeps tabbing but hides traffic lights only adds +2 rows in the *collapsed-sidebar*
  case, removes close/min/zoom affordances and the sidebar toggle's neighbourhood, and fights
  AppKit (title setter re-reveals the title view on 15+). **Not recommended**; at most a
  later `"hidden"` value with collapsed-sidebar-only effect.

---

## 3. Recommendation + config surface

**Recommend A (+ B's collapsed-sidebar leading inset as a follow-up).**

```json
"titlebar": "standard"   // default — today's opaque strip, byte-for-byte unchanged
"titlebar": "compact"    // FSC + transparent + title hidden; content enters the title row where clear
```
Fail-soft: unknown value → warning `titlebar 'x' unrecognised (expected one of: standard, compact) — using standard`
(same shape as `closeOnShellExit`, `Config+Load.swift:136-141`). Reload (⌘R / Settings Apply)
re-applies the style live (styleMask toggle keeps the frame; re-run `defaultFrame` math with
the FSC-stripped mask).

### File-by-file (LOC now → est. after; warn ≥315, ceiling 350)

| File | Now | Δ | After | Notes |
|---|---|---|---|---|
| `DocumentAreaViewController.swift` | 167 | +12 | ~179 | `viewDidLayout` lays out in `layoutBounds` from a helper; KVO install in `viewDidAppear` |
| **new** `DocumentAreaViewController+TitlebarInset.swift` | 0 | +70 | ~70 | inset policy (contentLayoutRect conversion, controls-aware rule, KVO) — pure-ish fn `topInset(viewFrameInWindow:contentLayoutRect:titleRowHeight:controlsMaxX:allowBand:)` so the gate can table-test it |
| `FileTreeViewController.swift` | 280 | +8 | ~288 | stack top edge honours `view.safeAreaInsets.top` (override `viewDidLayout` or constrain to `safeAreaLayoutGuide`); covers the SCM switcher too (it is inserted into this stack, `+SidebarActivity.swift:88`) |
| `SpaceWindowController.swift` | **345** | −4 / +1 | ~342 | **AT CEILING.** Replace stale `:166-169` comment, update `:130-141` comment to point at the new file, one call `applyTitlebarStyle(config)`. Do not add anything else |
| **new** `SpaceWindowController+Titlebar.swift` | 0 | +80 | ~80 | apply/unapply style, `windowDidExitFullScreen` reapply, FSC-stripped mask helper |
| `SpaceWindowController+InitialFrame.swift` | 90 | +4 | ~94 | `defaultFrame`/`repairPoisonedSavedFrame` use `styleMask.subtracting(.fullSizeContentView)` (no-op today) |
| `LiquidGlass.swift` | 132 | −2 | ~130 | correct the refuted "not propagated" header |
| `Config.swift` | **335** | +3 | ~338 | **already ≥315 (WARN)**: one `ConfigFile` field, one `AppConfig` field, one `defaults()` entry only. Enum + names live elsewhere |
| **new** `Config+Titlebar.swift` | 0 | +40 | ~40 | `TitlebarStyle` enum (Foundation-only, so a headless gate can compile it), `named(_:)`, `configNames` |
| `Config+Load.swift` | 225 | +8 | ~233 | parse + warning |
| `StarterConfig.swift` | 101 | +2 | ~103 | commented `"titlebar": "standard"` |
| `AppDelegate.swift` | 311 | +1 | ~312 | near warn: one line in `reloadConfig` loop (or route via `controller.apply(config:)` in the new file to add 0 here) |
| `DocumentTabStrip+Mouse.swift` (PR3) | 191 | +20 | ~211 | empty-area drag (`performDrag`) + double-click per `AppleActionOnDoubleClick` |
| `DocumentTabStrip.swift` (PR3) | 299 | +6 | ~305 | `leadingInset` in `Layout` — close to warn; put inset math in `+Affordances` if it grows |
| `SpaceViewController.swift` | **348** | 0 | 348 | **DO NOT TOUCH** (2 lines from ceiling). `syncDocumentChrome` needs no change |
| `app/Scripts/check-starter-config.sh` | — | +1 | | add `"titlebar"` to `configFileKnownTopLevelKeys` (drift guard exits 1 otherwise) |
| **new** `app/Scripts/check-titlebar-layout.sh` (+ `-harness.swift` split if >350) | 0 | ~300+250 | | see §4 |
| `AFK.md` | | | | rows for 4 new files + gate; correct the Liquid Glass bullet; gate count 53→54 |

---

## 4. Verification plan

### New gate `check-titlebar-layout.sh` (offscreen GUI, `@testable import GoblinPortal`, verdict = exit code, 1 real / 2 env)
Link recipe identical to `check-first-window.sh`. Windows parked at (−20000,−20000), `.accessory`
policy, never `activate`. Terminals added with `addTerminalDocument(start: false)` (no pty).
Measures the consumer's real frames (terminal view, strip, sidebar subviews) in window coords —
never the policy's own return value.

| # | Case | Assertion |
|---|---|---|
| C0 | **Control**: `standard` | no FSC in mask; contentLayoutRect == contentView bounds; terminal top ≤ clr.maxY; record baseline rows R0 |
| C1 | PR1 fix: harness forces FSC on a `standard` window | terminal top ≤ clr.maxY **and** rows == R0 (zero visible change) |
| C2 | `compact`, sidebar visible, 1 doc | terminal top > clr.maxY (entered band) **and** terminal minX ≥ controlsMaxX + 8 **and** rows > R0 |
| C3 | `compact`, sidebar collapsed | terminal top ≤ clr.maxY (no traffic lights over row 0) |
| C4 | `compact`, 2 Spaces (`addTabbedWindow`), **no manual relayout** | terminal top ≤ clr.maxY (tab bar) |
| C5 | `compact` + a `.bottom` accessory 36pt | terminal top ≤ clr.maxY |
| C6 | `compact`, 2 docs, sidebar visible | strip within band, strip.minX ≥ controlsMaxX, terminal top ≤ strip.minY |
| C7 | `compact` sidebar | topmost visible sidebar subview maxY ≤ sidebar safeAreaRect.maxY (no traffic-light collision) |
| C8 | `compact` first window | frame height == `standard` frame height (712 for 680 content); poisoned 500x532 still repaired |
| C9 | config parse (headless part, Foundation-only `Config+Titlebar.swift`) | `standard`/`compact` map; typo → warning + `.standard`; omitted → `.standard` |
| C10 | reload toggle `standard`→`compact`→`standard` | frame unchanged; rows return to R0 |

Falsification (each on an APFS clone of SHIPPED source, `cp -c -R app vendor patches $TMP`,
`swift build` there (~14s incremental since `.build` clones too), re-run harness, must exit 1,
attributed to the named case):
1. drop the contentLayoutRect inset (layout against `view.bounds` again) → C1 fails (+28pt, measured).
2. remove the KVO observer → C4 and C5 fail (+64pt, measured).
3. controls-aware rule ignores the sidebar-collapsed branch → C3 fails (+28pt, measured).
4. revert FileTree safe-area respect → C7 fails (search field y688-708 vs lights y689-703, measured).
5. `defaultFrame` uses the FSC mask → C8 fails (frame h680, measured).
6. drop `ctlMaxX` check (always give the band) → C3 fails; drop the `full > band` term → C4 fails.
A mutant that will not compile/apply exits 2, not 1.

### Existing gates
- `check-first-window.sh`: default unaffected; stays green. Its blind spot under FSC (content ==
  frame) is covered by C8 rather than editing it.
- `check-sidebar-toggle.sh`: default unaffected; the accessory remains `.left` in the band under
  `compact` (measured x78-106) — optionally parametrise it to also run under `compact`.
- `check-config-warnings.sh`: policy unaffected; the banner/contentLayoutRect interaction is C5.
- `check-cell-snap.sh` (needs 2x + 1x displays): re-run — layout now depends on window state
  that changes on display moves.
- `check-starter-config.sh`: **must** add `"titlebar"` to the key list in the same PR, or exit 1.
- `check-preferences-apply.sh`: unaffected unless a Settings control is added (then add a seed case
  `titlebar` derives from `AppConfig.defaults()`).
- `check-palette-covers-menu.sh`: only if a View-menu toggle is added (then add a palette command).
- `check-file-size.sh`, `check-afk-loc.sh`: new rows / counts.

### Stays daily-drive / manual (checklist in `.afk/verification/`)
Visual look under Liquid Glass (26/27) vs 14/15 (no 14/15 machine measured); drag feel from
sidebar band and empty strip; double-click zoom/minimise honouring System Settings; full screen
enter/exit (both modes) and Stage Manager; merged windows / dragging a Space out; theme tints in
the band (`afk-light`); `NSScrollPocket` in the sidebar on 27; VoiceOver window title with the
title hidden; ⌘R toggling modes on a live window.

---

## 5. Risks + ordered PRs

### Top risks
1. **Window dragging regresses** in `compact`: band over the terminal does text selection, not
   drag (measured hit-test → `GoblinPortalTerminalView`). Mitigation: sidebar band + strip empty
   area drag; single doc with sidebar visible leaves only the 250pt sidebar band. Ghostty's
   hidden style accepts "not draggable" outright.
2. **AppKit private/behavioural drift across macOS versions**: band height (28 → 32pt), tab-bar
   accessory geometry, `NSScrollPocket` on 27, title view re-revealing on `title` set (Ghostty
   15+ note). Only 27.0.1 measured. Mitigation: everything derived from `contentLayoutRect` +
   button frames at runtime, no constants; gate runs on every OS the operator uses.
3. **Stale layout on window-state transitions** (tab bar appears, banner, FS exit) — measured
   +64pt overlap without KVO. Mitigation: KVO + FS-exit reapply + C4/C5 + mutant 2.
Others: FSC changes `frameRect` math (first-window/poison repair, C8); `Config.swift` and
`SpaceWindowController.swift` are at 335/345 — any extra line there must be paid for by moving
code out; title hidden loses project name with 1 Space.

### Ordered PRs
- **PR1 — pure layout fix + gate, zero visible change at default.** DocumentArea lays out inside
  `contentLayoutRect` (KVO), FileTree honours safe area, `defaultFrame`/poison repair use the
  FSC-stripped mask, correct the three stale comments + AFK.md bullet. New gate with C0, C1, C4,
  C5, C7, C8 under harness-forced FSC; mutants 1, 2, 4, 5. Default never has FSC ⇒ inset 0
  (measured: fix under FSC gives 39 rows == control).
- **PR2 — `"titlebar": "compact"`.** `Config+Titlebar.swift`, parse/warn, starter + drift-guard
  list, `SpaceWindowController+Titlebar.swift` (style + FS-exit reapply + reload), controls-aware
  inset. Gate C2, C3, C6, C9, C10; mutants 3, 6.
- **PR3 — band ergonomics.** Strip empty-area drag + double-click; strip `leadingInset` so the
  strip uses the band when the sidebar is collapsed (+30pt at 2+ docs, UNVERIFIED).
- **PR4 (optional)** — Settings control / View-menu toggle (+ palette command, preferences seed case).
- **Not planned**: native Space tab bar inside the title row (Option D, private views) and
  Ghostty-style hidden traffic lights (Option C, breaks/undermines Spaces).

### Not verified
macOS 14/15 behaviour; full screen in either mode; real mouse drag/double-click; pixels
(glass/tint/scroll pocket); `check-cell-snap` interaction; strip-in-band with collapsed sidebar;
row gain at window sizes other than 1100x680 (expect +1 or +2).

Artifacts (ephemeral scratch, not in the repo): harness `/tmp/gp-tb/h1/main.swift`; clone with prototype inset/KVO
`/tmp/gp-tb/clone/app/Sources/GoblinPortal/DocumentAreaViewController.swift` (env-switched
`GP_TB_FIX=none|safe|clr|aware`, `GP_TB_KVO=1`); Ghostty sources `/tmp/gp-tb/*.swift`.

---

## 6. PR1 as landed (2026-10-12) — deviations from §3/§4

- **No new `+TitlebarInset` file for PR1.** The inset is the plain `contentLayoutRect` form
  (`DocumentAreaViewController+SafeArea.swift`, `layoutTopInset` + `observeContentLayoutRect()`);
  the controls-aware rule (§1c) is PR2's. `viewDidLayout` lays out in `bounds` minus
  `layoutTopInset`; the KVO is installed from `viewDidAppear`. Hook point for PR2: replace the
  body of `layoutTopInset` with the controls-aware policy — the KVO and the layout already
  consume it.
- **Sidebar**: `FileTreeViewController.viewDidLayout` adds `view.safeAreaInsets.top` to the stack's
  `edgeInsets.top` (no constraint to `safeAreaLayoutGuide`, so the SCM switcher / follow-status
  rows inserted into the same stack ride along). Measured under forced FSC: filter field top
  666 vs sidebar safe top 670 vs traffic lights minY 689.
- **Frame math deferred to PR2.** `defaultFrame` / `repairPoisonedSavedFrame` still pass
  `window.styleMask`; that is a no-op while FSC is off and the gate does not need it. PR2 must
  switch both to `styleMask.subtracting(.fullSizeContentView)` and add C8 + mutant 5 with it.
- **Gate shipped**: `check-titlebar-layout.sh` + `-harness.swift`, cases C0, C1, C4, C5, C7
  (+ ISO). Falsify mutants m1 (drop inset → C1, 28pt), m2 (drop KVO install → C4, 32pt — the
  layout rect returns to the stale full-height value, not +64, because the harness window was
  laid out once with the inset before the tab bar appeared), m3 (drop sidebar safe-area term →
  C7, field top 708). C8 deferred with the frame math. Scope §4's mutants 1, 2, 4 = m1, m2, m3.
- Measured on macOS 27.0.1 only, as before.

---

## 7. PR2 as landed (2026-10-12) — `"titlebar": "compact"`, deviations from §3/§4

- **Files.** Enum + fail-soft parse + the pure controls-aware rule in `TitlebarStyle.swift`
  (Foundation-only; §3 called it `Config+Titlebar.swift`). Window application in
  `SpaceWindowController+Titlebar.swift` (style, reload, `windowDidExitFullScreen` reapply,
  `NSWindow` helpers `allowsContentInTitleRow` / `titleRowHeight` / `titleRowControlsMaxX`).
  The rule replaced the body of `layoutTopInset` as §6 planned; no `+TitlebarInset` file.
- **Rule** (§1c): band given back only when `full <= titleRow` (nothing below the title row)
  AND `viewMinX >= controlsMaxX + 8`. Gated by `allowsContentInTitleRow` (FSC + transparent +
  hidden title), so PR1's harness-forced FSC (C1) still gets the full inset.
- **Reload**: `AppDelegate.reloadConfig` → `controller.applyTitlebarStyle()` after
  `space.apply(config:)`; the frame is pinned across the mask toggle (C10 measured no move).
  In full screen the style is not touched; FS exit re-applies it. FS itself UNMEASURED.
- **Frame math**: `frameMathMask` = `styleMask − .fullSizeContentView` in `defaultFrame` and
  `repairPoisonedSavedFrame` (C8: compact first window 1100x712, poisoned 500x532 repaired).
- **Gate**: cases C2, C3 (+ re-expand), C6, C4c, C5c, C8, C10, C9 (headless), W (grep) and a
  measurement table M, in `check-titlebar-compact-cases.swift` + the shell. Mutants m4 (raw
  mask → C8), m5 (ignore controls → C3), m6 (drop `full <= titleRow` → C4c), m7 (unknown →
  compact → C9); m1-m3 still caught. Scope §4 mutants 3/5/6 = m5/m4/m5+m6.
- **Measured rows (macOS 27.0.1, 1100x712 frame)**: standard 39x91 / 39x119 (1 doc, sidebar
  visible / collapsed), 37x91 / 37x119 (2 docs); compact 41x91 / 39x119, 39x91 / 37x119.
  With 2 docs the strip moved into the band (y682-712, minX 183.5 — the sidebar measured
  narrower in that window; controls maxX 106).
- **Not done (PR3/PR4)**: drag/double-click on the band over the terminal/strip; strip
  `leadingInset` for the collapsed sidebar; Settings control / menu toggle. Unmeasured:
  macOS 14/15, full screen, pixels/glass look, `check-cell-snap` (exit 2: no 2x+1x displays).
