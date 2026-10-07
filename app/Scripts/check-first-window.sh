#!/bin/bash
#
# Does the FIRST Space window on a clean defaults domain open at its intended size, centred —
# and does a frame the user genuinely saved still win?
#
# THE BUG. A UX audit on a fresh defaults domain measured the first window at 500x532pt, not
# centred, twice; the 220pt sidebar left the shell 28x28. Two causes were proposed: (A) assigning
# `window.contentViewController` resizes the window to NSSplitViewController's default view, and
# (B) per-root frame autosave restores a stale saved frame. This gate reproduced it on a domain
# with NO saved frame key at all, and recorded the frame at each step of the unfixed `init`:
#     NSWindow(contentRect: 1100x680)      -> (0, 0, 1100, 712)
#     contentViewController = space        -> (0, 180, 500, 532)   <- (A): the whole bug
#     setFrameAutosaveName(...)            -> (244, 180, 500, 532) and WRITTEN to defaults
# So (A) held. (B) is only the echo: autosave saved the bad frame on launch one, so launch two
# "restored" it. The fix is `SpaceWindowController+InitialFrame.swift`.
#
# CASES:
#   1. CLEAN DOMAIN — no saved key exists before construction (asserted, so case 1 cannot pass
#      by restoring something); the shown window's content is >= 1100x680 (or exactly the clamp,
#      on a screen too small for it) and it is centred in NSScreen.main's visibleFrame (<= 1pt).
#   2. CONTROL, saved frame restored — a frame written under a second root's autosave key must
#      come back exactly. Without this, a "fix" that ignored autosave entirely would pass case 1.
#      Its origin is placed >= 400pt in from the left of visibleFrame: measured on this machine,
#      AppKit nudges a window whose x is under ~244pt rightwards on show (cascade on OR off), and
#      that is not what this case is about.
#   3. SMALL-SCREEN CLAMP — `defaultFrame(contentSize:styleMask:in:)` is pure, so it is asked about
#      a 1024x600 screen and an offset secondary screen this machine may not have: the result must
#      fit inside visibleFrame and be centred in it; on a big screen it must NOT be clamped.
#   4. ISOLATION — the real com.griffinlong.goblin-portal domain's frame keys and open-Space list
#      are unchanged, compared as a DELTA against a snapshot taken first (check-space-restore.sh's
#      lesson: asserting absence fails on every machine the app was ever used on).
#
# DEFAULTS ISOLATION. A bundle-less binary's `UserDefaults.standard` is a domain named after the
# executable, so the harness binary is named with this shell's PID — a domain no run has used
# before, which is what "clean" means — and the harness removes that domain on exit. It never
# calls `present()`, which would write the open-Space list.
#
# EXIT: 0 all pass; 1 a real failure; 2 environmental (no toolchain, build/compile failure, no
# screen, or a screen too small to hold case 2's frame). The verdict is the harness EXIT CODE.
# FALSIFIED: with the `applyDefaultFrame` call removed from a temp copy of the app, case 1 fails
# with the 500x532 frame and the gate exits 1.
#
# CANNOT SEE: the real app's launch path (`AppDelegate.restoreSpaces`, tab groups of several
# Spaces), Stage Manager's placement, or how the window looks. The window is briefly ON screen (centring is the subject) but never steals focus:
# `.accessory` policy and never `NSApp.activate`, same as check-sidebar-toggle.sh.
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

# Same object lookup as check-sidebar-toggle.sh, for the same reason (N2: only the backend we
# pin writes GoblinPortal-p.build, so nothing stale from another build system can be linked).
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/SpaceWindowController.o" ]] || {
  echo "error: GoblinPortal objects not found under .build/out (expected GoblinPortal-p.build)." >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root-clean" "$TMP/root-saved"
BIN="gp-first-window-check-$$"

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String) { print("  ok   \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }
func env(_ m: String) -> Never { print("  ENV  \(m)"); exit(2) }

@MainActor func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}
func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1) -> Bool { abs(a - b) <= tol }
func frameKey(_ root: URL) -> String { "NSWindow Frame GoblinPortalSpace:\(root.path)" }

let ownDomain = ProcessInfo.processInfo.processName
guard Bundle.main.bundleIdentifier == nil, ownDomain.hasPrefix("gp-first-window-check-") else {
    env("harness would not be writing to its own throwaway defaults domain (\(ownDomain))")
}
let real = UserDefaults(suiteName: "com.griffinlong.goblin-portal")
func realSnapshot() -> [String: String] {
    var out: [String: String] = [:]
    for (k, v) in real?.dictionaryRepresentation() ?? [:]
        where k.hasPrefix("NSWindow Frame") || k == "GoblinPortal.openSpaceRoots" {
        out[k] = "\(v)"
    }
    return out
}
let realBefore = realSnapshot()

