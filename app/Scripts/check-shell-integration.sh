#!/bin/bash
#
# Does the OSC 133 parser correctly implement the A/C/D state machine?
# Asserts ShellIntegration.swift's handler and parseExitCode function.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/ShellIntegration.swift` only. That file is
# Foundation-only BY DESIGN — the OSC 133 parser and state machine are pure functions
# of their inputs, and a pure function compiles headless with swiftc. Same trick
# check-command-outcome.sh plays on CommandOutcome.swift, check-cwd-follow.sh on
# ShellDirectory.swift, check-cursor-style.sh on CursorStyle.swift.
#
# Compiling the SHIPPED file, not a restatement of its logic, is the whole point: a
# check that restates the parser proves only that the check agrees with itself.
#
# WHY IT EXISTS. The A/C/D state machine has one load-bearing edge: a D before any C
# (the first precmd after sourcing the script) must be silently ignored. Get that wrong
# and every shell session opens by fabricating a zero-exit command of some duration —
# which could mark the tab, depending on CommandOutcome's threshold. The machine also
# has a second correctness invariant: D;0 must yield exit code 0, D must yield nil, and
# D;127 must yield 127. Exit code parsing is load-bearing for the failed/succeeded split.
#
# WHAT IT CANNOT REACH. Whether the OSC 133 sequence actually arrives from the zsh
# script, whether `registerOscHandler` fires at the right moment, and whether the tab
# strip repaint is triggered — all AppKit or live-shell territory. This owns the
# parser and state machine.
#
# EXIT CODES: 0 = all cases passed. 1 = real failure (parser wrong, state machine wrong).
# 2 = environmental (no toolchain, source file missing, harness compile failure).
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/ShellIntegration.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }
[[ -f "$SRC" ]] || {
    echo "error: $SRC not found — did the file move? This gate names its subject explicitly." >&2
    exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$SRC" "$TMP/ShellIntegration.swift"

# The harness uses ShellIntegration.State directly (it is not `private`).
# It exercises `handle(data:state:)` and `parseExitCode(from:)` — both are
# `internal` rather than `private`, which is what makes them reachable here.
# This mirrors how check-cwd-follow.sh exercises ShellDirectory.singleQuoted.
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

var bad = 0
func fail(_ label: String, _ msg: String) {
    print("  FAIL \(label): \(msg)")
    bad += 1
}
func ok(_ label: String) {
    // Only printed when QUIET == 0; say() is a shell construct, not available here.
    // The gate script mirrors check-command-outcome.sh: final summary only.
}

// ── parseExitCode ──────────────────────────────────────────────────────────────

func asBytes(_ s: String) -> ArraySlice<UInt8> {
    ArraySlice(s.utf8)
}

// D with no semicolon → nil (no exit code)
if ShellIntegration.parseExitCode(from: asBytes("D")) != nil {
    fail("D-no-semi", "expected nil, got \(ShellIntegration.parseExitCode(from: asBytes("D"))!)")
}

// D; with nothing after → nil
if ShellIntegration.parseExitCode(from: asBytes("D;")) != nil {
    fail("D-empty-code", "expected nil for empty suffix")
}

// D;0 → 0
if ShellIntegration.parseExitCode(from: asBytes("D;0")) != 0 {
    fail("D;0", "expected 0, got \(String(describing: ShellIntegration.parseExitCode(from: asBytes("D;0"))))")
}

// D;1 → 1
if ShellIntegration.parseExitCode(from: asBytes("D;1")) != 1 {
    fail("D;1", "expected 1")
}

// D;127 → 127 (command not found)
if ShellIntegration.parseExitCode(from: asBytes("D;127")) != 127 {
    fail("D;127", "expected 127")
}

// D;-1 → -1 (signal-killed processes sometimes report -1)
if ShellIntegration.parseExitCode(from: asBytes("D;-1")) != -1 {
    fail("D;-1", "expected -1")
}

// D;130 → 130 (Ctrl+C, SIGINT+128)
if ShellIntegration.parseExitCode(from: asBytes("D;130")) != 130 {
    fail("D;130", "expected 130")
}

// D;0;extra → 0 (extra fields are trimmed)
if ShellIntegration.parseExitCode(from: asBytes("D;0;extra")) != 0 {
    fail("D;0;extra", "expected 0 (trimmed at non-digit)")
}

// D;abc → nil (non-numeric)
if ShellIntegration.parseExitCode(from: asBytes("D;abc")) != nil {
    fail("D;abc", "expected nil for non-numeric code")
}

// ── State machine ──────────────────────────────────────────────────────────────

var received: [(Int?, UInt64)] = []
let state = ShellIntegration.State { code, nanos in
    received.append((code, nanos))
}

// 1. D before any C → ignored (first precmd after sourcing)
ShellIntegration.handle(data: asBytes("D;0"), state: state)
if !received.isEmpty {
    fail("D-before-C", "D before any C must be ignored; got \(received.count) callback(s)")
}

// 2. A clears the start-time guard — falsification: set commandStartTime first so
//    deleting the `commandStartTime = nil` line in handle(case "A") would expose the gap.
//    Without priming commandStartTime, a fresh State already has it nil, so removing the
//    nil-assignment in the A handler would still pass — the D would reach `guard let start`
//    and bail, giving a false green. Priming forces a real clear.
state.commandStartTime = Date()
ShellIntegration.handle(data: asBytes("A"), state: state)
if state.commandStartTime != nil {
    fail("A-clears-start-time", "A must set commandStartTime to nil; got non-nil after A")
}
// D after A (still no C) → still ignored
ShellIntegration.handle(data: asBytes("D;0"), state: state)
if !received.isEmpty {
    fail("D-after-A-no-C", "D after A without C must be ignored; got \(received.count) callback(s)")
}

// 3. C → D delivers a callback
ShellIntegration.handle(data: asBytes("C"), state: state)
Thread.sleep(forTimeInterval: 0.001)  // ensure elapsed > 0
ShellIntegration.handle(data: asBytes("D;0"), state: state)
if received.count != 1 {
    fail("C-then-D", "expected 1 callback after C→D, got \(received.count)")
} else if received[0].0 != 0 {
    fail("C-then-D-exitCode", "expected exit code 0, got \(String(describing: received[0].0))")
} else if received[0].1 == 0 {
    fail("C-then-D-nanos", "expected nanos > 0 (measured duration), got 0")
}
received.removeAll()

// 4. D without C after the previous D → ignored (state reset to idle)
ShellIntegration.handle(data: asBytes("D;1"), state: state)
if !received.isEmpty {
    fail("D-after-D", "second consecutive D must be ignored (state was reset to idle)")
}

// 5. Non-zero exit code delivered correctly
ShellIntegration.handle(data: asBytes("C"), state: state)
ShellIntegration.handle(data: asBytes("D;127"), state: state)
if received.count != 1 {
    fail("exit-127-count", "expected 1 callback, got \(received.count)")
} else if received[0].0 != 127 {
    fail("exit-127-code", "expected 127, got \(String(describing: received[0].0))")
}
received.removeAll()

// 6. D without exit code (nil) after a C
ShellIntegration.handle(data: asBytes("C"), state: state)
ShellIntegration.handle(data: asBytes("D"), state: state)
if received.count != 1 {
    fail("D-no-code-count", "expected 1 callback for D with no code, got \(received.count)")
} else if received[0].0 != nil {
    fail("D-no-code-exitCode", "expected nil exit code, got \(String(describing: received[0].0))")
}
received.removeAll()

// 7. Unknown bytes (B, other) are silently ignored
ShellIntegration.handle(data: asBytes("C"), state: state)
ShellIntegration.handle(data: asBytes("B"), state: state)  // output start — ignore
if !received.isEmpty {
    fail("unknown-byte", "B should be silently ignored")
}
// The C is still pending — deliver D to clean up
ShellIntegration.handle(data: asBytes("D;0"), state: state)
received.removeAll()

// ── parseOsc7Directory ────────────────────────────────────────────────────────

// Basic file://localhost path
let basic = ShellIntegration.parseOsc7Directory("file://localhost/Users/test")
if basic != "/Users/test" {
    fail("osc7-basic", "expected /Users/test, got \(String(describing: basic))")
}

// Percent-encoded path (UTF-8 multibyte: é = %C3%A9)
let encoded = ShellIntegration.parseOsc7Directory("file://localhost/Users/test/caf%C3%A9")
if encoded != "/Users/test/café" {
    fail("osc7-percent-encoded", "expected /Users/test/café, got \(String(describing: encoded))")
}

// Path with spaces (%20)
let spaces = ShellIntegration.parseOsc7Directory("file://localhost/Users/test/my%20dir")
if spaces != "/Users/test/my dir" {
    fail("osc7-spaces", "expected /Users/test/my dir, got \(String(describing: spaces))")
}

// Bare absolute path (no scheme) — passthrough
let bare = ShellIntegration.parseOsc7Directory("/Users/test")
if bare != "/Users/test" {
    fail("osc7-bare-path", "expected /Users/test, got \(String(describing: bare))")
}

// Relative path → nil (not a valid working directory)
let relative = ShellIntegration.parseOsc7Directory("Users/test")
if relative != nil {
    fail("osc7-relative-path", "expected nil for relative path, got \(String(describing: relative))")
}

// Empty string → nil
let empty = ShellIntegration.parseOsc7Directory("")
if empty != nil {
    fail("osc7-empty", "expected nil for empty input, got \(String(describing: empty))")
}

// Invalid URL → nil
let invalid = ShellIntegration.parseOsc7Directory("file://\u{00}/bad")
if invalid != nil {
    fail("osc7-invalid", "expected nil for invalid URL, got \(String(describing: invalid))")
}

// ── FALSIFICATION PIN ─────────────────────────────────────────────────────────
// Remove the `guard let start = state.commandStartTime` guard in handle() and
// this pin must turn red: D before any C would then fire the callback.
let falseState = ShellIntegration.State { _, _ in }
// If the guard is missing, this D would reach the callback — measure by counting
// calls: falseState has its own callback, so we cannot share `received`.
var falseCalled = 0
let falseState2 = ShellIntegration.State { _, _ in falseCalled += 1 }
ShellIntegration.handle(data: asBytes("D;0"), state: falseState2)
if falseCalled != 0 {
    fail("falsification-pin", "guard removed? D before C fired the callback")
}

// ── Summary ──────────────────────────────────────────────────────────────────
if bad == 0 {
    print("  ok  parseExitCode: D/D;0/D;1/D;127/D;-1/D;130/D;0;extra/D;abc/D;")
    print("  ok  state machine: D-before-C ignored, A resets (start-time cleared), C→D delivers")
    print("  ok  state machine: nil exit code on bare D, non-zero exit codes")
    print("  ok  state machine: second D without C ignored (idle reset)")
    print("  ok  unknown bytes (B) silently ignored")
    print("  ok  parseOsc7Directory: basic file:// path, percent-encoded UTF-8, spaces, bare path, relative→nil, empty→nil, invalid→nil")
    print("  ok  falsification pin: D-before-C guard confirmed load-bearing")
    print("\nall shell-integration cases passed")
} else {
    print("\n\(bad) shell-integration case(s) FAILED")
}
exit(bad == 0 ? 0 : 1)
SWIFT

if ! swiftc -o "$TMP/si_check" "$TMP/ShellIntegration.swift" "$TMP/main.swift" 2>"$TMP/compile.log"; then
    echo "error: the harness would not compile — the gate cannot run." >&2
    echo "  If this names AppKit or SwiftTerm, ShellIntegration.swift has stopped being" >&2
    echo "  Foundation-only and THAT is the regression: the parser must compile headless." >&2
    grep -E 'error:' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
fi

out="$("$TMP/si_check" 2>&1)"; status=$?
say "$out"
exit $status
