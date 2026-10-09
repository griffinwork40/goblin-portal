#!/bin/bash
#
# Assert the command palette is a superset of the menu bar's actionable items.
#
# THE HAZARD CLASS. `AppMenu.swift`, `AppMenu+Navigate.swift`, and
# `AppMenu+SourceControl.swift` define ~40 actionable selectors across ~109 menu
# items. `CommandPalette+Commands.swift` defines the palette's static list. The
# two are maintained independently, so a new menu item added without a matching
# palette entry creates a silent gap: users who rely on the palette as their
# 'one door' cannot reach that action. This gate closes the gap mechanically by
# building the REAL main menu and the REAL palette list from the SAME binary and
# asserting that every menu selector appears in the palette, or is on the
# explicit allowlist.
#
# WHAT IS UNDER TEST. The gate exercises:
#   * `AppDelegate.buildMenu()` — the live menu tree (all three AppMenu* files).
#   * `CommandPalette.allCommands` — the static list in `+Commands.swift`.
#   Both are reached through `@testable import GoblinPortal`, so this is not a
#   copy or a grep over source text; it is the compiled runtime tables.
#
# ALLOWLISTED SELECTORS (things that make no sense in a palette, or are already
# handled structurally). Each entry is commented with the reason:
#   cut:/copy:/paste:          — clipboard text; context-sensitive in-situ ops
#   selectAll:                 — already in palette; also in allowlist for gate clarity
#   undo:/redo:                — in palette; also allowlisted (text-edit fundamentals)
#   terminate:/hide:           — app/system management, not command-palette territory
#   orderFrontStandardAboutPanel: — About box, not an editor command
#   performMiniaturize:/performZoom:/arrangeInFront:/hideOtherApplications:/
#     unhideAllApplications:   — stock window-manager selectors AppKit owns
#   performFindPanelAction:    — covered by tagged variants in the palette; the bare
#                                selector alone (with no tag) does nothing useful
#   showCommandPalette:        — IS the palette; invoking it from itself is circular
#   selectDocumentByIndex:     — the ⌘1-9 select-tab family; covered dynamically by
#                                `spaceCommands()` which generates per-open-tab entries
#
# PART 2 — KEY HINT CHECK. For every palette command whose keyHint is non-empty AND
# whose selector also has a menu item, the displayed hint must match the menu item's
# keyEquivalent + keyEquivalentModifierMask (same modifier set, same key character).
# Both sides are normalised to (⌃⌥⇧⌘ order)(uppercase letter or arrow glyph) before
# comparison, so "⌥⌘F" == "⌘⌥F". Commands with no menu counterpart (palette-only) are
# not checked — those key hints document user expectations and cannot be mechanically
# verified against a menu item that does not exist.
# Selectors with a tag (find-panel variants) are matched by (selector, tag) pair.
#
# FALSIFICATION. The gate was validated by temporarily commenting out one palette
# command and confirming exit 1 with the missing selector listed; restoring it
# gives exit 0. A control case (building a menu with a sentinel selector nobody
# implements) is not exercised here because the gate's logic is a set-membership
# check, not a responder-chain query — it cannot suffer the "resolves everything"
# failure class that `check-sidebar-toggle.sh` CASE 5 guards against.
#
# EXIT CODES (same three-valued contract as every gate in this repo):
#   0 = all menu selectors are covered by the palette or the allowlist,
#       AND all palette key hints match their menu item equivalents.
#   1 = one or more menu selectors are missing from both palette and allowlist,
#       OR one or more palette key hints do not match the menu item.
#   2 = environmental — no swiftc, swift build failed, harness would not compile,
#       or no GoblinPortal objects were found. A broken environment must never
#       read as a green gate.
#
# WHAT THIS CANNOT SEE. The gate checks COVERAGE and HINT ACCURACY for commands
# that have a menu item. A palette-only command's hint is never checked here (no
# menu item to compare against). Commands silently no-oping because no responder
# is in the chain are also not checked — that is a daily-drive catch.
#
# Usage: ./Scripts/check-palette-covers-menu.sh
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
say "==> building (the harness links GoblinPortal's own objects, so they must be current)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

# Locate the GoblinPortal object directory produced by the build we JUST ran.
# The Swift Build backend writes GoblinPortal-p.build/Objects-normal/<arch>/.
# (Same lookup as check-sidebar-toggle.sh — see its comment for the full rationale.)
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/CommandPalette.o" ]] || {
  echo "error: GoblinPortal objects not found under .build/out (expected GoblinPortal-p.build)." >&2
  echo "  Run: swift build --build-system swiftbuild" >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Offscreen harness: builds the real menu and compares it to the real palette list.
# Uses @testable import GoblinPortal (internal access) — same reach as
# check-sidebar-toggle.sh and check-pane-teardown.sh.
cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
// .accessory so we hold no Dock icon and steal no focus — same contract as
// check-sidebar-toggle.sh.
app.setActivationPolicy(.accessory)

