#!/bin/bash
#
# The document lifecycle, end to end: is a pane BUILT from the engine the config names, and is it
# FREED when its tab closes? Asserts `config.engine` reaching `addTerminalDocument`, then
# `documentWillClose()` for BOTH engines — a Ghostty pane's surface freed, and each engine's shell dead.
#
# WHY THIS GATE EXISTS. `documentWillClose()` is the commit-point half of the `SpaceDocument`
# seam (`documentShouldClose()` asks, this one commits), and it was added because closing a tab
# leaked a libghostty surface AND the shell it spawned. Nothing else in this repo can see that
# failure: a leaked surface renders nothing, prints nothing, and fails no other check — the
# symptom is a Mac that gets slower over a day of opening and closing tabs. `AFK.md` carried it
# as a written risk for exactly one commit, which is the longest a risk should live as prose.
#
# WHY IT NEEDS A WINDOW SERVER. There is no headless path to a ghostty surface. `AppTerminalView`
# sets `core.isAttached = { self?.window != nil }` (`Platform/AppKit/AppTerminalView.swift:73`)
# and `rebuildIfReady` bails with "view detached" when that is false, so a bare `NSView()` never
# gets a surface — verified by execution, not inferred. Same offscreen accessory `NSWindow` shape
# as `check-ghostty-pane.sh`, for the same reason.
#
# EXIT CODES, same contract as its siblings: 0 = all cases passed. 1 = a REAL failure — a surface
# survived teardown, a shell survived it, or a doubled call misbehaved. 2 = environmental — no
# toolchain, `swift build` failed, the harness would not compile, or no surface could be created
# at all. A broken environment must never read as a green gate, and a crashed harness is telling
# you about the machine rather than about the code.
#
# THE VERDICT IS THE EXIT CODE. `check-ghostty-pane.sh` once exited 0 unconditionally with its
# verdict travelling only as a stdout substring, so a crash *after* printing "ALL-OK" read as
# green. This counts failures and exits on the count.
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

# The testable variant is what exposes Goblin Portal's internals to `@testable import`. The directory
# carries a build-configuration hash, so glob for it rather than hardcoding one machine's.
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*testable-t.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/GhosttyPane.o" ]] || {
  echo "error: no testable GoblinPortal objects under .build — cannot @testable import the real panes." >&2
  echo "  Looked for '*testable-t.build/Objects-normal/*/GhosttyPane.o'. Try: swift build" >&2
  exit 2; }
for o in GhosttyTerminal.o GhosttyKit.o libghostty.a SwiftTerm.o; do
  [[ -e "$PRODUCTS/$o" ]] || { echo "error: $PRODUCTS/$o missing after build." >&2; exit 2; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
// `@testable` on BOTH modules: GoblinPortal for the panes, GhosttyTerminal because `view.surface` is
// internal to the dependency and the freed-ness of the surface is the whole assertion.
@testable import GhosttyTerminal
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String) { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

/// Pump the main run loop, returning early once `done()` holds.
///
/// Waits here are CONJUNCTIONS, never disjunctions. `pump` returns the instant its condition
/// holds, so an `A || B` wait ends on whichever signal is faster and silently truncates the
/// other — that exact bug produced a confident false negative about OSC 7 in this repo
/// (`check-ghostty-pane.sh`'s 5a/5b split is the fix). Wait for everything, then assert.
@MainActor
func pump(_ seconds: Double, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if done() { return }
    }
}

/// Direct children of this process, which is where both engines' shells land: SwiftTerm
/// `forkpty`s from us (`LocalProcess.swift:513`) and libghostty's `.exec` backend spawns from
/// the host process too. Diffing this set across `start()` is what identifies a pane's shell
/// without either engine having to expose a pid.
func childPids() -> Set<Int32> {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-P", String(getpid())]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Set(String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
}

/// Is `pid` dead? A zombie counts as dead, and that distinction is load-bearing rather than
/// pedantic: `kill(pid, 0)` returns 0 for an unreaped zombie, so a naive liveness check would
/// call a shell that has already exited "alive" and fail this gate for the wrong reason. The
/// shell is reaped by whoever owns the child, on its own schedule. Measured against
/// `/bin/zsh -l` under a `pty.fork()`: closing the pty master moves it to `Z` immediately.
func isDead(_ pid: Int32) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "state=", "-p", String(pid)]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return true }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let state = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return state.isEmpty || state.hasPrefix("Z") || state.contains("E")
}

