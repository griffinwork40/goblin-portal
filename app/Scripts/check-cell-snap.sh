#!/usr/bin/env bash
# check-cell-snap.sh — on-screen but invisible GUI gate: does a terminal's cell grid stay
# PIXEL-ALIGNED to the display it is actually drawn on?
#
# Subject: GoblinPortalTerminalView+CellSnap.swift. SwiftTerm snaps the cell width to the
# pixel grid once, at font-set time, for whatever scale it can see then (the MAIN screen,
# when the pane is still detached), and never again. On a 1x monitor a width snapped for
# 2x can be fractional (18pt system mono: 11.5px), and text (placed at cellWidth*col) and
# box/block glyphs (stepped by round(cellWidthPx)) then drift apart by 0.5px per column —
# tmux's pane border lands ~4 columns right of the pane it borders. See that file's header.
#
# Needs TWO displays with DIFFERENT backing scales (e.g. a Retina laptop + a 1x monitor):
# the defect cannot exist on one scale, so a single-scale machine exits 2, never 0.
#
# Cases:
#   1 FALSIFICATION: a stock LocalProcessTerminalView (no hook), font set on the high-scale
#     screen, window moved to the low-scale one, MUST be misaligned — otherwise this gate cannot see the bug
#     at this font size and its passes below would mean nothing (exit 1, "BLIND").
#   2 GoblinPortalTerminalView, font set on the high-scale screen, window moved to the
#     low-scale one: cellWidth*scale is a whole pixel (THE case — the only one that went
#     red when the fix was stubbed out).
#   3 moved back to the high-scale screen: re-snapped, still a whole pixel.
#   4 detached-then-attached on the low-scale screen: aligned.
#
# What does NOT discriminate, stated rather than hidden (found by stubbing the re-snap out:
# only case 2 went red). Case 3 is the benign direction — 11.5pt is 23px at 2x with or
# without the fix — so it only guards that the fix does not BREAK the return trip. Case 4
# depends on NSScreen.main, which is the screen with keyboard focus, not something a gate
# can set: it discriminates only when focus is on the high-scale screen. Nothing here can
# see a pixel; that text and box glyphs then coincide follows from the renderer arithmetic
# in the +CellSnap header, not from a measurement.
#
# Exit: 0 all pass · 1 a real failure (or blind) · 2 environmental (no second-scale display,
# no window server, build or compile failure, harness died).

set -uo pipefail
QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"
command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found." >&2; exit 2; }