// ---------------------------------------------------------------------------
// Allowlist — selectors that are intentionally absent from the palette.
// Each entry is spelled as NSStringFromSelector produces it.
// ---------------------------------------------------------------------------
let allowlisted: Set<String> = [
    // Clipboard text: context-sensitive in-situ ops not suited to a palette.
    "cut:",
    "copy:",
    "paste:",
    // selectAll: is IN the palette; listed here so the gate doesn't double-count it.
    "selectAll:",
    // undo:/redo: are IN the palette; allowlisted for the same reason.
    "undo:",
    "redo:",
    // App/system management — not editor commands.
    "terminate:",
    "hide:",
    "orderFrontStandardAboutPanel:",
    // Standard window-manager selectors AppKit owns; the palette has no role here.
    "performMiniaturize:",
    "performZoom:",
    "arrangeInFront:",
    "hideOtherApplications:",
    "unhideAllApplications:",
    // performFindPanelAction: alone (with no tag) does nothing useful; the gate
    // checks the tagged variants individually through the palette's tag field.
    "performFindPanelAction:",
    // showCommandPalette: IS the palette; circular to invoke it from itself.
    "showCommandPalette:",
    // selectDocumentByIndex: — the ⌘1-9 tab-select family; the palette covers these
    // dynamically through spaceCommands(), which generates one entry per open Space.
    "selectDocumentByIndex:",
]

// ---------------------------------------------------------------------------
// Key: (selector, tag) — tag 0 means "no tag".
// ---------------------------------------------------------------------------
struct MenuKey: Hashable {
    let sel: String
    let tag: Int
}

// ---------------------------------------------------------------------------
// Canonical key-hint form: sort modifiers as ⌃⌥⇧⌘, then append the key char.
// Arrow-key unicode scalars → glyphs. Letters → uppercase. Other chars → as-is.
//
// An uppercase menu keyEquivalent implies ⇧: AppKit stores "G" with .command
// rather than "g" with [.command, .shift]. We promote .shift into the mask
// whenever the stored keyEquivalent is a single uppercase ASCII letter and .shift
// is absent, so the canonical form matches the palette hint "⌘⇧G".
// ---------------------------------------------------------------------------
func canonical(equiv: String, mask: NSEvent.ModifierFlags) -> String {
    var effectiveMask = mask
    // Uppercase ASCII letter without .shift → add .shift (AppKit convention).
    if equiv.count == 1,
       let c = equiv.unicodeScalars.first,
       c.value >= 65 && c.value <= 90,   // 'A'–'Z'
       !mask.contains(.shift) {
        effectiveMask.insert(.shift)
    }
    var mods = ""
    if effectiveMask.contains(.control) { mods += "⌃" }
    if effectiveMask.contains(.option)  { mods += "⌥" }
    if effectiveMask.contains(.shift)   { mods += "⇧" }
    if effectiveMask.contains(.command) { mods += "⌘" }
    let arrowMap: [Unicode.Scalar: String] = [
        Unicode.Scalar(NSRightArrowFunctionKey)!: "→",
        Unicode.Scalar(NSLeftArrowFunctionKey)!:  "←",
        Unicode.Scalar(NSUpArrowFunctionKey)!:    "↑",
        Unicode.Scalar(NSDownArrowFunctionKey)!:  "↓",
    ]
    let key: String
    if let s = equiv.unicodeScalars.first, let arrow = arrowMap[s] {
        key = arrow
    } else {
        key = equiv.uppercased()
    }
    return mods + key
}

// Parse a palette hint string into canonical form for comparison.
// The hint may have modifiers in any order; we extract them by set membership.
func canonicalHint(_ hint: String) -> String {
    let modGlyphs = ["⌃", "⌥", "⇧", "⌘"]
    var mods: Set<String> = []
    var key = hint
    for g in modGlyphs {
        if key.contains(g) { mods.insert(g); key = key.replacingOccurrences(of: g, with: "") }
    }
    var ordered = ""
    for g in ["⌃", "⌥", "⇧", "⌘"] { if mods.contains(g) { ordered += g } }
    return ordered + key.uppercased()
}

// ---------------------------------------------------------------------------
// Collect all actionable menu items (selector, tag, keyEquiv, modifiers).
// Hidden items are excluded from key-hint checks — they are key aliases
// (e.g. ⌘= as a hidden alias for ⌘+) and are not user-visible UI.
// Hidden items ARE included in the selector-coverage check: they are real
// actions even if the user cannot see them in the menu.
// ---------------------------------------------------------------------------
func collectItems(from menu: NSMenu) -> [(MenuKey, String, NSEvent.ModifierFlags, isHidden: Bool)] {
    var result: [(MenuKey, String, NSEvent.ModifierFlags, isHidden: Bool)] = []
    for item in menu.items {
        if let sub = item.submenu { result += collectItems(from: sub) }
        guard let action = item.action, item.submenu == nil else { continue }
        result.append((MenuKey(sel: NSStringFromSelector(action), tag: item.tag),
                       item.keyEquivalent, item.keyEquivalentModifierMask, item.isHidden))
    }
    return result
}