/// A real offscreen accessory window, positioned far off any screen. `orderBack` rather than
/// leaving it unordered: `check-ghostty-pane.sh` records that "an ordered-out window does not
/// reliably get [a surface]".
@MainActor
func hostWindow(_ view: NSView) -> NSWindow {
    let win = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView?.addSubview(view)
    view.frame = win.contentView!.bounds
    win.orderBack(nil)
    return win
}

MainActor.assumeIsolated {
    let cfg = AppConfig.defaults()
    let cwd = URL(fileURLWithPath: NSTemporaryDirectory())
    let frame = NSRect(x: 0, y: 0, width: 800, height: 400)

    // ========================================================================================
    // CASE 0 — construction honours `config.engine`.
    //
    // `check-engine-config.sh` proves a config STRING maps to the right `TerminalEngine` case, but it
    // compiles `TerminalEngine.swift` alone and therefore cannot see whether anything ever CONSULTS
    // the result. That gap is the quiet one: the mapping table could be perfect while
    // `addTerminalDocument` ignores it, and the symptom is a config line that parses without a
    // warning and changes nothing. This is the cheapest place to close it — the harness already
    // links GoblinPortal testably, and `start: false` means no shell is spawned and no window is needed, so
    // this asserts the WIRING without paying for a surface.
    // ========================================================================================
    for (engine, expected) in [(TerminalEngine.swiftTerm, "TerminalPane"),
                               (TerminalEngine.ghostty, "GhosttyPane")] {
        var c = AppConfig.defaults()
        c.engine = engine
        let space = SpaceViewController(config: c, root: cwd)
        let built = space.addTerminalDocument(start: false)
        let actual = String(describing: type(of: built))
        if actual == expected {
            ok("engine .\(engine) builds a \(expected)")
        } else {
            fail("engine .\(engine) built a \(actual), expected \(expected) — config.engine is not "
                 + "reaching addTerminalDocument")
        }
    }

    // ========================================================================================
    // CASE 1 + 2 — Ghostty: the surface is freed, and the shell dies.
    // ========================================================================================
    let before = childPids()
    let gPane = GhosttyPane(config: cfg, frame: frame, workingDirectory: cwd)
    let gWin = hostWindow(gPane.view)
    gPane.start()
    // Conjunction: a surface exists AND a child was actually spawned. Either alone would let a
    // half-started pane pass the teardown assertions trivially.
    pump(12.0) { gPane.view.surface != nil && !childPids().subtracting(before).isEmpty }
    let gChild = childPids().subtracting(before).first

    guard gPane.view.surface != nil else {
        print("  ENV  no ghostty surface came up in 12s — cannot judge teardown")
        print(bad == 0 ? "ENV-BLOCKED" : "SOME-FAILED")
        exit(2)
    }
    guard let gChild else {
        print("  ENV  ghostty spawned no direct child — cannot judge process teardown")
        print(bad == 0 ? "ENV-BLOCKED" : "SOME-FAILED")
        exit(2)
    }

    gPane.documentWillClose()
    if gPane.view.surface == nil {
        ok("ghostty: surface freed by documentWillClose() (was non-nil, now nil)")
    } else {
        fail("ghostty: surface SURVIVED documentWillClose() — tearDownSurface did not run")
    }
    pump(4.0) { isDead(gChild) }
    if isDead(gChild) { ok("ghostty: the shell it spawned (pid \(gChild)) is gone") }
    else { fail("ghostty: shell pid \(gChild) SURVIVED teardown") }

    // ========================================================================================
    // CASE 3 — SwiftTerm: the shell dies.
    //
    // Note what is NOT asserted: that SIGTERM killed it. `terminate()` closes the pty master and
    // also signals, and the close is the half that works — an interactive login shell ignores
    // SIGTERM by design. See `TerminalPane.documentWillClose()` for the measurement.
    // ========================================================================================
    let before2 = childPids()
    let tPane = TerminalPane(config: cfg, frame: frame, workingDirectory: cwd)
    let tWin = hostWindow(tPane.view)
    tPane.start()
    pump(12.0) { !childPids().subtracting(before2).isEmpty }
    guard let tChild = childPids().subtracting(before2).first else {
        print("  ENV  SwiftTerm spawned no direct child — cannot judge process teardown")
        print(bad == 0 ? "ENV-BLOCKED" : "SOME-FAILED")
        exit(2)
    }
    tPane.documentWillClose()
    pump(4.0) { isDead(tChild) }
    if isDead(tChild) { ok("swiftterm: the shell it spawned (pid \(tChild)) is gone") }
    else { fail("swiftterm: shell pid \(tChild) SURVIVED teardown") }

    // ========================================================================================
    // CASE 4 — Idempotency, and this is load-bearing rather than defensive.
    //
    // SwiftTerm's `terminate()` gates its signal on `shellPid != 0` (`LocalProcess.swift:567`),
    // and `shellPid` is assigned once at spawn (`:527`) and NEVER cleared — `childStopped()`
    // only sets `running = false` (`:269-277`). So an unguarded second call would SIGTERM a pid
    // the OS is free to have reused. The `running` guard in `documentWillClose()` is what stops
    // it; this case is what proves the guard is still there. The ghostty side is idempotent via
    // `guard controller !== oldValue` in the coordinator's didSet.
    // ========================================================================================
    gPane.documentWillClose()
    tPane.documentWillClose()
    if gPane.view.surface == nil { ok("both panes survive a SECOND documentWillClose() (idempotent)") }
    else { fail("ghostty: a second documentWillClose() resurrected a surface") }

    // ========================================================================================
    // CASE 5 — THE CONTROL, and it is mandatory.
    //
    // A pane that is started and NOT torn down must still hold its surface and its live child
    // after the same elapsed wait. Without this, every case above could be passing because
    // everything dies on its own — run-loop starvation, the harness winding down, the window
    // going away — and the gate would be measuring nothing while reading green. This is the
    // lesson `check-altbuffer-resize.sh` encodes: a verdict with no control is not a verdict.
    // ========================================================================================
    let before3 = childPids()
    let cPane = GhosttyPane(config: cfg, frame: frame, workingDirectory: cwd)
    let cWin = hostWindow(cPane.view)
    cPane.start()
    pump(12.0) { cPane.view.surface != nil && !childPids().subtracting(before3).isEmpty }
    guard let cChild = childPids().subtracting(before3).first, cPane.view.surface != nil else {
        print("  ENV  control pane never came up — cannot validate the harness")
        print(bad == 0 ? "ENV-BLOCKED" : "SOME-FAILED")
        exit(2)
    }
    pump(4.0)  // the same elapsed wait the torn-down panes got, with no teardown call
    if cPane.view.surface != nil && !isDead(cChild) {
        ok("control: an untouched pane kept its surface and its shell for the same 4s")
    } else {
        fail("control: an UNTOUCHED pane lost its surface or its shell — this harness is "
             + "measuring process exit, not teardown, and the cases above prove nothing")
    }
    cPane.documentWillClose()  // do not leak the control's own shell

    _ = (gWin, tWin, cWin)  // keep the windows alive to the end of the run

    if bad == 0 {
        print("\nall pane-teardown cases passed (engine wiring + ghostty surface + both shells + idempotency + control)")
    } else {
        print("\n\(bad) pane-teardown case(s) FAILED")
    }
    exit(bad == 0 ? 0 : 1)
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/teardown" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" "$PRODUCTS/GhosttyTerminal.o" "$PRODUCTS/GhosttyKit.o" \
    "$PRODUCTS/MSDisplayLink.o" "$PRODUCTS/libghostty.a" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  echo "  If this names a missing member on a pane, the seam changed and this script is what" >&2
  echo "  needs updating. If it names a linker symbol, the object list above is stale." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

out="$("$TMP/teardown" 2>&1)"; status=$?
say "$out"

# The exit code is the verdict; the text is for humans. A harness that died before printing
# anything is environmental (2), not a teardown failure (1) — a crashed process is telling you
# about the machine.
if [[ $status -eq 0 ]]; then exit 0; fi
if [[ $status -eq 2 ]] || ! grep -q 'ok  \|FAIL ' <<<"$out"; then
  echo "error: harness could not judge teardown (exit $status) — treating as environmental." >&2
  exit 2
fi
exit 1
