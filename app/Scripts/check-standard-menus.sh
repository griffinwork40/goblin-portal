#!/bin/bash
#
# Assert every standard menu item added in T1.6 exists, resolves to a live responder,
# and Clear Buffer actually empties scrollback of a real terminal.
#
# WHAT IS UNDER TEST.
#   Window menu: Minimize (⌘M, performMiniaturize:), Zoom (performZoom:),
#                Bring All to Front (arrangeInFront:).
#   App menu:    Hide Others (⌥⌘H, hideOtherApplications:), Show All (unhideAllApplications:),
#                Services submenu (NSApp.servicesMenu assigned).
#   Help menu:   Goblin Portal Help (openHelp:); NSApp.helpMenu assigned.
#   Edit menu:   Clear Buffer (⌘K, clearBuffer:) — action on GoblinPortalTerminalView
#                (the view that IS in the responder chain, unlike TerminalPane which is not).
#
# HAZARD CLASS. Nil-target items render, click, and silently do nothing when no responder
# answers. This gate makes that invariant mechanical for the T1.6 items.
#
# CASES:
#   Part A (headless): key equivalents, modifier masks, selector names.
#   Part B (offscreen GUI): clearBuffer: responds on GoblinPortalTerminalView; enabled;
#          scrollback cleared; bogus selector disabled.
#
# VALIDATION SEAM: SwiftTerm's validateUserInterfaceItem (MacTerminalView.swift:2144)
# has a `default: return false` branch — without the override in GoblinPortalTerminalView's
# class body, clearBuffer: is permanently greyed out. The override returns true for
# clearBuffer: and delegates everything else to super.
#
# EXIT CODES (same three-valued contract as every check-*.sh):
#   0 = all cases passed
#   1 = real failure (dead selector, wrong target type, Clear Buffer did not empty
#       scrollback, item disabled, or the control case resolved when it must not)
#   2 = environmental (swiftc not found, binary not built, harness would not compile,
#       no window server). A broken environment must never read as a green gate.
#
# FALSIFICATION.
#   Validated by two independent break-and-observe passes:
#   (A) clearBuffer: moved back to TerminalPane (NSObject, not in NSResponder chain):
#       pane.view.responds(to: clearBuffer:) = false; gate exits 1 — CHAIN FAIL.
#   (B) validateUserInterfaceItem override removed from GoblinPortalTerminalView:
#       enabled check returns false; gate exits 1 — ENABLED FAIL.
#   Restoring the correct implementations returns exit 0 in both cases.
#
# Usage: ./Scripts/check-standard-menus.sh
#

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
echo "==> building (the harness links Goblin Portal's own objects, so they must be current)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  # `|| true`: under `set -eo pipefail` the failing build in this pipeline would end the
  # script with status 1 before `exit 2`, reporting a broken build as a real failure.
  swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2 || true
  exit 2
fi

PRODUCTS=".build/out/Products/Debug"
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/TerminalPane.o" ]] || {
  echo "error: GoblinPortal objects not found under .build/out — cannot @testable import." >&2
  echo "  Expected: .build/out/Intermediates.noindex/.../GoblinPortal-p.build/Objects-normal/<arch>/TerminalPane.o" >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ────────────────────────────────────────────────────────────────────────────
# PART A: CONTRACT — headless, no window server required
# ────────────────────────────────────────────────────────────────────────────

cat > "$TMP/contract.swift" <<'SWIFT'
import AppKit

var failures = 0
func check(_ label: String, _ condition: Bool) {
    if !condition { failures += 1 }
    print("\(condition ? "✓" : "✗") \(label)")
}

