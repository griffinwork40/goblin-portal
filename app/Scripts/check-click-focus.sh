#!/bin/bash
#
# check-click-focus.sh
# Offscreen GUI gate: does a first-responder change on a split pane trigger
# dimming + focus-cue updates?
#
# WHAT IS UNDER TEST
#
# SpaceViewController+FirstResponderObserver.swift — the KVO observer that calls
# `updateSplitDimming` one run-loop turn after `NSWindow.firstResponder` changes.
# This is the fix for the click-to-focus bug: SwiftTerm's MacTerminalView.mouseDown
# consumes the event without calling super, so SplitContainerView.mouseDown (which
# fired the old didReceiveClickInChild callback) was never reached on terminal clicks.
# AppKit still calls makeFirstResponder on the clicked view independently (because
# acceptsFirstResponder = true), so firstResponder DOES change — but updateSplitDimming
# was never triggered. The KVO observer detects the firstResponder change and fires the
# update on the next run-loop turn.
#
# CASES
#
#   F1  FOCUS-MOVES  — after makeFirstResponder(paneB), the accent border layer
#                      appears on paneB and is absent from paneA (one run-loop pump).
#   F2  FOCUS-BACK   — after makeFirstResponder(paneA), the border swaps back.
#   F3  NO-SPLIT     — makeFirstResponder on a non-split pane does not add a border.
#   F4  FALSIFICATION (mandatory control) — an APFS-clone COPY of the app source
#                      with `subscribeToFirstResponderChanges` REMOVED must fail F1.
#                      Without this, passing F1/F2 could be explained by some other
#                      mechanism (e.g. SplitContainerView.mouseDown miraculously firing).
#
# EXIT CODES (standard gate contract):
#   0 = all cases passed (F1, F2, F3) and the falsification correctly failed F1.
#   1 = real failure — a case the shipped code should handle did not.
#   2 = environmental — no swiftc, swift build failed, harness would not compile,
#       or the testable objects needed to link are absent.
#
# THE VERDICT IS THE EXIT CODE, never a stdout substring.
#
# WHY OFFSCREEN GUI
#
# `updateSplitDimming` queries `view.window?.firstResponder` and manipulates CALayer
# sublayers — both require a real AppKit window hierarchy. The harness uses
# `.accessory` activation and an off-screen window (origin −20000, −20000) so it
# never steals focus from a user's active session.
#
# FALSIFICATION
#
# The APFS-clone copy (cp -cR, not cp -r, so it shares data blocks) has the
# `subscribeToFirstResponderChanges` call removed from `viewDidAppear` via a Python
# sed-equivalent. The falsification binary must FAIL F1 — if it passes, the control
# is blind and the gate exits 1 (not 2), because that is a gate correctness failure,
# not an environmental one.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

BFLAGS=()
swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)

say "==> swift build (F1/F2/F3 harness links @testable GoblinPortal objects)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
    echo "error: swift build failed — fix the build before running this gate." >&2
    swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2
    exit 2
fi

# Locate GoblinPortal object directory.
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
    -path '*/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/SpaceViewController.o" ]] || {
    echo "error: GoblinPortal objects not found under .build — cannot @testable import." >&2
    exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
    echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Shared harness (F1, F2, F3)
# ---------------------------------------------------------------------------
cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ label: String)   { print("  ok   \(label)") }
func fail(_ label: String) { print("  FAIL \(label)"); bad += 1 }

/// Pump the run loop until `done()` holds or `seconds` elapse.
/// Conjunctive: never truncates a signal by returning early on a disjunction.
@MainActor
func pump(_ seconds: Double, until done: @MainActor () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if done() { return }
    }
}

/// Does `view`'s layer have a sublayer named focusBorderLayerName?
@MainActor
func hasBorder(_ view: NSView) -> Bool {
    view.layer?.sublayers?.contains { $0.name == TerminalClipView.focusBorderLayerName } ?? false
}

