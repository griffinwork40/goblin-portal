#!/bin/bash
#
# Does a finished shell command mark its tab correctly? Asserts the OSC 133 status policy.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/CommandOutcome.swift` only. That file is Foundation-only BY
# DESIGN — the *decision* (what a finished command means for its tab) is a pure function of exit
# code, duration and whether the user is looking, and a pure function compiles headless with
# swiftc: no NSView, no window server, no shell, no `swift build`. Same trick
# check-renderer-config.sh plays on Renderer.swift, check-engine-config.sh on TerminalEngine.swift,
# check-cursor-style.sh on CursorStyle.swift, check-cwd-follow.sh on ShellDirectory.swift.
# Compiling the SHIPPED file, not a restatement of its table, is the whole point: a check that
# restates the policy proves only that the check agrees with itself.
#
# WHY IT EXISTS. This policy is the kind that fails silently and in the annoying direction. Get it
# slightly wrong and a status dot appears after every `ls` — at which point the user stops seeing
# dots, and `.failed`, the one that matters, is lost with them. The failure has no crash, no
# warning and no visual glitch; it just quietly makes the feature worthless. `DocumentStatus` had
# `.running`/`.succeeded`/`.failed` sitting unwired for months precisely because nobody wanted to
# guess this policy, so the guess deserves an instrument.
#
# WHAT IT CANNOT REACH, stated rather than implied. Whether the dot is legible, whether
# `documentDidBecomeActive()` really clears it, and whether libghostty's OSC 133 delegate fires
# when this policy assumes it does — all AppKit or live-shell territory. `check-ghostty-pane.sh`
# and daily use own those. This owns the mapping.
#
# EXIT CODES: 0 = all cases passed. 1 = a REAL failure (an outcome mapped wrongly, or the
# threshold moved). 2 = environmental (no toolchain, source file missing, harness would not
# compile). A broken environment must never read as a green gate.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/CommandOutcome.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }
[[ -f "$SRC" ]] || {
  echo "error: $SRC not found — did the file move? This gate names its subject explicitly." >&2
  exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$SRC" "$TMP/CommandOutcome.swift"

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

var bad = 0
func expect(_ label: String, _ actual: CommandOutcome, _ wanted: CommandOutcome) {
    if actual == wanted { return }
    print("  FAIL \(label): got \(actual), expected \(wanted)")
    bad += 1
}

// Durations in nanoseconds, named so the cases read as intent rather than arithmetic.
let instant: UInt64 = 40_000_000            // 40ms — a typo, or a cache hit
let brief: UInt64 = 2_000_000_000           // 2s — still watching
let justUnder: UInt64 = 9_900_000_000       // 9.9s — the near side of the boundary
let atThreshold: UInt64 = 10_000_000_000    // exactly 10s — inclusive per `>=`
let long: UInt64 = 240_000_000_000          // 4 minutes — you walked away

// --- 1. The active-document guard wins over everything. -----------------------------------
// It is checked first in `of(...)`, so even a hard failure on the tab you are reading must be
// ignored. If this regresses, every command you run paints a dot on the tab in front of you.
expect("active + failure", .of(exitCode: 1, durationNanos: instant, isActiveDocument: true), .ignore)
expect("active + long success", .of(exitCode: 0, durationNanos: long, isActiveDocument: true), .ignore)
expect("active + nil exit", .of(exitCode: nil, durationNanos: long, isActiveDocument: true), .ignore)

// --- 2. Failure marks the tab regardless of duration. -------------------------------------
// The asymmetry against success is deliberate: failure is rare and interesting.
expect("bg + exit 1 instant", .of(exitCode: 1, durationNanos: instant, isActiveDocument: false), .failed)
expect("bg + exit 1 long", .of(exitCode: 1, durationNanos: long, isActiveDocument: false), .failed)
expect("bg + exit 127", .of(exitCode: 127, durationNanos: brief, isActiveDocument: false), .failed)
expect("bg + exit 130 (SIGINT)", .of(exitCode: 130, durationNanos: brief, isActiveDocument: false), .failed)
expect("bg + negative exit", .of(exitCode: -1, durationNanos: instant, isActiveDocument: false), .failed)

// --- 3. A missing exit code is NOT a failure. ---------------------------------------------
// An OSC 133 `D` can arrive without a status; guessing "failed" would paint red on a tab whose
// command may well have succeeded.
expect("bg + nil exit, instant", .of(exitCode: nil, durationNanos: instant, isActiveDocument: false), .ignore)
expect("bg + nil exit, long", .of(exitCode: nil, durationNanos: long, isActiveDocument: false), .ignore)

// --- 4. Success is marked only when it ran long enough. -----------------------------------
expect("bg + fast success", .of(exitCode: 0, durationNanos: instant, isActiveDocument: false), .ignore)
expect("bg + brief success", .of(exitCode: 0, durationNanos: brief, isActiveDocument: false), .ignore)
expect("bg + success just under threshold", .of(exitCode: 0, durationNanos: justUnder, isActiveDocument: false), .ignore)
expect("bg + success AT threshold (>= is inclusive)", .of(exitCode: 0, durationNanos: atThreshold, isActiveDocument: false), .succeeded)
expect("bg + long success", .of(exitCode: 0, durationNanos: long, isActiveDocument: false), .succeeded)
expect("bg + zero duration success", .of(exitCode: 0, durationNanos: 0, isActiveDocument: false), .ignore)

// --- 5. The threshold itself, pinned. -----------------------------------------------------
// Asserted directly so that MOVING it is a deliberate act that updates this line, rather than a
// silent behaviour change hidden behind cases that happen to still pass.
if CommandOutcome.longRunningThreshold != 10 {
    print("  FAIL threshold moved: \(CommandOutcome.longRunningThreshold)s, expected 10s — if that "
          + "was deliberate, update this case and the boundary cases above with it")
    bad += 1
}

// --- 6. FALSIFICATION PIN. ----------------------------------------------------------------
// This gate must be capable of failing. To re-verify it is not vacuous, invert the comparison in
// `CommandOutcome.of` (`>=` to `<`) or drop the `isActiveDocument` guard: either edit must turn
// this run red. Verified by doing exactly that during authoring: dropping the `isActiveDocument`
// guard failed exactly 2 cases — "active + failure" and "active + long success", but NOT
// "active + nil exit", which returns `.ignore` via the missing-exit-code branch anyway. That
// asymmetry is worth knowing: a guard-removal regression is only visible on inputs that would
// otherwise have marked the tab, so those two cases are the ones carrying the guard.
if CommandOutcome.of(exitCode: 0, durationNanos: long, isActiveDocument: false) == .ignore {
    print("  FAIL falsification pin: a 4-minute success on a background tab must NOT be ignored")
    bad += 1
}

if bad == 0 {
    print("  ok  active-tab guard beats every other input")
    print("  ok  any nonzero exit marks the tab; a missing exit code never does")
    print("  ok  success marks only at or past the 10s threshold, boundary inclusive")
    print("  ok  falsification pin holds; threshold is still 10s")
    print("\nall command-outcome cases passed (17 mappings + threshold pin + falsification pin)")
} else {
    print("\n\(bad) command-outcome case(s) FAILED")
}
exit(bad == 0 ? 0 : 1)
SWIFT

if ! swiftc -o "$TMP/outcome" "$TMP/CommandOutcome.swift" "$TMP/main.swift" 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  echo "  If this names AppKit or NSColor, CommandOutcome.swift has stopped being Foundation-only" >&2
  echo "  and THAT is the regression: the policy must stay compilable without a view." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

out="$("$TMP/outcome" 2>&1)"; status=$?
say "$out"
# The exit code is the verdict, not a stdout substring — see check-ghostty-pane.sh's header for
# the run where that distinction mattered.
exit $status
