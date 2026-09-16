#!/bin/bash
#
# Is the titlebar sidebar-toggle button actually wired to something, or does it just render?
#
# WHAT IS UNDER TEST. `SidebarToggleAccessory.swift` installs one borderless NSButton on the
# leading edge of every Space window's titlebar, with `target = nil` and
# `action = #selector(NSSplitViewController.toggleSidebar(_:))` (`SidebarToggleAccessory.swift:82-83`).
# That is the same responder-chain trick the Edit menu already uses for Undo/Redo/Find — and
# AFK.md names the hazard class in plain words: "an item wired to an unanswered selector or an
# unrecognised tag renders, clicks, and silently does nothing." A titlebar button is one level
# LESS visible than a menu item: a menu at least opens and shows its whole list of items every
# time, so a dead one is a couple of clicks from being noticed. This button just sits there,
# looking identical whether the responder chain resolves or not. Nothing else in this repo
# would notice if it stopped working — that is what this gate is for.
#
# FIVE CASES, in order of "how far wrong could this be" — all five were proven against a real
# build before this script existed, in an ad hoc harness kept at
# ~/.afk/workspace/reports/umber-pr33-probe/harness1_main.swift; this script is that harness
# made permanent and folded into the check-*.sh contract:
#   1. INSTALLED — exactly one SidebarToggleAccessory really lands in
#      `window.titlebarAccessoryViewControllers`, on `.left` (rawValue 1) — the only positions
#      AppKit documents as valid are `.left`/`.right`/`.bottom` (`SidebarToggleAccessory.swift:41-46`).
#   2. SHAPE — the NSButton inside it has `target == nil`, the exact `toggleSidebar:` selector,
#      a non-empty accessibility label, a non-empty tooltip, and a non-nil image. The label and
#      tooltip are not decoration: a glyph-only control with neither is unusable by VoiceOver and
#      unreadable on hover, so this gate treats them as behaviour, per
#      `SidebarToggleAccessory.swift:84-90`.
#   3. RESOLVES — `NSApp.target(forAction:to:from:)` actually finds a responder for
#      `toggleSidebar:` starting from this exact button. This is the case that would have caught
#      a typo'd selector or a responder chain that never reaches `NSSplitViewController`.
#   4. TOGGLES — sending the button's own action twice, through `NSApp.sendAction`, flips
#      `isCollapsed` and flips it back. Not a proxy for a click: `NSApp.sendAction` is the actual
#      mechanism AppKit uses when the button is clicked, never a stand-in for it.
#   5. CONTROL, mandatory — the identical resolution call for a selector nobody implements
#      (`umberProbeNoSuchAction:`) must come back nil. Without this, cases 1-4 could be passing
#      because `NSApp.target(forAction:)` resolves everything it is ever asked about on this
#      machine, and the gate would be measuring the test rig instead of the button.
#
# WHY IT NEEDS A WINDOW SERVER. Case 3 asks the responder chain a real question and case 4 drives
# a real, animated split-view collapse — neither has a headless equivalent. Same offscreen
# accessory-window shape as `check-pane-teardown.sh` and `check-find-menu.sh`, for the same
# reason: a screen-negative frame is real enough for AppKit to answer honestly.
# `app.setActivationPolicy(.accessory)`, and NEVER `NSApp.activate(...)`: this process must not
# steal the user's focus or show a Dock icon while it opens a real, key-eligible window to probe
# it. (Measured: under `.accessory` with no `activate`, `window.isKeyWindow` reads `false` even
# after `makeKey()` — and case 3 still passes, because responder-chain resolution walks up from
# the `from:` view, not from key-window status.)
#
# EXIT CODES, the same three-valued contract as every other gate in this repo: 0 = all five
# cases passed. 1 = a REAL failure — the accessory is missing, the selector does not resolve, the
# sidebar did not actually toggle, or (this is the one that matters most) the control case
# resolved when it should not have. 2 = environmental — no swiftc, `swift build` failed, the
# harness would not compile, or the testable objects it needs to link are not there. A broken
# environment must never read as a green gate.
#
# THE VERDICT IS THE EXIT CODE, never a stdout substring. AFK.md records that
# `check-ghostty-pane.sh` once exited 0 unconditionally with its verdict travelling only as text,
# so a crash *after* printing "ALL-OK" still read as green. This script counts failures and
# exits on the count, and reclassifies a status-2/no-marker run as environmental before it ever
# reaches a plain `exit 1`/`exit 0`.
#
# LINK INPUTS. This harness never touches a `GhosttyTerminal` type — it never calls `.start()`
# on any pane — but it still links against `GhosttyTerminal.o`/`GhosttyKit.o`/`libghostty.a`
# because Goblin Portal's OWN object files (`GhosttyPane.o`, `GhosttyTerminalView.o`, pulled in by the
# `$OBJS` glob below) reference those symbols unconditionally. Measured, not assumed: dropping
# them produces `symbol(s) not found for architecture arm64` against `TerminalSurfaceOptions`,
# `TerminalSurfacePwdDelegate` and friends, so they go back in — same full object set
# `check-pane-teardown.sh` links, for a reason that has nothing to do with what this gate
# actually exercises.
#
# WHAT THIS CANNOT SEE, stated so "all green" is not misread as "fully verified": whether the
# button is visually where a user expects it (beside the traffic lights, not overlapping them),
# whether its glyph re-tints correctly across every shipped theme, how it looks merged into the
# native tab bar once a Space is dragged into a tab group, or its mirrored position and
# behaviour under a right-to-left layout. Those are daily-drive and visual-review territory —
# the same category `check-theme-contrast.sh` puts "taste" in.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