MainActor.assumeIsolated {
    // -----------------------------------------------------------------------
    // Build a minimal split scene: two TerminalClipViews inside a window.
    // We do NOT start real shells — we only care about the KVO path that fires
    // updateSplitDimming, which operates on TerminalClipView layers.
    //
    // SpaceViewController wires the KVO observer in viewDidAppear. We create a
    // real SpaceViewController (with a dummy root URL) and place it in an
    // offscreen window, then trigger viewDidAppear via the window ordering.
    // -----------------------------------------------------------------------
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
    let cfg = AppConfig.defaults()
    let svc = SpaceViewController(config: cfg, root: root)

    let win = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    win.contentViewController = svc
    win.orderBack(nil)
    // Pump until viewDidAppear fires and the KVO observer is installed.
    pump(0.5)

    // Create two fake pane clip views to stand in for real TerminalClipViews.
    // updateSplitDimming resolves `leaves` via gatherLeaves → documentView
    // (which returns TerminalClipView). We inject them by building minimal
    // TerminalPane-like documents and checking the CALayer state directly.
    //
    // Since we cannot start real pty processes without a shell, we test the
    // KVO wiring by directly calling makeFirstResponder and checking that
    // updateSplitDimming runs — verifiable through the focusBorder layer.

    // Build two real TerminalPanes (no pty started — documentView is the clip).
    let frame = NSRect(x: 0, y: 0, width: 380, height: 580)
    let paneA = TerminalPane(config: cfg, frame: frame, workingDirectory: root)
    let paneB = TerminalPane(config: cfg, frame: frame, workingDirectory: root)

    // Add paneA as the primary document.
    svc.add(document: paneA)
    pump(0.2)

    // Manually install paneB as a split peer (avoids needing a live pty for makeSplit).
    // We wire only what updateSplitDimming needs: splitPeers dict + container layout.
    let entry = SplitEntry(document: paneB, direction: .horizontal)
    svc.splitPeers[ObjectIdentifier(paneA)] = entry
    svc.documentArea.presentSplit(
        primaryView: paneA.documentView,
        splitView: paneB.documentView,
        direction: .horizontal)
    svc.installClickCallback(primary: paneA)
    pump(0.2)

    // Make paneA's terminal view first responder (simulates user click on paneA).
    win.makeFirstResponder(paneA.view)
    // Pump two run-loop turns: one for KVO delivery, one for the deferred RunLoop.perform.
    pump(0.3)

    // -----------------------------------------------------------------------
    // F1 — FOCUS-MOVES: makeFirstResponder(paneB.view) → border on B, not A.
    // -----------------------------------------------------------------------
    win.makeFirstResponder(paneB.view)
    pump(0.4, until: { hasBorder(paneB.documentView) })

    let f1BorderOnB = hasBorder(paneB.documentView)
    let f1BorderOnA = hasBorder(paneA.documentView)

    if f1BorderOnB && !f1BorderOnA {
        ok("F1 FOCUS-MOVES: border on paneB, absent from paneA after makeFirstResponder(paneB)")
    } else {
        fail("F1 FOCUS-MOVES: borderOnB=\(f1BorderOnB) borderOnA=\(f1BorderOnA) — expected true/false")
    }

    // -----------------------------------------------------------------------
    // F2 — FOCUS-BACK: makeFirstResponder(paneA.view) → border swaps back.
    // -----------------------------------------------------------------------
    win.makeFirstResponder(paneA.view)
    pump(0.4, until: { hasBorder(paneA.documentView) })

    let f2BorderOnA = hasBorder(paneA.documentView)
    let f2BorderOnB = hasBorder(paneB.documentView)

    if f2BorderOnA && !f2BorderOnB {
        ok("F2 FOCUS-BACK: border on paneA, absent from paneB after makeFirstResponder(paneA)")
    } else {
        fail("F2 FOCUS-BACK: borderOnA=\(f2BorderOnA) borderOnB=\(f2BorderOnB) — expected true/false")
    }

    // -----------------------------------------------------------------------
    // F3 — NO-SPLIT: a SpaceViewController with no split entry should not add a border.
    // -----------------------------------------------------------------------
    let svc2 = SpaceViewController(config: cfg, root: root)
    let win2 = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    win2.contentViewController = svc2
    win2.orderBack(nil)
    let paneC = TerminalPane(config: cfg, frame: frame, workingDirectory: root)
    svc2.add(document: paneC)
    pump(0.3)
    // No splitPeers entry — make it first responder.
    win2.makeFirstResponder(paneC.view)
    pump(0.3)
    // updateSplitDimming is a no-op when there is no split entry, so no border appears.
    if !hasBorder(paneC.documentView) {
        ok("F3 NO-SPLIT: no border on an unsplit pane after first-responder change")
    } else {
        fail("F3 NO-SPLIT: border appeared on an unsplit pane — updateSplitDimming ran when it should not have")
    }

    if bad == 0 {
        print("\nall click-focus cases passed (F1 focus-moves, F2 focus-back, F3 no-split)")
    } else {
        print("\n\(bad) click-focus case(s) FAILED")
    }
    exit(bad == 0 ? 0 : 1)
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')

say "==> compiling F1/F2/F3 harness …"
if ! swiftc -o "$TMP/click_focus" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
    echo "error: harness would not compile." >&2
    grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
fi

out="$("$TMP/click_focus" 2>&1)"; status=$?
say "$out"

if [[ $status -ne 0 ]] && ! grep -qE 'ok |FAIL ' <<<"$out"; then
    echo "error: harness could not reach any case (exit $status) — environmental." >&2
    exit 2
fi

if [[ $status -ne 0 ]]; then
    say ""
    say "F1/F2/F3: one or more cases FAILED — shipped code did not pass."
    exit 1
fi

# ---------------------------------------------------------------------------
# F4 — FALSIFICATION via APFS clone of source with the subscription removed.
#
# We clone the Sources directory, mutate the clone's SpaceViewController.swift
# to delete the subscribeToFirstResponderChanges call from viewDidAppear, build
# a standalone binary from the clone (reusing the same SwiftTerm.o), and confirm
# the harness FAILS F1. If it passes, the gate is blind and we exit 1.
# ---------------------------------------------------------------------------
say ""
say "==> F4 FALSIFICATION: APFS-clone with subscribeToFirstResponderChanges removed …"

CLONE="$TMP/clone"
cp -cR "$ROOT/Sources" "$CLONE"

# Remove the subscribeToFirstResponderChanges call from viewDidAppear in the clone.
CLONE_SVC="$CLONE/GoblinPortal/SpaceViewController.swift"
python3 - "$CLONE_SVC" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
# Remove the viewDidAppear override that wires the KVO subscription.
patched = re.sub(
    r'\n    override func viewDidAppear\(\) \{.*?\n    \}\n',
    '\n',
    src,
    flags=re.DOTALL
)
open(sys.argv[1], 'w').write(patched)
PY

if grep -q 'subscribeToFirstResponderChanges' "$CLONE_SVC"; then
    echo "error: mutation did not remove subscribeToFirstResponderChanges — control invalid." >&2
    exit 2
fi
say "  mutant: viewDidAppear (subscribeToFirstResponderChanges) removed from clone"

# Build the falsification binary directly from the clone sources + the same SwiftTerm.o.
# We compile all GoblinPortal Swift files from the clone together with the harness.
CLONE_SOURCES=$(find "$CLONE/GoblinPortal" -name '*.swift' | grep -v 'main.swift' | tr '\n' ' ')

# The harness for the falsification run is the same F1 logic isolated.
cat > "$TMP/falsify_main.swift" <<'SWIFT'
import AppKit
// All GoblinPortal sources compiled alongside this file — no @testable import needed.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func fail(_ label: String) { print("  FAIL \(label)"); bad += 1 }
func ok(_ label: String)   { print("  ok   \(label)") }

@MainActor
func pump(_ seconds: Double, until done: @MainActor () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if done() { return }
    }
}

