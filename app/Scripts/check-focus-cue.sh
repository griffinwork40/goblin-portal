#!/bin/bash
#
# check-focus-cue.sh
# Offscreen GUI gate: does the focus-border layer track pane resize?
#
# WHY THIS GATE EXISTS
#
# Case K of .afk/verification/focus-cue-checklist.md — "border tracks pane resize" —
# is mechanically checkable: `TerminalClipView.layout()` must re-frame any sublayer
# named "goblin.focusBorder" to `focusBorderFrame(in: bounds)` on every layout pass.
# During the #217 land run an offscreen probe compiled the shipped TerminalClipView.swift
# and confirmed the frame tracks both grow and shrink; a copy WITHOUT the layout()
# override failed as the control. This gate makes that probe permanent.
#
# WHAT IS UNDER TEST
#
# `TerminalClipView.layout()` (TerminalClipView.swift:80-89). The method iterates
# sublayers named `TerminalClipView.focusBorderLayerName` and re-applies
# `focusBorderFrame(in: host.bounds)` with animations disabled. Without it, a frame
# set at focus-change time goes stale on the next window resize or divider drag, leaving
# a border that no longer hugs the focused pane's edge.
#
# THREE CASES
#
#   K1  GROW   — shipped TerminalClipView: after the view grows, the border layer's
#                frame matches `focusBorderFrame(in: newBounds)`.
#   K2  SHRINK — shipped TerminalClipView: after the view shrinks, the border layer's
#                frame matches `focusBorderFrame(in: newBounds)`.
#   K3  CONTROL (mandatory) — a COPY of TerminalClipView.swift with the layout()
#                override deleted is compiled standalone and the same harness run
#                against it. K1 must FAIL for the mutant. Without a control that
#                actually fails, the passing K1/K2 cases could be coincidental (e.g.
#                CALayer autoresizing doing the right thing for some other reason),
#                and the gate would be measuring nothing.
#
#                The mutant is compiled from a COPY (`cp`), never the shipped file,
#                per the gate convention in AFK.md. `TerminalClipView.swift` imports
#                only AppKit so it compiles standalone — same trick as
#                `check-renderer-config.sh` (Foundation-only) and `check-smooth-scroll.sh`.
#
# EXIT CODES — same three-valued contract as every other gate in this repo:
#   0 = all cases passed (K1, K2 passed; K3 mutant failed K1 as required).
#   1 = a REAL failure — K1 or K2 failed (border did not track), or K3 passed when
#       it should have failed (the control is blind).
#   2 = environmental — no swiftc, swift build failed, harness would not compile, or
#       the testable objects needed to link are absent.
#
# THE VERDICT IS THE EXIT CODE, never a stdout substring.
#
# WHY K1/K2 NEED A WINDOW SERVER
#
# `layout()` is called by AppKit's layout engine during a real view-hierarchy pass.
# We trigger it by resizing the view's frame and calling `layoutSubtreeIfNeeded()`,
# which requires the view to be layer-backed (TerminalClipView.swift:39: wantsLayer=true).
# No GPU path is exercised; the process runs offscreen with `.accessory` activation
# and never steals focus. K3 compiles the mutant standalone with no window server needed.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"
CLIP_SRC="$ROOT/Sources/GoblinPortal/TerminalClipView.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