say "==> building (the harness links Goblin Portal's own objects, so they must be current)"
if ! swift build >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

# The testable variant is what exposes SpaceWindowController/SidebarToggleAccessory to
# `@testable import`. The directory carries a build-configuration hash, so glob for it rather
# than hardcoding one machine's, exactly as check-pane-teardown.sh does.
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*testable-t.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/SidebarToggleAccessory.o" ]] || {
  echo "error: no testable GoblinPortal objects under .build — cannot @testable import the real accessory." >&2
  echo "  Looked for '*testable-t.build/Objects-normal/*/SidebarToggleAccessory.o'. Try: swift build" >&2
  exit 2; }
for o in GhosttyTerminal.o GhosttyKit.o libghostty.a SwiftTerm.o MSDisplayLink.o; do
  [[ -e "$PRODUCTS/$o" ]] || { echo "error: $PRODUCTS/$o missing after build." >&2; exit 2; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The Space root the harness constructs against. A real directory, not just a path string:
# `SpaceViewController` hands it to `FileTreeViewController`, which lists it. Never the repo —
# this is the whole reason it lives under mktemp.
SPACE_ROOT="$TMP/space-root"; mkdir -p "$SPACE_ROOT"

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
// @testable for SpaceWindowController, SpaceViewController and SidebarToggleAccessory — all
// `internal` — the same reach check-pane-teardown.sh needs for TerminalPane/GhosttyPane.
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String) { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

/// Pump the main run loop, copied in spirit from check-pane-teardown.sh's `pump`.
/// `toggleSidebar(_:)` animates the split-view divider, so `isCollapsed` needs real run-loop
/// turns after `sendAction` before it reflects the new state.
@MainActor
func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

    // ========================================================================================
    // CASE 1 — INSTALLED.
    // ========================================================================================
    let wc = SpaceWindowController(config: .defaults(), root: root)
    guard let window = wc.window else {
        print("  ENV  SpaceWindowController produced no window — cannot probe further")
        exit(2)
    }

    let accessories = window.titlebarAccessoryViewControllers
    let toggles = accessories.compactMap { $0 as? SidebarToggleAccessory }
    print("  titlebarAccessoryViewControllers.count = \(accessories.count)")
    for (i, a) in accessories.enumerated() {
        print("  [\(i)] class=\(String(describing: type(of: a))) "
              + "layoutAttribute.rawValue=\(a.layoutAttribute.rawValue)")
    }
    if toggles.count == 1 {
        ok("exactly one SidebarToggleAccessory installed "
           + "(layoutAttribute rawValue=\(toggles[0].layoutAttribute.rawValue))")
    } else {
        fail("expected exactly 1 SidebarToggleAccessory, found \(toggles.count)")
    }
    guard let accessory = toggles.first else {
        print("  ENV  no SidebarToggleAccessory found — cannot probe cases 2-5")
        exit(1)  // case 1 already failed above; this is a real failure, not an environment gap.
    }

    // ========================================================================================
    // CASE 2 — SHAPE. The label/tooltip checks matter as much as target/action: a glyph-only
    // control with neither is unusable by VoiceOver and unreadable on hover
    // (SidebarToggleAccessory.swift:84-90).
    // ========================================================================================
    let container = accessory.view  // forces loadView() if not already loaded
    let buttons = container.subviews.compactMap { $0 as? NSButton }
    print("  container.subviews.count = \(container.subviews.count), NSButton count = \(buttons.count)")
    guard let button = buttons.first else {
        print("  ENV  no NSButton found inside accessory.view — cannot probe cases 2-5")
        exit(1)
    }

    let expectedSel = #selector(NSSplitViewController.toggleSidebar(_:))

    print("  button.target = \(String(describing: button.target))")
    if button.target == nil { ok("target == nil") }
    else { fail("target is NOT nil: \(String(describing: button.target))") }

    print("  button.action = \(String(describing: button.action))")
    if button.action == expectedSel { ok("action == #selector(NSSplitViewController.toggleSidebar(_:))") }
    else { fail("action is \(String(describing: button.action)), expected \(expectedSel)") }

    let axLabel = button.accessibilityLabel()
    print("  button.accessibilityLabel() = \(String(describing: axLabel))")
    if let axLabel, !axLabel.isEmpty { ok("accessibilityLabel() is non-empty (\"\(axLabel)\")") }
    else { fail("accessibilityLabel() is nil or empty") }

    let tooltip = button.toolTip
    print("  button.toolTip = \(String(describing: tooltip))")
    if let tooltip, !tooltip.isEmpty { ok("toolTip is non-nil, non-empty (\"\(tooltip)\")") }
    else { fail("toolTip is nil or empty") }

    print("  button.image = \(String(describing: button.image))")
    if button.image != nil { ok("image is non-nil") } else { fail("image is nil") }

    // ========================================================================================
    // CASE 3 — RESOLVES. Offscreen, real, key-eligible window; never NSApp.activate(). Under
    // .accessory with no activate, isKeyWindow reads false even after makeKey() — irrelevant
    // here, because target(forAction:to:from:) walks the chain from `from:`, not from key state.
    // ========================================================================================
    window.setFrame(NSRect(x: -20000, y: -20000, width: 1100, height: 680), display: false)
    window.orderFront(nil)
    window.makeKey()
    pump(0.5)
    print("  window.isKeyWindow = \(window.isKeyWindow), frame = \(window.frame)")

    // Resolve `button.action`, NOT the hardcoded `expectedSel`. Those differ exactly when the
    // button is miswired, which is the whole failure this case exists to catch — asking the
    // responder chain about a selector the BUTTON does not send tests the chain and nothing
    // else, and passes green while the shipped control is inert. Observed, not theorised:
    // with the action swapped to a nonsense selector this case still printed `ok ... NSSplitView`
    // until it was pointed at the consumer. Same defect class AFK.md records as "a gate measured
    // a value the app never draws". Case 2 above is what pins the action to the right selector.
    let resolvedTarget = app.target(forAction: button.action!, to: nil, from: button)
    if let resolvedTarget {
        let cls = String(describing: type(of: resolvedTarget))
        print("  NSApp.target(forAction: toggleSidebar(_:), to: nil, from: button) resolved to class = \(cls)")
        ok("resolves to a non-nil responder (\(cls))")
    } else {
        print("  NSApp.target(forAction: toggleSidebar(_:), to: nil, from: button) = nil")
        fail("resolved to NIL — button would render, click, and silently do nothing")
    }

    // ========================================================================================
    // CASE 4 — TOGGLES. `NSApp.sendAction` is the real mechanism, not a stand-in for a click.
    // ========================================================================================
    guard let sidebarItem = wc.space.splitViewItems.first else {
        print("  ENV  space.splitViewItems is empty — cannot probe toggling")
        exit(1)
    }
    let before1 = sidebarItem.isCollapsed
    print("  before first click: isCollapsed = \(before1)")
    _ = app.sendAction(button.action!, to: button.target, from: button)
    pump(0.6)
    let after1 = sidebarItem.isCollapsed
    print("  after  first click: isCollapsed = \(after1)")
    if after1 != before1 { ok("first click FLIPPED isCollapsed (\(before1) -> \(after1))") }
    else { fail("first click did NOT flip isCollapsed (stayed \(before1))") }

    _ = app.sendAction(button.action!, to: button.target, from: button)
    pump(0.6)
    let after2 = sidebarItem.isCollapsed
    print("  after second click: isCollapsed = \(after2)")
    // Both halves are required. `after2 == before1` ALONE is satisfied trivially when the first
    // click already failed to move anything — every value stays equal to every other, and this
    // line then reported "FLIPPED IT BACK (false -> false)" while the sidebar had never moved.
    // Demanding a real transition off `after1` as well is what makes a dead button fail twice
    // here instead of once.
    if after2 != after1 && after2 == before1 {
        ok("second click FLIPPED IT BACK (\(after1) -> \(after2), matches original \(before1))")
    } else if after2 == after1 {
        fail("second click did NOT move isCollapsed at all (stuck at \(after2))")
    } else { fail("second click did NOT flip it back (expected \(before1), got \(after2))") }

    // ========================================================================================
    // CASE 5 — THE CONTROL, mandatory. Without this, cases 1-4 could be passing because
    // target(forAction:) resolves everything it is asked about on this machine, and this
    // harness would be measuring the test rig instead of the button. See check-pane-teardown.sh
    // CASE 5 for the same lesson applied to process teardown.
    // ========================================================================================
    let bogusSel = NSSelectorFromString("umberProbeNoSuchAction:")
    let controlResolved = app.target(forAction: bogusSel, to: nil, from: button)
    if let controlResolved {
        let cls = String(describing: type(of: controlResolved))
        print("  NSApp.target(forAction: umberProbeNoSuchAction:, to: nil, from: button) resolved to class = \(cls)")
        fail("CONTROL RESOLVED NON-NIL (\(cls)) — the harness is measuring nothing, say so loudly")
    } else {
        print("  NSApp.target(forAction: umberProbeNoSuchAction:, to: nil, from: button) = nil")
        ok("control correctly resolved to nil for an unimplemented selector")
    }

    if bad == 0 {
        print("\nall sidebar-toggle cases passed (installed + shape + resolves + toggles + control)")
    } else {
        print("\n\(bad) sidebar-toggle case(s) FAILED")
    }
    exit(bad == 0 ? 0 : 1)
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/sidebartoggle" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" "$PRODUCTS/GhosttyTerminal.o" "$PRODUCTS/GhosttyKit.o" \
    "$PRODUCTS/MSDisplayLink.o" "$PRODUCTS/libghostty.a" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  echo "  If this names a missing member on the accessory or window controller, the seam" >&2
  echo "  changed and this script is what needs updating. If it names a linker symbol, the" >&2
  echo "  object list above is stale." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

out="$("$TMP/sidebartoggle" "$SPACE_ROOT" 2>&1)"; status=$?
say "$out"

# The exit code is the verdict; the text is for humans. A harness that died before printing
# anything is environmental (2), not a toggle failure (1) — a crashed process is telling you
# about the machine.
if [[ $status -eq 0 ]]; then exit 0; fi
if [[ $status -eq 2 ]] || ! grep -q 'ok  \|FAIL ' <<<"$out"; then
  echo "error: harness could not judge the sidebar toggle (exit $status) — treating as environmental." >&2
  exit 2
fi
exit 1