MainActor.assumeIsolated {
    let clean = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let saved = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    defer { UserDefaults.standard.removePersistentDomain(forName: ownDomain) }
    guard let screen = NSScreen.main else { env("no main screen — needs a window server") }
    let vis = screen.visibleFrame
    let want = NSSize(width: 1100, height: 680)
    print("  screen.visibleFrame = \(vis)")

    // ---- CASE 1: clean domain --------------------------------------------------------------
    print("\n  CASE 1 — clean domain")
    if UserDefaults.standard.object(forKey: frameKey(clean)) != nil {
        env("the 'clean' domain already holds a saved frame — the case would test restore, not default")
    }
    let wc = SpaceWindowController(config: .defaults(), root: clean)
    guard let w = wc.window else { env("SpaceWindowController produced no window") }
    print("  after init:          frame = \(w.frame)")
    wc.showWindow(nil); pump(0.4)
    let f = w.frame, content = w.contentRect(forFrameRect: f)
    print("  after showWindow:    frame = \(f) content = \(content.size)")
    print("  autosaved:           \(UserDefaults.standard.string(forKey: frameKey(clean)) ?? "nil")")
    let full = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: want), styleMask: w.styleMask)
    let fits = full.width <= vis.width && full.height <= vis.height
    if fits {
        if content.width >= want.width - 0.5 && content.height >= want.height - 0.5 {
            ok("content \(content.size) >= 1100x680")
        } else { fail("content \(content.size) is smaller than 1100x680 — the first window shrank") }
    } else if near(f.width, min(full.width, vis.width)) && near(f.height, min(full.height, vis.height)) {
        ok("screen too small for 1100x680; frame clamped to visibleFrame (\(f.size))")
    } else { fail("frame \(f.size) neither full size nor clamped to visibleFrame \(vis.size)") }
    if near(f.midX, vis.midX) && near(f.midY, vis.midY) {
        ok("centred in visibleFrame (mid \(f.midX),\(f.midY) vs \(vis.midX),\(vis.midY))")
    } else { fail("not centred: mid \(f.midX),\(f.midY) vs visibleFrame mid \(vis.midX),\(vis.midY)") }
    if vis.contains(f) { ok("inside visibleFrame") } else { fail("frame \(f) spills outside visibleFrame \(vis)") }
    w.orderOut(nil)

    // ---- CASE 2: CONTROL, a user-saved frame is restored -----------------------------------
    print("\n  CASE 2 — control: a saved frame is restored")
    let target = NSRect(x: vis.minX + 400, y: vis.minY + 60, width: 700, height: 450)
    guard vis.contains(target) else { env("visibleFrame \(vis) too small to hold the control frame") }
    let s = screen.frame
    let savedString = "\(Int(target.minX)) \(Int(target.minY)) \(Int(target.width)) \(Int(target.height)) "
        + "\(Int(s.minX)) \(Int(s.minY)) \(Int(s.width)) \(Int(s.height)) "
    UserDefaults.standard.set(savedString, forKey: frameKey(saved))
    let wc2 = SpaceWindowController(config: .defaults(), root: saved)
    guard let w2 = wc2.window else { env("second SpaceWindowController produced no window") }
    wc2.showWindow(nil); pump(0.4)
    print("  saved \"\(savedString)\" -> shown frame = \(w2.frame)")
    if w2.frame == target { ok("saved frame restored exactly") }
    else { fail("saved frame NOT restored: expected \(target), got \(w2.frame)") }
    w2.orderOut(nil)

    // ---- CASE 3: small-screen clamp (pure) -------------------------------------------------
    print("\n  CASE 3 — clamp to visibleFrame")
    let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    for screenRect in [NSRect(x: 0, y: 0, width: 1024, height: 600),
                       NSRect(x: 1440, y: 200, width: 1280, height: 700)] {
        let r = SpaceWindowController.defaultFrame(contentSize: want, styleMask: mask, in: screenRect)
        if screenRect.contains(r) && near(r.midX, screenRect.midX) && near(r.midY, screenRect.midY) {
            ok("\(screenRect) -> \(r): fits and is centred")
        } else { fail("\(screenRect) -> \(r): does not fit or is not centred") }
    }
    let big = NSRect(x: 0, y: 0, width: 2560, height: 1400)
    let rb = SpaceWindowController.defaultFrame(contentSize: want, styleMask: mask, in: big)
    if rb.size == full.size { ok("big screen -> \(rb.size): NOT clamped") }
    else { fail("big screen clamped to \(rb.size), expected \(full.size)") }

    // ---- CASE 4: isolation, as a delta -----------------------------------------------------
    print("\n  CASE 4 — isolation")
    if realSnapshot() == realBefore { ok("real com.griffinlong.goblin-portal frame keys + open roots unchanged") }
    else { fail("the REAL com.griffinlong.goblin-portal domain changed during this run") }

    print(bad == 0 ? "\nall first-window cases passed" : "\n\(bad) first-window case(s) FAILED")
    exit(bad == 0 ? 0 : 1)
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/$BIN" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

# `grep -v '^\['` drops the app's own `[goblin-portal]`/`[diag]` stderr chatter, not verdicts.
out="$("$TMP/$BIN" "$TMP/root-clean" "$TMP/root-saved" 2>&1)"; status=$?
# Belt and braces for the defaults plist: the harness removes its domain, but a crash would not.
defaults delete "$BIN" >/dev/null 2>&1
rm -f "$HOME/Library/Preferences/$BIN.plist"
say "$(grep -v '^\[' <<<"$out")"

if [[ $status -eq 0 ]]; then exit 0; fi
if [[ $status -eq 2 ]] || ! grep -q 'ok   \|FAIL ' <<<"$out"; then
  echo "error: harness could not judge the first window (exit $status) — treating as environmental." >&2
  exit 2
fi
exit 1