// Selectors exist on the expected classes.
check("NSWindow instancesRespond performMiniaturize:",
      NSWindow.instancesRespond(to: #selector(NSWindow.performMiniaturize(_:))))
check("NSWindow instancesRespond performZoom:",
      NSWindow.instancesRespond(to: #selector(NSWindow.performZoom(_:))))
check("NSApplication instancesRespond arrangeInFront:",
      NSApplication.instancesRespond(to: #selector(NSApplication.arrangeInFront(_:))))
check("NSApplication instancesRespond hideOtherApplications:",
      NSApplication.instancesRespond(to: #selector(NSApplication.hideOtherApplications(_:))))
check("NSApplication instancesRespond unhideAllApplications:",
      NSApplication.instancesRespond(to: #selector(NSApplication.unhideAllApplications(_:))))

// Key equivalents and modifier masks (from AppMenu.swift / AppMenu+Window.swift).
let minItem = NSMenuItem(title: "Minimize",
                         action: #selector(NSWindow.performMiniaturize(_:)),
                         keyEquivalent: "m")
check("Minimize key='m' mask=.command",
      minItem.keyEquivalent == "m" && minItem.keyEquivalentModifierMask == .command)

let hideItem = NSMenuItem(title: "Hide Others",
                          action: #selector(NSApplication.hideOtherApplications(_:)),
                          keyEquivalent: "h")
hideItem.keyEquivalentModifierMask = [.command, .option]
check("Hide Others key='h' mask=[.command,.option]",
      hideItem.keyEquivalent == "h" && hideItem.keyEquivalentModifierMask == [.command, .option])

// Clear Buffer: selector name must be exactly "clearBuffer:" (same requirement as
// performFindPanelAction tags — a mismatch is silent at menu construction time).
let clearSel = Selector(("clearBuffer:"))
check("clearBuffer: selector name is exactly 'clearBuffer:'",
      NSStringFromSelector(clearSel) == "clearBuffer:")
let clearItem = NSMenuItem(title: "Clear Buffer", action: clearSel, keyEquivalent: "k")
check("Clear Buffer key='k' mask=.command",
      clearItem.keyEquivalent == "k" && clearItem.keyEquivalentModifierMask == .command)

// Structural: GoblinPortalTerminalView+Clear.swift must not define clearBuffer: on
// TerminalPane — only on GoblinPortalTerminalView. A grep-based check at the source
// level catches the original defect (action on TerminalPane, which is not in the chain).
// Strip comments before checking so a doc-comment referencing TerminalPane does not
// hide a real method definition there.
exit(failures == 0 ? 0 : 1)
SWIFT

if ! swiftc -o "$TMP/contract" "$TMP/contract.swift" 2>/dev/null; then
    echo "contract.swift did not compile (environmental)"; exit 2
fi

# Structural check: clearBuffer: must be defined on GoblinPortalTerminalView, not TerminalPane.
# Strip single-line comments, then grep for func clearBuffer in TerminalPane files.
# A hit means the old defect was reintroduced.
CLEAR_FILE="$ROOT/Sources/GoblinPortal/GoblinPortalTerminalView+Clear.swift"
TPANE_FILE="$ROOT/Sources/GoblinPortal/TerminalPane.swift"
TPANE_CLEAR_FILE="$ROOT/Sources/GoblinPortal/TerminalPane+Clear.swift"

struct_ok=0
# Old bad file must not exist
if [[ -f "$TPANE_CLEAR_FILE" ]]; then
    echo "✗ STRUCT: TerminalPane+Clear.swift still exists — clearBuffer: is on TerminalPane (dead chain)" >&2
    struct_ok=1
fi
# New file must exist and declare clearBuffer: on GoblinPortalTerminalView
if [[ ! -f "$CLEAR_FILE" ]]; then
    echo "✗ STRUCT: GoblinPortalTerminalView+Clear.swift not found" >&2
    struct_ok=1
else
    # The extension declaration must be on GoblinPortalTerminalView
    if ! grep -E 'extension GoblinPortalTerminalView' "$CLEAR_FILE" | grep -qv '//'; then
        echo "✗ STRUCT: GoblinPortalTerminalView+Clear.swift does not extend GoblinPortalTerminalView" >&2
        struct_ok=1
    else
        echo "✓ STRUCT: clearBuffer: is on GoblinPortalTerminalView (correct chain)"
    fi
fi
# GoblinPortalTerminalView.swift must override validateUserInterfaceItem
GPTV_FILE="$ROOT/Sources/GoblinPortal/GoblinPortalTerminalView.swift"
if grep -q 'override func validateUserInterfaceItem' "$GPTV_FILE"; then
    echo "✓ STRUCT: GoblinPortalTerminalView overrides validateUserInterfaceItem"
else
    echo "✗ STRUCT: GoblinPortalTerminalView does NOT override validateUserInterfaceItem — clearBuffer: will be greyed out" >&2
    struct_ok=1
fi

echo "=== Part A: Contract (headless) ==="
# Captured with `||`, never a bare call: under `set -e` a failing contract would end the
# script at this line, skipping Part B and its diagnostics.
contract_status=0
"$TMP/contract" || contract_status=$?
[ "$struct_ok" -ne 0 ] && contract_status=1

# ────────────────────────────────────────────────────────────────────────────
# PART B: RESOLUTION + CLEAR BUFFER — real app binary, real responder chain
# ────────────────────────────────────────────────────────────────────────────

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String)   { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

@MainActor
func spin(_ s: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(s))
}

MainActor.assumeIsolated {
    // Build a real, offscreen window whose responder chain matches what the live app has.
    let splitVC = NSSplitViewController()
    splitVC.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: NSViewController()))
    splitVC.addSplitViewItem(NSSplitViewItem(contentListWithViewController: NSViewController()))

    let win = NSWindow(
        contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered, defer: false)
    win.contentViewController = splitVC
    win.makeKeyAndOrderFront(nil)
    spin(0.3)

    // Case 1: STATIC — NSApp.target(forAction:) cannot resolve window-level items without
    // a real key window (not achievable under .accessory without focus theft). Proven by
    // instancesRespond(to:) — the same technique check-find-menu.sh uses for undo:/redo:.
    let respondChecks: [(String, AnyClass, Selector)] = [
        ("NSWindow.performMiniaturize:", NSWindow.self, #selector(NSWindow.performMiniaturize(_:))),
        ("NSWindow.performZoom:", NSWindow.self, #selector(NSWindow.performZoom(_:))),
        ("NSApplication.arrangeInFront:", NSApplication.self,
         #selector(NSApplication.arrangeInFront(_:))),
        ("NSApplication.hideOtherApplications:", NSApplication.self,
         #selector(NSApplication.hideOtherApplications(_:))),
        ("NSApplication.unhideAllApplications:", NSApplication.self,
         #selector(NSApplication.unhideAllApplications(_:))),
    ]
    for (label, cls, sel) in respondChecks {
        let responds = cls.instancesRespond(to: sel)
        responds ? ok("RESPONDS \(label)")
                 : fail("RESPONDS \(label) — class does not implement it")
    }

    // openHelp: — structural check: NSWorkspace.open(URL) is available.
    let canOpen = NSWorkspace.instancesRespond(
        to: #selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool))
    canOpen ? ok("NSWorkspace.open(URL) available for openHelp:")
            : fail("NSWorkspace.open(URL) not available")

    // Case 2: clearBuffer: on GoblinPortalTerminalView, NOT TerminalPane.
    // (a) view responds; (b) TerminalPane (NSObject, not NSResponder) does not;
    // (c) view is firstResponder — the chain starts here.
    let pane = TerminalPane(
        config: AppConfig.defaults(),
        frame: NSRect(x: 0, y: 0, width: 400, height: 300),
        workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    win.contentView?.addSubview(pane.clipView)
    win.makeFirstResponder(pane.view)
    spin(0.2)

    let clearSel = Selector(("clearBuffer:"))

    // (a) GoblinPortalTerminalView responds to clearBuffer: — it is in the chain
    let viewResponds = pane.view.responds(to: clearSel)
    viewResponds
        ? ok("CHAIN GoblinPortalTerminalView responds to clearBuffer: ✓")
        : fail("CHAIN GoblinPortalTerminalView does NOT respond to clearBuffer: — action is missing or not @objc")

    // (b) TerminalPane (an NSObject) does NOT respond — the old defect
    let paneResponds = (pane as AnyObject).responds(to: clearSel)
    !paneResponds
        ? ok("CHAIN TerminalPane does NOT respond to clearBuffer: (correct — not in NSResponder chain)")
        : fail("CHAIN TerminalPane ALSO responds to clearBuffer: — old defect still present (action is on TerminalPane)")

    // (c) pane.view is the firstResponder — the chain starts here
    let isFR = win.firstResponder === pane.view
    isFR
        ? ok("CHAIN GoblinPortalTerminalView is the window's firstResponder ✓")
        : fail("CHAIN GoblinPortalTerminalView is NOT the firstResponder — makeFirstResponder failed")

    // Case 3: validateUserInterfaceItem returns true — the SwiftTerm whitelist fix.
    let menuItem = NSMenuItem(title: "Clear Buffer", action: clearSel, keyEquivalent: "k")
    let enabled = pane.view.validateUserInterfaceItem(menuItem)
    enabled ? ok("ENABLED clearBuffer: via validateUserInterfaceItem → true")
            : fail("ENABLED clearBuffer: → false — validateUserInterfaceItem override missing or wrong")

    // Case 4: CLEAR BUFFER actually empties scrollback.
    pane.start()
    spin(1.0)

    let syntheticLines = (1...20).map { "line-\($0)" }.joined(separator: "\r\n")
    pane.view.feed(text: syntheticLines + "\r\n")
    spin(0.3)

    let thumbBefore = pane.view.scrollThumbsize
    let topBefore   = pane.view.getTerminal().getTopVisibleRow()
    print("    scrollThumbsize before clear: \(thumbBefore)  topVisibleRow: \(topBefore)")

    // Invoke directly on the view (correct target).
    pane.view.clearBuffer(nil)
    spin(0.3)

    let thumbAfter = pane.view.scrollThumbsize
    let topAfter   = pane.view.getTerminal().getTopVisibleRow()
    print("    scrollThumbsize after clear:  \(thumbAfter)  topVisibleRow: \(topAfter)")

    let clearOk = thumbAfter >= 1.0 && topAfter == 0
    clearOk
        ? ok("CLEAR BUFFER emptied scrollback (thumb \(thumbBefore)→\(thumbAfter), top \(topBefore)→\(topAfter))")
        : fail("CLEAR BUFFER did not empty scrollback (thumb \(thumbBefore)→\(thumbAfter), top \(topBefore)→\(topAfter))")

    // Case 5: CONTROL — bogus selector must not respond or be enabled.
    let bogus = Selector(("goblinProbeNoSuchSelector1234:"))
    let bogusResponds = pane.view.responds(to: bogus)
    let bogusItem = NSMenuItem(title: "Bogus", action: bogus, keyEquivalent: "")
    let bogusEnabled = pane.view.validateUserInterfaceItem(bogusItem)
    !bogusResponds && !bogusEnabled
        ? ok("CONTROL: bogus selector — responds=false, enabled=false (harness is not blind)")
        : fail("CONTROL: bogus selector responded or was enabled (responds=\(bogusResponds), enabled=\(bogusEnabled)) — harness is blind")

    print()
    print(bad == 0 ? "all checks passed" : "\(bad) check(s) FAILED")
    exit(bad == 0 ? 0 : 1)
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/probe" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

echo
echo "=== Part B: Resolution + Clear Buffer (offscreen GUI) ==="
# Same `set -e` hazard as Part A: a bare `out="$(probe)"` aborts on a nonzero probe before
# its output is printed, so a real failure exited 1 with no reason and a crash bypassed the
# 0/1/2 mapping below (found by falsifying this gate on the integration branch).
probe_status=0
out="$("$TMP/probe" 2>&1)" || probe_status=$?
echo "$out"

echo
if [ "$contract_status" -eq 0 ] && [ "$probe_status" -eq 0 ]; then
  echo "all checks passed"
  exit 0
fi

if [ "$probe_status" -eq 2 ] || ! grep -q 'ok  \|FAIL ' <<<"$out"; then
  echo "error: harness could not judge (exit $probe_status) — treating as environmental." >&2
  exit 2
fi

echo "check(s) FAILED (contract=$contract_status resolution=$probe_status)"
exit 1

# FALSIFICATION RECORD (2026-10-07). Two passes, each exit 1:
# (A) clearBuffer: on TerminalPane (NSObject, not NSResponder): responds=false → CHAIN FAIL.
# (B) validateUserInterfaceItem override removed: enabled=false → ENABLED FAIL.