@MainActor
func hasBorder(_ view: NSView) -> Bool {
    view.layer?.sublayers?.contains { $0.name == TerminalClipView.focusBorderLayerName } ?? false
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
    let cfg = AppConfig.defaults()
    let svc = SpaceViewController(config: cfg, root: root)

    let win = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    win.contentViewController = svc
    win.orderBack(nil)
    pump(0.5)

    let frame = NSRect(x: 0, y: 0, width: 380, height: 580)
    let paneA = TerminalPane(config: cfg, frame: frame, workingDirectory: root)
    let paneB = TerminalPane(config: cfg, frame: frame, workingDirectory: root)
    svc.add(document: paneA)
    pump(0.2)

    let entry = SplitEntry(document: paneB, direction: .horizontal)
    svc.splitPeers[ObjectIdentifier(paneA)] = entry
    svc.documentArea.presentSplit(
        primaryView: paneA.documentView,
        splitView: paneB.documentView,
        direction: .horizontal)
    svc.installClickCallback(primary: paneA)
    pump(0.2)

    win.makeFirstResponder(paneA.view)
    pump(0.3)

    // F1 on mutant: border should NOT appear on paneB (KVO not wired).
    win.makeFirstResponder(paneB.view)
    pump(0.4, until: { hasBorder(paneB.documentView) })

    if hasBorder(paneB.documentView) {
        // Mutant passed F1 — the control is blind.
        ok("F1: border appeared on mutant (CONTROL IS BLIND — gate exits 1)")
    } else {
        // Mutant failed F1 — this is what we want.
        fail("F1: border did NOT appear on mutant (correct — mutant failed as required)")
    }
    // Exit 0 when mutant PASSED (bad=0 means ok printed = control blind = real exit 1 from outer script).
    // Exit 1 when mutant FAILED (bad>0 means fail printed = mutant correctly failed).
    exit(bad == 0 ? 0 : 1)
}
SWIFT

