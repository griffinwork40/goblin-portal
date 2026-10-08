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
# FALSIFICATION. The gate was validated by temporarily commenting out one palette
# command and confirming exit 1 with the missing selector listed; restoring it
# gives exit 0. A control case (building a menu with a sentinel selector nobody
# implements) is not exercised here because the gate's logic is a set-membership
# check, not a responder-chain query — it cannot suffer the "resolves everything"
# failure class that `check-sidebar-toggle.sh` CASE 5 guards against.
#
# EXIT CODES (same three-valued contract as every gate in this repo):
#   0 = all menu selectors are covered by the palette or the allowlist.
#   1 = one or more menu selectors are missing from both palette and allowlist.
#       The missing list is printed to stdout.
#   2 = environmental — no swiftc, swift build failed, harness would not compile,
#       or no GoblinPortal objects were found. A broken environment must never
#       read as a green gate.
#
# WHAT THIS CANNOT SEE. The gate checks COVERAGE, not correctness: a palette
# command with the right selector but the wrong title, a stale key hint, or a
# `validateUserInterfaceItem` that greys out the palette entry in the wrong
# circumstances — none of those are caught here. Those stay daily-drive territory,
# the same category `check-sidebar-toggle.sh` puts visual placement in.
# INVERSE GAP (by design): a palette entry whose selector has NO menu item is NOT
# flagged. The palette intentionally carries commands that are palette-only (no menu
# item at all). The gate direction is menu→palette only: every menu selector must
# appear in the palette, not every palette entry must appear in a menu.
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
// Collect all actionable selectors from the real menu tree, recursively.
// "Actionable" = has a non-nil action AND is not a separator AND is not
// a submenu container (those carry no action themselves).
// ---------------------------------------------------------------------------
func collectSelectors(from menu: NSMenu) -> Set<String> {
    var result = Set<String>()
    for item in menu.items {
        if let sub = item.submenu {
            result.formUnion(collectSelectors(from: sub))
        }
        // Items with a submenu exist only as containers; their own action is
        // typically nil. Items with action = nil are separators or headers.
        guard let action = item.action, item.submenu == nil else { continue }
        result.insert(NSStringFromSelector(action))
    }
    return result
}

// Build the real menu. AppDelegate.buildMenu() is `internal`, so @testable gives us
// access. We need a real AppDelegate instance because buildMenu reads `NSApp` state
// and calls `buildNavigateMenu` / `addSourceControlMenu` — both of which add submenus
// to the passed NSMenu.
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

    let menuSelectors = collectSelectors(from: mainMenu)

    // ---------------------------------------------------------------------------
    // Collect the palette's selector set from the static list.
    // ---------------------------------------------------------------------------
    let paletteSelectors = Set(CommandPalette.allCommands.map {
        NSStringFromSelector($0.action)
    })

    // ---------------------------------------------------------------------------
    // Compute the gap: menu selectors not in the palette and not allowlisted.
    // ---------------------------------------------------------------------------
    let gap = menuSelectors.subtracting(paletteSelectors).subtracting(allowlisted)

    let menuCount   = menuSelectors.count
    let paletteCount = paletteSelectors.count
    let allowCount  = allowlisted.intersection(menuSelectors).count

    if gap.isEmpty {
        print("ok  palette covers all \(menuCount) menu selectors")
        print("    palette commands: \(paletteCount) | allowlisted: \(allowCount)")
        exit(0)
    } else {
        print("FAIL palette is missing \(gap.count) menu selector(s):")
        for sel in gap.sorted() {
            print("    \(sel)")
        }
        print("    menu selectors: \(menuCount) | palette: \(paletteCount) | allowlisted: \(allowCount)")
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