# The objects linked below live under .build/out, which only the Swift Build backend
# writes; a plain `swift build` on a newer toolchain refreshes .build/<triple>/ instead and
# would leave this gate linking STALE objects (same backend choice as vendored-module.sh).
BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
say "==> building (the harness links Goblin Portal's own objects, so they must be current)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed." >&2; swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2; exit 2
fi
# Locate the GoblinPortal object directory produced by the build we JUST ran.
# The Swift Build backend writes GoblinPortal-p.build/Objects-normal/<arch>/.
# The old GoblinPortal-*-testable.build glob matched only Xcode-generated artefacts
# that swift build --build-system swiftbuild never writes, so it silently linked
# objects from a previous Xcode session — weeks stale, different Swift version
# (N2, rendering-audit-2026-10-05).  The -p.build glob is unambiguous: that path
# is only written by the backend we pin, so there is no wrong-session overlap.
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/GoblinPortalTerminalView+CellSnap.o" ]] || {
  echo "error: GoblinPortal objects not found under .build/out (expected GoblinPortal-p.build)." >&2; exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || { echo "error: $PRODUCTS/SwiftTerm.o missing." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
import SwiftTerm
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func pump(_ s: Double = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }

MainActor.assumeIsolated {
    // The defect only exists one way round: a width snapped at a HIGH scale drawn at a LOW
    // one (11.5pt is 23px at 2x but 11.5px at 1x). Snapped low and drawn high it is always a
    // whole pixel. So pick the two screens by scale, not by NSScreen.main — which is merely
    // the screen with keyboard focus, and was the 1x one the first time this gate ran BLIND.
    let byScale = NSScreen.screens.sorted { $0.backingScaleFactor > $1.backingScaleFactor }
    guard let hi = byScale.first, let lo = byScale.last, hi.backingScaleFactor != lo.backingScaleFactor
    else { print("env: need two displays with different backing scales"); exit(2) }
    let hs = hi.backingScaleFactor, ls = lo.backingScaleFactor
    print("high scale \(hs), low scale \(ls)")

    func snap(_ w: CGFloat, _ s: CGFloat) -> CGFloat { ceil(w * s) / s }
    let size = ([18.0] + Array(stride(from: 11.0, through: 28.0, by: 1.0))).first { sz in
        let f = NSFont.monospacedSystemFont(ofSize: sz, weight: .regular)
        let w = f.advancement(forGlyph: f.glyph(withName: "W")).width
        let px = snap(w, hs) * ls; return px != px.rounded()
    } ?? 18.0
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    print("font size \(size)")

    func frame(on s: NSScreen) -> NSRect { NSRect(x: s.frame.minX + 40, y: s.frame.minY + 40, width: 900, height: 500) }
    func window(on s: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: frame(on: s), styleMask: .borderless, backing: .buffered, defer: false, screen: s)
        w.alphaValue = 0; w.ignoresMouseEvents = true; w.isReleasedWhenClosed = false
        w.orderFrontRegardless(); return w
    }
    func move(_ w: NSWindow, to s: NSScreen) { w.setFrame(frame(on: s), display: true); pump(0.6) }
    func aligned(_ v: TerminalView, _ w: NSWindow) -> (Bool, String) {
        let px = v.caretFrame.width * w.backingScaleFactor
        return (abs(px - px.rounded()) < 0.001, "cell \(px)px at window scale \(w.backingScaleFactor)")
    }
    var bad = 0
    func report(_ ok: Bool, _ name: String, _ detail: String) {
        print("\(ok ? "ok  " : "FAIL") \(name): \(detail)"); if !ok { bad += 1 }
    }

    // 1 — FALSIFICATION: stock SwiftTerm, font set on the high-scale screen, window moved to
    // the low-scale one (a window dragged from the laptop to the monitor). Must be misaligned.
    let plain = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    let w1 = window(on: hi); w1.contentView?.addSubview(plain); pump()
    plain.font = font
    move(w1, to: lo)
    let (pOK, pD) = aligned(plain, w1)
    report(!pOK && w1.backingScaleFactor == ls, "1 stock view misaligned after hi->lo move (else gate is BLIND)", pD)

    // 2 — the fix, same sequence.
    let fixed = GoblinPortalTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    let w2 = window(on: hi); w2.contentView?.addSubview(fixed); pump()
    fixed.font = font; fixed.noteCellGridSnapped()
    move(w2, to: lo)
    let (fOK, fD) = aligned(fixed, w2)
    report(fOK && w2.backingScaleFactor == ls, "2 fixed view re-snapped after hi->lo move", fD)

    // 3 — and back: the recorded scale must have moved with it, not stuck on the first re-snap.
    move(w2, to: hi)
    let (bOK, bD) = aligned(fixed, w2)
    report(bOK && w2.backingScaleFactor == hs, "3 fixed view re-snapped after lo->hi move", bD)

    // 4 — detached path: font applied before the view has a window (how every pane is built),
    // snapped for whatever screen has focus, then attached on the low-scale screen.
    let late = GoblinPortalTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    late.font = font; late.noteCellGridSnapped()
    let w4 = window(on: lo); w4.contentView?.addSubview(late); pump()
    let (lOK, lD) = aligned(late, w4)
    report(lOK, "4 detached-then-attached view aligned on the low-scale screen", lD)
    exit(bad == 0 ? 0 : 1)
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/cellsnap" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2; exit 2
fi

out="$("$TMP/cellsnap" 2>&1)"; status=$?
say "$out"
if [[ $status -eq 0 ]]; then exit 0; fi
if [[ $status -eq 2 ]] || ! grep -q 'ok  \|FAIL ' <<<"$out"; then
  echo "error: harness could not judge (exit $status) — treating as environmental." >&2; exit 2
fi
exit 1