say "  compiling falsification binary (all clone sources + SwiftTerm.o) …"
# Find SwiftTerm sources in the vendor directory.
SWIFTTERM_SOURCES=$(find "$ROOT/vendor/SwiftTerm/Sources/SwiftTerm" -name '*.swift' 2>/dev/null | tr '\n' ' ')
[[ -n "$SWIFTTERM_SOURCES" ]] || {
    echo "error: vendor/SwiftTerm sources not found — falsification cannot compile." >&2
    exit 2; }

if ! swiftc -o "$TMP/click_focus_mutant" \
    "$TMP/falsify_main.swift" \
    $CLONE_SOURCES \
    $SWIFTTERM_SOURCES \
    -framework AppKit 2>"$TMP/mutant_compile.log"; then
    # A compile failure may be environmental (missing vendor) or a real breakage.
    # Treat as environmental (exit 2) so a compile error does not mask a gate failure.
    echo "error: falsification binary would not compile — treating as environmental." >&2
    grep -E 'error' "$TMP/mutant_compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
fi

mutant_out="$("$TMP/click_focus_mutant" 2>&1)"; mutant_status=$?
say "  mutant run:"
say "$mutant_out" | sed 's/^/    /'

# mutant_status=1: mutant FAILED F1 (good — the control works).
# mutant_status=0: mutant PASSED F1 (bad — the gate is blind).
if [[ $mutant_status -ne 0 ]]; then
    say "  ok   F4 FALSIFICATION: mutant (no KVO subscription) FAILED F1 as required — gate is not blind"
else
    say "  FAIL F4 FALSIFICATION: mutant PASSED F1 when it should have failed"
    say "       The control is blind — the fix is not actually driving the border."
    exit 1
fi

say ""
say "all click-focus cases passed (F1 focus-moves, F2 focus-back, F3 no-split, F4 falsification)"
exit 0
