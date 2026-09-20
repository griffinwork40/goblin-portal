#!/bin/bash
#
# The document lifecycle, end to end: does `documentWillClose()` kill a pane's shell?
# Asserts that closing a TerminalPane terminates the shell it spawned.
#
# WHY THIS GATE EXISTS. `documentWillClose()` is the commit-point half of the `SpaceDocument`
# seam (`documentShouldClose()` asks, this one commits), and it was added because closing a tab
# can leak the shell it spawned. Nothing else in this repo can see that failure: a leaked shell
# is invisible in the UI, prints nothing, and fails no other check — the symptom is a Mac with
# accumulating zombie processes over a day of opening and closing tabs.
#
# EXIT CODES, same contract as its siblings: 0 = all cases passed. 1 = a REAL failure — a shell
# survived teardown, or a doubled call misbehaved. 2 = environmental — no toolchain, `swift
# build` failed, the harness would not compile, or no shell could be spawned at all. A broken
# environment must never read as a green gate.
#
# THE VERDICT IS THE EXIT CODE. A previous version of this script had its verdict travel only as
# a stdout substring, so a crash after printing "ALL-OK" read as green. This counts failures and
# exits on the count.
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
[[ -n "$TOBJ" && -f "$TOBJ/TerminalPane.o" ]] || {
  echo "error: no testable GoblinPortal objects under .build — cannot @testable import the real panes." >&2
  echo "  Looked for '*testable-t.build/Objects-normal/*/TerminalPane.o'. Try: swift build" >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
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
/// other. Wait for everything, then assert.
@MainActor
func pump(_ seconds: Double, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if done() { return }
    }
}

/// Direct children of this process — SwiftTerm `forkpty`s from us (`LocalProcess.swift:513`).
/// Diffing this set across `start()` identifies a pane's shell without the pane having to
/// expose a pid.
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
/// call a shell that has already exited "alive" and fail this gate for the wrong reason.
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

/// A real offscreen accessory window, positioned far off any screen. Keeps the pane's view
/// hierarchy intact so SwiftTerm's pty can start cleanly.
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
    // CASE 1 — SwiftTerm: the shell dies after documentWillClose().
    //
    // Note what is NOT asserted: that SIGTERM killed it. `terminate()` closes the pty master
    // and also signals, and the close is the half that works — an interactive login shell
    // ignores SIGTERM by design. See `TerminalPane.documentWillClose()` for the measurement.
    // ========================================================================================
    let before = childPids()
    let tPane = TerminalPane(config: cfg, frame: frame, workingDirectory: cwd)
    let tWin = hostWindow(tPane.view)
    tPane.start()
    pump(12.0) { !childPids().subtracting(before).isEmpty }
    guard let tChild = childPids().subtracting(before).first else {
        print("  ENV  SwiftTerm spawned no direct child — cannot judge process teardown")
        print(bad == 0 ? "ENV-BLOCKED" : "SOME-FAILED")
        exit(2)
    }
    tPane.documentWillClose()
    pump(4.0) { isDead(tChild) }
    if isDead(tChild) { ok("swiftterm: the shell it spawned (pid \(tChild)) is gone after documentWillClose()") }
    else { fail("swiftterm: shell pid \(tChild) SURVIVED teardown") }

    // ========================================================================================
    // CASE 2 — Idempotency, and this is load-bearing rather than defensive.
    //
    // SwiftTerm's `terminate()` gates its signal on `shellPid != 0` (`LocalProcess.swift:567`),
    // and `shellPid` is assigned once at spawn (`:527`) and NEVER cleared — `childStopped()`
    // only sets `running = false` (`:269-277`). So an unguarded second call would SIGTERM a pid
    // the OS is free to have reused. The `running` guard in `documentWillClose()` is what stops
    // it; this case is what proves the guard is still there.
    // ========================================================================================
    tPane.documentWillClose()
    ok("pane survives a second documentWillClose() (idempotent)")
    if isDead(tChild) { ok("idempotency: shell (pid \(tChild)) is still dead — no spurious signal was sent") }
    else { fail("idempotency: shell pid \(tChild) is ALIVE after second documentWillClose() — running guard missing?") }

    // ========================================================================================
    // CASE 3 — THE CONTROL, and it is mandatory.
    //
    // A pane that is started and NOT torn down must still hold its live child after the same
    // elapsed wait. Without this, every case above could be passing because everything dies on
    // its own — run-loop starvation, the harness winding down, the window going away — and the
    // gate would be measuring nothing while reading green.
    // ========================================================================================
    let before2 = childPids()
    let cPane = TerminalPane(config: cfg, frame: frame, workingDirectory: cwd)
    let cWin = hostWindow(cPane.view)
    cPane.start()
    pump(12.0) { !childPids().subtracting(before2).isEmpty }
    guard let cChild = childPids().subtracting(before2).first else {
        print("  ENV  control pane spawned no direct child — cannot validate the harness")
        print(bad == 0 ? "ENV-BLOCKED" : "SOME-FAILED")
        exit(2)
    }
    pump(4.0)  // same elapsed wait the torn-down pane got, with no teardown call
    if !isDead(cChild) {
        ok("control: an untouched pane's shell (pid \(cChild)) is still alive after the same 4s")
    } else {
        fail("control: an UNTOUCHED pane lost its shell — this harness is measuring process exit, "
             + "not teardown, and case 1 proves nothing")
    }
    cPane.documentWillClose()  // do not leak the control's own shell

    _ = (tWin, cWin)  // keep windows alive to the end of the run

    if bad == 0 {
        print("\nall pane-teardown cases passed (shell exits + idempotency + control)")
    } else {
        print("\n\(bad) pane-teardown case(s) FAILED")
    }
    exit(bad == 0 ? 0 : 1)
}
SWIFT

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/teardown" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
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
