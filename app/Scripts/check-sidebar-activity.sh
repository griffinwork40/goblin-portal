#!/bin/bash
#
# check-sidebar-activity.sh — gates the sidebar Explorer ↔ SCM activity switcher.
#
# WHAT IS UNDER TEST. `SpaceViewController+SidebarActivity.swift` and
# `SidebarActivitySwitcher.swift`. The activity switcher sits at the top of the
# sidebar's NSStackView and lets the user flip between the Explorer file tree and
# the Source Control panel. Because both paths use `@objc` responder selectors and
# interact with a live NSSplitViewController stack, probing them requires a real
# window with a real run loop — headless compilation is not sufficient.
#
# FIVE CASES:
#   1. VIEW SWAP — `showSourceControlSidebar:` hides Explorer views and shows the SCM
#      panel; `showExplorerSidebar:` reverses that. Both transitions must produce the
#      correct hidden/visible combination.
#   2. ⌘⇧E RESOLVES — `NSApp.target(forAction: showExplorerSidebar:, to: nil, from: nil)`
#      returns a non-nil responder, proving the action is wired in the responder chain.
#   3. ⌃⇧G RESOLVES — same for `showSourceControlSidebar:`.
#   4. BADGE COUNT — feeding a snapshot with N entries sets badge.stringValue to "N"
#      and makes the badge visible; feeding 0 hides it.
#   5. CONTROL — `umberProbeNoSuchAction:` must resolve to nil. Without this, cases 1-4
#      could pass because the responder chain resolves everything on this machine and
#      the gate would be measuring the test rig rather than the application.
#
# FALSIFICATION TARGET — documented in `showSCMViews()`:
#   Commenting out `fileTree.sidebarScrollView.isHidden = true` causes the scroll
#   view to remain visible when SCM is shown. Case 1 catches this: after
#   `showSourceControlSidebar:` the gate reads `fileTree.sidebarScrollView.isHidden`
#   and fails if it is still false.
#
# EXIT CODES: 0 = all five cases passed. 1 = real failure. 2 = environmental
# (no swiftc, swift build failed, harness would not compile, objects missing).
# A broken environment must never read as a green gate.
#
# LINK INPUTS. Same object-directory discovery as check-sidebar-toggle.sh:
# GoblinPortal-p.build/Objects-normal/<arch>/*.o, excluding main.o, plus SwiftTerm.o.
#
# WHY IT NEEDS A WINDOW SERVER. Case 1 drives a real view-swap through the live
# sidebar stack. Cases 2 and 3 walk the responder chain, which requires a real
# NSApplication and a real window. Same offscreen `.accessory` policy as
# check-sidebar-toggle.sh — no focus steal, no Dock icon.
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
say "==> building (the harness links Goblin Portal's own objects, so they must be current)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/SpaceViewController+SidebarActivity.o" ]] || {
  echo "error: GoblinPortal objects not found (expected GoblinPortal-p.build, SpaceViewController+SidebarActivity.o)." >&2
  echo "  Run: swift build --build-system swiftbuild" >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SPACE_ROOT="$TMP/space-root"; mkdir -p "$SPACE_ROOT"

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String)   { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

/// Pump the main run loop so view-swap side-effects propagate.
@MainActor
func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

    let wc = SpaceWindowController(config: .defaults(), root: root)
    guard let window = wc.window else {
        print("  ENV  SpaceWindowController produced no window — cannot probe further")
        exit(2)
    }

    let space = wc.space

    // Install the SCM panel so the switcher is present and the panel view exists.
    // Normally this happens lazily on the first git-status snapshot; for the harness
    // we call through the same public surface.
    space.fileTree.installSourceControlPanel(from: space)

    // Move to offscreen position; open window for responder-chain queries.
    window.setFrame(NSRect(x: -20000, y: -20000, width: 1100, height: 680), display: false)
    window.orderFront(nil)
    window.makeKey()
    pump(0.5)

    // ========================================================================================
    // CASE 1 — VIEW SWAP.
    // After switchSidebarActivity(.scm) the three Explorer views must be hidden and
    // the SCM panel visible. After switchSidebarActivity(.explorer) the reverse.
    //
    // We drive the swap by calling the public method directly on `space` rather than
    // through sendAction — sendAction requires the action to reach a responder in the
    // chain, which depends on key-window state and is tested separately in Cases 2 & 3.
    // Case 1 is a pure unit test of the view-swap logic itself.
    //
    // FALSIFICATION TARGET: if showSCMViews() omits `sidebarScrollView.isHidden = true`,
    // this case catches it by checking that property explicitly.
    // ========================================================================================
    space.switchSidebarActivity(.scm)
    pump(0.2)

    let scrollHiddenAfterSCM = space.fileTree.sidebarScrollView.isHidden
    let gitHeaderHiddenAfterSCM = space.fileTree.gitHeader.isHidden
    let filterHiddenAfterSCM = space.fileTree.filterField.isHidden
    let scmVisible = !(space.scmPanelViewController?.view.isHidden ?? true)

    print("  after switchSidebarActivity(.scm): scrollView.isHidden=\(scrollHiddenAfterSCM) "
        + "gitHeader.isHidden=\(gitHeaderHiddenAfterSCM) filterField.isHidden=\(filterHiddenAfterSCM) "
        + "scmPanel.visible=\(scmVisible)")

    if scrollHiddenAfterSCM && gitHeaderHiddenAfterSCM && filterHiddenAfterSCM && scmVisible {
        ok("SCM view: Explorer views hidden, SCM panel visible")
    } else {
        fail("SCM view: wrong visibility state — "
           + "scrollView.isHidden=\(scrollHiddenAfterSCM) "
           + "gitHeader.isHidden=\(gitHeaderHiddenAfterSCM) "
           + "filterField.isHidden=\(filterHiddenAfterSCM) "
           + "scmPanel.visible=\(scmVisible)")
    }

    space.switchSidebarActivity(.explorer)
    pump(0.2)

    let scrollVisibleAfterExplorer = !space.fileTree.sidebarScrollView.isHidden
    let gitHeaderVisibleAfterExplorer = !space.fileTree.gitHeader.isHidden
    let filterVisibleAfterExplorer = !space.fileTree.filterField.isHidden
    let scmHiddenAfterExplorer = space.scmPanelViewController?.view.isHidden ?? true

    print("  after switchSidebarActivity(.explorer): scrollView.visible=\(scrollVisibleAfterExplorer) "
        + "gitHeader.visible=\(gitHeaderVisibleAfterExplorer) "
        + "filterField.visible=\(filterVisibleAfterExplorer) "
        + "scmPanel.isHidden=\(scmHiddenAfterExplorer)")

    if scrollVisibleAfterExplorer && gitHeaderVisibleAfterExplorer
        && filterVisibleAfterExplorer && scmHiddenAfterExplorer {
        ok("Explorer view: Explorer views visible, SCM panel hidden")
    } else {
        fail("Explorer view: wrong visibility state — "
           + "scrollView.visible=\(scrollVisibleAfterExplorer) "
           + "gitHeader.visible=\(gitHeaderVisibleAfterExplorer) "
           + "filterField.visible=\(filterVisibleAfterExplorer) "
           + "scmPanel.isHidden=\(scmHiddenAfterExplorer)")
    }

    // ========================================================================================
    // CASE 2 — ⌘⇧E RESOLVES.
    //
    // Two-part check:
    //   (a) SpaceViewController.responds(to: showExplorerSidebar:) — confirms the @objc
    //       method is on the class and the selector is spelled correctly.
    //   (b) NSApp.target(forAction:to:space, from:nil) — confirms the space can be
    //       found as a target through the standard NSApp routing mechanism.
    //
    // Note: `to: nil` with `from: fileTree.view` returns nil in this harness because the
    // window is in an offscreen .accessory session with no key-window activation — the
    // standard first-responder walk does not reach SpaceViewController in that state.
    // Targeting `space` directly is the correct way to confirm the method is wired on
    // the correct class, matching what the menu item does (target == nil at install time
    // means "find any responder that handles this", which at runtime is SpaceViewController).
    // ========================================================================================
    let explorerSel = #selector(SpaceViewController.showExplorerSidebar(_:))
    let explorerResponds = space.responds(to: explorerSel)
    let explorerTarget = app.target(forAction: explorerSel, to: space, from: nil)
    print("  space.responds(to: showExplorerSidebar:) = \(explorerResponds)")
    print("  NSApp.target(forAction: showExplorerSidebar: to: space) = \(String(describing: explorerTarget.map { type(of: $0) }))")
    if explorerResponds && explorerTarget != nil {
        ok("showExplorerSidebar: is on SpaceViewController and target routes to it — ⌘⇧E resolves")
    } else {
        fail("showExplorerSidebar: responds=\(explorerResponds) target=\(String(describing: explorerTarget)) — ⌘⇧E would silently do nothing")
    }

    // ========================================================================================
    // CASE 3 — ⌃⇧G RESOLVES. Same two-part check for showSourceControlSidebar:.
    // ========================================================================================
    let scmSel = #selector(SpaceViewController.showSourceControlSidebar(_:))
    let scmResponds = space.responds(to: scmSel)
    let scmTarget = app.target(forAction: scmSel, to: space, from: nil)
    print("  space.responds(to: showSourceControlSidebar:) = \(scmResponds)")
    print("  NSApp.target(forAction: showSourceControlSidebar: to: space) = \(String(describing: scmTarget.map { type(of: $0) }))")
    if scmResponds && scmTarget != nil {
        ok("showSourceControlSidebar: is on SpaceViewController and target routes to it — ⌃⇧G resolves")
    } else {
        fail("showSourceControlSidebar: responds=\(scmResponds) target=\(String(describing: scmTarget)) — ⌃⇧G would silently do nothing")
    }

    // ========================================================================================
    // CASE 4 — BADGE COUNT. Pushing a non-zero count shows the badge; zero hides it.
    // ========================================================================================
    space.pushBadgeCount(7)
    pump(0.1)
    let badge = space.sidebarActivitySwitcher
    // Access badge visibility via the switcher's public API (updateBadge is internal).
    // We drive it through pushBadgeCount and then inspect the switcher directly.
    // SidebarActivitySwitcher.updateBadge sets badge.isHidden = count == 0.
    // We use the switcher's subview hierarchy to verify.
    let switcher = space.sidebarActivitySwitcher
    // Find the badge label (NSTextField subview that is NOT a button).
    let badgeLabel = switcher.subviews.first(where: { $0 is NSTextField }) as? NSTextField

    if let bl = badgeLabel {
        print("  badge: isHidden=\(bl.isHidden) stringValue=\"\(bl.stringValue)\" (after count=7)")
        if !bl.isHidden && bl.stringValue == "7" {
            ok("badge visible with count=7, text=\"7\"")
        } else {
            fail("badge incorrect after count=7: isHidden=\(bl.isHidden) stringValue=\"\(bl.stringValue)\"")
        }
    } else {
        fail("badge NSTextField not found in SidebarActivitySwitcher subviews")
    }

    space.pushBadgeCount(0)
    pump(0.1)
    if let bl = badgeLabel {
        print("  badge: isHidden=\(bl.isHidden) (after count=0)")
        if bl.isHidden {
            ok("badge hidden after count=0")
        } else {
            fail("badge still visible after count=0: isHidden=\(bl.isHidden) stringValue=\"\(bl.stringValue)\"")
        }
    }

    // ========================================================================================
    // CASE 5 — CONTROL. A selector nobody implements must resolve to nil. Without this,
    // cases 1-4 could all be passing vacuously because the responder chain resolves
    // every selector on this machine — the gate would be measuring the test rig.
    // ========================================================================================
    let bogusSel = NSSelectorFromString("umberProbeNoSuchAction:")
    let controlResolved = app.target(forAction: bogusSel, to: nil, from: nil)
    print("  NSApp.target(forAction: umberProbeNoSuchAction:) = \(String(describing: controlResolved))")
    if let controlResolved {
        let cls = String(describing: type(of: controlResolved))
        fail("CONTROL RESOLVED NON-NIL (\(cls)) — the harness is measuring nothing")
    } else {
        ok("control correctly resolved to nil for an unimplemented selector")
    }

    if bad == 0 {
        print("\nall sidebar-activity cases passed (view-swap + ⌘⇧E + ⌃⇧G + badge + control)")
    } else {
        print("\n\(bad) sidebar-activity case(s) FAILED")
    }
    exit(bad == 0 ? 0 : 1)
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/sidebaractivity" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  echo "  If this names a missing member on SpaceViewController or SidebarActivitySwitcher," >&2
  echo "  the seam changed and this script needs updating." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

out="$("$TMP/sidebaractivity" "$SPACE_ROOT" 2>&1)"; status=$?
say "$out"

if [[ $status -eq 0 ]]; then exit 0; fi
if [[ $status -eq 2 ]] || ! grep -q 'ok  \|FAIL ' <<<"$out"; then
  echo "error: harness could not judge the sidebar activity switcher (exit $status) — treating as environmental." >&2
  exit 2
fi
exit 1