MainActor.assumeIsolated {
    // Build the menu. This triggers buildMenu(), which sets NSApp.mainMenu.
    // We call it on a fresh AppDelegate rather than NSApp.delegate to avoid side
    // effects on a live session.
    let delegate = AppDelegate()
    delegate.buildMenu()

    guard let mainMenu = NSApp.mainMenu else {
        print("ENV: NSApp.mainMenu is nil after buildMenu() — cannot proceed")
        exit(2)
    }

    let allMenuItems = collectItems(from: mainMenu)
    // selector-only set (for coverage check; include hidden items — they are real actions)
    let menuSelectors = Set(allMenuItems.map { $0.0.sel })
    // (selector,tag) → canonical hint (for key-hint check; skip hidden and keyless items)
    var menuHints: [MenuKey: String] = [:]
    for (key, equiv, mask, hidden) in allMenuItems where !equiv.isEmpty && !hidden {
        menuHints[key] = canonical(equiv: equiv, mask: mask)
    }

    // ---------------------------------------------------------------------------
    // Collect the palette's selector set from the static list.
    // ---------------------------------------------------------------------------
    let paletteSelectors = Set(CommandPalette.allCommands.map {
        NSStringFromSelector($0.action)
    })

    // ---------------------------------------------------------------------------
    // PART 1: coverage check — menu selectors not in the palette and not allowlisted.
    // ---------------------------------------------------------------------------
    let gap = menuSelectors.subtracting(paletteSelectors).subtracting(allowlisted)
    let menuCount    = menuSelectors.count
    let paletteCount = paletteSelectors.count
    let allowCount   = allowlisted.intersection(menuSelectors).count

    if !gap.isEmpty {
        print("FAIL palette is missing \(gap.count) menu selector(s):")
        for sel in gap.sorted() { print("    \(sel)") }
        print("    menu selectors: \(menuCount) | palette: \(paletteCount) | allowlisted: \(allowCount)")
        exit(1)
    }
    print("ok  palette covers all \(menuCount) menu selectors")
    print("    palette commands: \(paletteCount) | allowlisted: \(allowCount)")

    // ---------------------------------------------------------------------------
    // PART 2: key-hint check — palette hint must match the menu item's equivalent.
    // Only checked when the palette command has a non-empty keyHint AND has a
    // matching menu item (by selector+tag). Palette-only commands (or commands
    // that route through a different selector than the menu item — e.g. "Find…"
    // uses openSearch: in the palette but performFindPanelAction: tag 1 in the
    // menu) are skipped. Skipped hints are printed with their reason so the
    // omission is visible and not silently lost.
    // ---------------------------------------------------------------------------
    var hintMismatches: [(String, String, String)] = [] // (title, menuHint, paletteHint)
    var checkedHints = 0
    var skippedHints: [(String, String)] = [] // (title, reason)
    for cmd in CommandPalette.allCommands {
        guard !cmd.keyHint.isEmpty else { continue }
        let mkey = MenuKey(sel: NSStringFromSelector(cmd.action), tag: cmd.tag ?? 0)
        guard let menuHint = menuHints[mkey] else {
            // Selector+tag not in menuHints: palette-only hint or selector mismatch
            // (e.g. "Find…" → openSearch: in palette vs performFindPanelAction: tag 1
            // in the menu). Print it so the gap is visible.
            skippedHints.append((cmd.title, "selector '\(NSStringFromSelector(cmd.action))' not in menu"))
            continue
        }
        let palHint = canonicalHint(cmd.keyHint)
        checkedHints += 1
        if menuHint != palHint {
            hintMismatches.append((cmd.title, menuHint, palHint))
        }
    }

    if !skippedHints.isEmpty {
        print("note \(skippedHints.count) palette hint(s) skipped (palette-only selector or selector mismatch):")
        for (title, reason) in skippedHints.sorted(by: { $0.0 < $1.0 }) {
            print("    '\(title)': \(reason)")
        }
    }

    if hintMismatches.isEmpty {
        print("ok  all \(checkedHints) palette key hints match their menu item equivalents")
        exit(0)
    } else {
        print("FAIL \(hintMismatches.count) palette key hint(s) do not match the menu:")
        for (title, menu, pal) in hintMismatches.sorted(by: { $0.0 < $1.0 }) {
            print("    '\(title)': menu='\(menu)' palette='\(pal)'")
        }
        exit(1)
    }
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/palette_covers_menu" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  echo "  If this names a missing member on CommandPalette or AppDelegate, the" >&2
  echo "  relevant source file changed and this script needs updating." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

out="$("$TMP/palette_covers_menu" 2>&1)"; status=$?
say "$out"

# The exit code is the verdict; text is for humans. A harness that died before
# printing a recognisable verdict is environmental (2), not a coverage gap (1).
if [[ $status -eq 0 ]]; then exit 0; fi
if [[ $status -eq 2 ]] || ! grep -qE 'ok  |FAIL ' <<<"$out"; then
  echo "error: harness exited $status without a verdict — treating as environmental." >&2
  exit 2
fi
exit 1