[[ -f "$CLIP_SRC" ]] || {
  echo "error: $CLIP_SRC not found." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
say "==> building (K1/K2 harness links Goblin Portal objects, so they must be current)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

# Locate GoblinPortal object directory produced by the build we just ran.
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/TerminalClipView.o" ]] || {
  echo "error: GoblinPortal objects not found — cannot @testable import." >&2
  echo "  Expected: .build/out/Intermediates.noindex/.../GoblinPortal-p.build/Objects-normal/<arch>/TerminalClipView.o" >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Shared harness Swift source — tests K1 GROW and K2 SHRINK.
# Used twice: once against the shipped binary (K1+K2) and once against the
# mutant binary (K3 control — must fail K1).
# ---------------------------------------------------------------------------
cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String)   { print("  ok   \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

/// Pump the main run loop, returning early once `done()` holds.
/// Waits are conjunctions — never disjunctions — so no signal is truncated.
@MainActor
func pump(_ seconds: Double, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if done() { return }
    }
}

MainActor.assumeIsolated {
    // Build a real TerminalClipView with a dummy hosted view. The clip view is
    // layer-backed (wantsLayer = true in init), so layout() will update sublayers.
    let initialFrame = NSRect(x: 0, y: 0, width: 400, height: 200)
    let terminal = NSView(frame: initialFrame)
    let clip = TerminalClipView(hosting: terminal, frame: initialFrame)

    // Host it in an offscreen window so AppKit's layout engine can run.
    let win = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView?.addSubview(clip)
    clip.frame = win.contentView!.bounds
    win.orderBack(nil)
    pump(0.1)

    // Install a fake focus-border sublayer — the same way SpaceViewController+FocusCue
    // does it — so layout() has something to re-frame.
    let border = CALayer()
    border.name = TerminalClipView.focusBorderLayerName
    border.borderWidth = 1.0
    // Deliberately wrong initial frame so we can detect whether layout() corrects it.
    border.frame = CGRect(x: 99, y: 99, width: 10, height: 10)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    clip.layer?.addSublayer(border)
    CATransaction.commit()

    // -----------------------------------------------------------------------
    // K1 — GROW: resize the clip view larger; border must track.
    // -----------------------------------------------------------------------
    let grownBounds = NSRect(x: 0, y: 0, width: 600, height: 350)
    clip.frame = grownBounds
    clip.layoutSubtreeIfNeeded()
    pump(0.1)

    let expectedGrown = TerminalClipView.focusBorderFrame(in: grownBounds)
    if border.frame == expectedGrown {
        ok("K1 GROW: border frame \(border.frame) matches focusBorderFrame after grow")
    } else {
        fail("K1 GROW: border frame \(border.frame) ≠ expected \(expectedGrown) after grow")
    }

    // -----------------------------------------------------------------------
    // K2 — SHRINK: resize the clip view smaller; border must track.
    // -----------------------------------------------------------------------
    let shrunkBounds = NSRect(x: 0, y: 0, width: 200, height: 100)
    clip.frame = shrunkBounds
    clip.layoutSubtreeIfNeeded()
    pump(0.1)

    let expectedShrunk = TerminalClipView.focusBorderFrame(in: shrunkBounds)
    if border.frame == expectedShrunk {
        ok("K2 SHRINK: border frame \(border.frame) matches focusBorderFrame after shrink")
    } else {
        fail("K2 SHRINK: border frame \(border.frame) ≠ expected \(expectedShrunk) after shrink")
    }

    if bad == 0 {
        print("\nall focus-cue resize cases passed (K1 grow, K2 shrink)")
    } else {
        print("\n\(bad) focus-cue resize case(s) FAILED")
    }
    exit(bad == 0 ? 0 : 1)
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')

# ---------------------------------------------------------------------------
# K1 + K2 — shipped binary (@testable import GoblinPortal)
# ---------------------------------------------------------------------------
if ! swiftc -o "$TMP/focus_cue" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

out="$("$TMP/focus_cue" 2>&1)"; status=$?
say "$out"

if [[ $status -ne 0 ]] && ! grep -q 'ok  \|FAIL ' <<<"$out"; then
  echo "error: harness could not judge resize (exit $status) — treating as environmental." >&2
  exit 2
fi

if [[ $status -ne 0 ]]; then
  say ""
  say "K1/K2 failed — shipped TerminalClipView did not track resize."
  exit 1
fi

# ---------------------------------------------------------------------------
# K3 — CONTROL (falsification)
#
# TerminalClipView.swift imports only AppKit — it compiles standalone, the same
# trick check-renderer-config.sh plays for Renderer.swift (Foundation-only).
#
# A COPY of TerminalClipView.swift has its layout() override removed. That copy
# is compiled into a standalone binary that re-implements the harness logic
# WITHOUT @testable import, directly inlining the two TerminalClipView members
# that the test exercises (focusBorderLayerName, focusBorderFrame, layout()).
# The mutant binary must exit 1 (K1 fails) — the control is blind if it exits 0.
# ---------------------------------------------------------------------------
say ""
say "==> K3 CONTROL: compiling mutant (layout() override deleted from copy) …"

cp "$CLIP_SRC" "$TMP/TerminalClipView_mutant.swift"

# Delete the layout() override block from the copy using python3 (portable,
# avoids macOS sed -i quirks). Matches from the doc-comment line through the
# closing `}` of the override — the exact block in TerminalClipView.swift:71-89.
python3 - "$TMP/TerminalClipView_mutant.swift" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
patched = re.sub(
    r'\n    /// Re-frame the focus border.*?override func layout\(\) \{.*?\n    \}',
    '',
    src,
    flags=re.DOTALL
)
open(sys.argv[1], 'w').write(patched)
PY

if grep -q 'override func layout' "$TMP/TerminalClipView_mutant.swift"; then
  echo "error: mutation did not remove layout() override — control is invalid." >&2
  exit 2
fi
say "  mutant: layout() override removed from copy"

# Standalone harness that exercises the mutant's layout() behaviour without
# @testable import. Inlines the two static members under test to avoid module dep.
cat > "$TMP/mutant_main.swift" <<'SWIFT'
import AppKit

// TerminalClipView compiled alongside this file — reference its members directly.
// (No @testable import needed; the class is visible because it's in the same swiftc
// invocation.)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String)   { print("  ok   \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

@MainActor
func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

MainActor.assumeIsolated {
    let initialFrame = NSRect(x: 0, y: 0, width: 400, height: 200)
    let clip = TerminalClipView(hosting: NSView(frame: initialFrame), frame: initialFrame)

    let win = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView?.addSubview(clip)
    clip.frame = win.contentView!.bounds
    win.orderBack(nil)
    pump(0.1)

    let border = CALayer()
    border.name = TerminalClipView.focusBorderLayerName
    border.borderWidth = 1.0
    border.frame = CGRect(x: 99, y: 99, width: 10, height: 10)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    clip.layer?.addSublayer(border)
    CATransaction.commit()

    // K1 on mutant — must FAIL (layout() deleted, frame stays stale)
    let grownBounds = NSRect(x: 0, y: 0, width: 600, height: 350)
    clip.frame = grownBounds
    clip.layoutSubtreeIfNeeded()
    pump(0.1)

    let expected = TerminalClipView.focusBorderFrame(in: grownBounds)
    if border.frame == expected {
        ok("K1 GROW: border tracked (mutant PASSED — control is BLIND)")
    } else {
        fail("K1 GROW: border did NOT track — mutant FAILED as required")
    }

    exit(bad == 0 ? 0 : 1)  // exits 1 when mutant failed K1 (good); 0 if it passed (bad)
}
SWIFT

mkdir -p "$TMP/mutant_sources"
mv "$TMP/mutant_main.swift" "$TMP/mutant_sources/main.swift"
cp "$TMP/TerminalClipView_mutant.swift" "$TMP/mutant_sources/TerminalClipView.swift"

if ! swiftc -o "$TMP/focus_cue_mutant" \
    "$TMP/mutant_sources/main.swift" "$TMP/mutant_sources/TerminalClipView.swift" \
    -framework AppKit 2>"$TMP/mutant_compile.log"; then
  echo "error: mutant harness would not compile." >&2
  grep -E 'error' "$TMP/mutant_compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

mutant_out="$("$TMP/focus_cue_mutant" 2>&1)"; mutant_status=$?
say "  mutant run:"
say "$mutant_out" | sed 's/^/    /'

# mutant_status=1 means K1 FAILED for the mutant — this is what we want.
# mutant_status=0 means the mutant PASSED K1 — the control is blind.
if [[ $mutant_status -ne 0 ]]; then
  say "  ok   K3 CONTROL: mutant (no layout() override) FAILED K1 as required — gate is not blind"
else
  say "  FAIL K3 CONTROL: mutant PASSED K1 when it should have FAILED"
  say "       The control is blind — K1/K2 passes mean nothing."
  exit 1
fi

say ""
say "all focus-cue cases passed (K1 grow, K2 shrink, K3 control mutant failed as required)"
exit 0
