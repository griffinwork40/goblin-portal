#!/bin/bash
#
# Assert an ALTERNATE-buffer resize does not resurrect content from a previous,
# wider window size.
#
# This is the gate for patches/swiftterm/0003-trim-lines-on-narrowing-for-all-buffers.patch.
# Same technique as check-reflow.sh: no test target exists, so compile a throwaway
# harness against the SHIPPED vendored SwiftTerm and run a truth table. The unit
# under test is the vendored emulator, which is why this links
# .build/out/Products/Debug/SwiftTerm.o rather than any file from Sources/GoblinPortal.
#
# THE DEFECT (upstream SwiftTerm, not introduced by any local patch — 0002 touches
# neither `resize` nor `isReflowEnabled`)
#   Buffer.swift:419-421  `isReflowEnabled` is nothing but `hasScrollback`.
#   Terminal.swift:694    the alt buffer is built `scrollback: nil`, so that is false.
#   Buffer.swift:522-531  but the loop that trims each line down to the new width sat
#                         INSIDE `if isReflowEnabled`. So narrowing the alt buffer shrank
#                         `cols` while every BufferLine kept its old `dataSize`.
#   AppleTerminalView.swift:887  those cells are invisible while out of range, because the
#                         renderer clamps to `min(terminal.cols-1, line.count-1)`.
#   BufferLine.swift:197  on the next WIDENING, resize() takes its shrink branch and copies
#                         data[0..<cols] verbatim — pulling pre-narrowing cells back into
#                         the visible grid.
#   Ghost band = columns [oldNarrowCols, min(newCols, originalWideCols)) of every row.
#
# WHY IT MATTERS, AND WHY tmux IS THE VICTIM
# tmux lives in the alt buffer and repaints only the deltas its own screen model says
# changed. The emulator mutated cells tmux never wrote, so the two models diverge with no
# event to reconcile them, and a tmux window switch is redrawn from that same stale model.
# Goblin Portal calls terminal.resize on EVERY cols/rows change — processSizeChange
# (AppleTerminalView.swift:233: live window drag, ⌘B sidebar, full screen) and resetFont
# (:151: ⌘+/⌘-/⌘0 zoom, ⌘R reload) — so a day of use deposits several bands, each holding
# text a differently-sized tmux pane layout wrapped at ITS width. Rendered inside today's
# layout that reads as narrow ribbons of wrapped prose sitting in the wrong pane.
# Diagnosis: .afk/research/tmux-bleed-altbuffer-resize-2026-07-29.md
#
# WHY THESE FOUR CASES
# Case 1 observes the defect directly (are the lines still wide?), case 2 is the
# user-visible bug end to end, and both would be worthless without the other two:
#   - Case 3 is the CONTROL. It runs the identical sequence on the NORMAL buffer, where
#     reflow — and therefore the trim — does run. If case 3 ever fails alongside 1 and 2,
#     the harness is measuring something other than the alt-buffer path and its verdict
#     must not be trusted. This is the check the retired ReflowGateTests never had.
#   - Case 4 pins VISIBILITY to the widen step: while narrow, the stale cells must sit
#     outside `cols`. That is what makes "the corruption appears when you make the window
#     BIGGER" a prediction of this model rather than a coincidence.
# Validated by falsification, like check-reflow.sh: reverting 0003 fails cases 1 and 2 and
# still passes 3 and 4, which is the only reason to believe 4 passes mean anything.
#
# Usage:
#   ./Scripts/check-altbuffer-resize.sh            # build if needed, run the truth table
#   ./Scripts/check-altbuffer-resize.sh --quiet    # only the summary line and failures
#
# Exit codes (mirrors check-reflow.sh / verify-vendor.sh: an environment failure must never
# be confusable with an assertion failure):
#   0  every case passed
#   1  a real ASSERTION failure — the alt buffer is resurrecting content across a resize
#   2  ENVIRONMENT failure: vendor/ missing, no toolchain, or the harness would not compile
#
set -euo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"
VENDOR="$REPO_ROOT/vendor/SwiftTerm"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- environment gates, all exit 2 ---------------------------------------------
if [[ ! -d "$VENDOR" ]]; then
  echo "error: vendor/SwiftTerm is missing — nothing to check." >&2
  echo "       See app/README.md (\"Dependency note\") or run ./Scripts/verify-vendor.sh" >&2
  exit 2
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
fi

# ALWAYS build — never skip on "the .o already exists". That guard was check-reflow.sh's
# own first bug: `.build` is warm in every real working copy, so the gate linked whatever
# was compiled LAST rather than the vendor tree under test, and a re-vendored SwiftTerm
# missing the patch passed against a stale patched object file. SwiftPM is incremental, so
# building unconditionally costs ~2s and is the only way the gate's subject is the tree on
# disk.
# Where is the compiled vendored module? That whole concern — including which build
# backend can even produce the merged object this harness links — lives in one place,
# because both vendor gates need it and an identical copy in each is how you ship a
# gate that passes for the wrong reason.
. Scripts/vendored-module.sh
resolve_vendored_module          # sets PRODUCTS, or exits 2

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
import SwiftTerm

// Exit 1 == assertion failure, exit 2 == environment/precondition failure.
var failures = 0
var env = 0

let ROWS = 10
let WIDE = 80      // era 1: the wide window
let NARROW = 40    // era 2: the user narrows it (window drag, ⌘B, or a font zoom)
let BACK = 70      // era 3: the user widens it again — where the ghosts become visible

/// Rows of the requested buffer. `getBufferAsData` is public (Terminal.swift:5947) and its
/// loop runs `for row in 0..<b.lines.count` (:5953), so it reports each line's FULL
/// `dataSize` rather than clamping to `cols` — which is exactly what case 1 needs to see.
/// Trailing blank rows are padding and dropped.
func rows(_ t: Terminal, _ kind: Terminal.BufferKind) -> [String] {
    let s = String(data: t.getBufferAsData(kind: kind), encoding: .utf8) ?? ""
    var r = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while let last = r.last, last.isEmpty { r.removeLast() }
    return r
}

/// Paint every row the way tmux does: absolute CUP, then that row's cells. Never a bare
/// "\r\n" feed — that pins the cursor to the bottom row and takes a different code path.
func paint(_ t: Terminal, _ body: (Int) -> String) {
    for r in 1...ROWS {
        t.feed(text: "\u{1b}[\(r);1H")
        t.feed(text: body(r))
    }
}

/// `alt: true` feeds CSI ?1049h — what tmux does once at startup and then stays in.
func newTerminal(alt: Bool) -> Terminal? {
    let h = HeadlessTerminal(options: TerminalOptions(cols: WIDE, rows: ROWS, scrollback: 1000)) { _ in }
    guard let t = h.terminal else { return nil }
    if alt { t.feed(text: "\u{1b}[?1049h") }
    return t
}

/// Era-1 content: 'A' through column 39, then a unique GHOST marker from column 40 on. The
/// marker sits in the band a narrow(40)+widen(70) cycle resurrects.
func wideEra(_ _r: Int) -> String {
    String(repeating: "A", count: 40) + "GHOST" + String(repeating: "g", count: 35)
}

// ---------------------------------------------------------------- case 1
// DIRECT OBSERVATION: after narrowing, are the alt buffer's lines still WIDE?
func case1() {
    guard let t = newTerminal(alt: true) else { env += 1; return }
    paint(t, wideEra)
    t.resize(cols: NARROW, rows: ROWS)
    let after = rows(t, .alt).filter { !$0.isEmpty }
    let overlong = after.filter { $0.count > NARROW }
    if overlong.isEmpty {
        print("  ✓ case 1  alt-buffer lines trimmed to \(NARROW) cols on narrowing")
    } else {
        failures += 1
        print("  ✗ case 1  \(overlong.count)/\(after.count) alt rows STILL WIDER than cols=\(NARROW)")
        print("            e.g. \(overlong[0].count) chars: \(overlong[0].prefix(90))")
    }
}

// ---------------------------------------------------------------- case 2
// THE USER-VISIBLE BUG: narrow, let tmux fully repaint at the narrow size, then widen.
// Nothing from the WIDE era may reappear — tmux does not know those cells exist.
func case2() {
    guard let t = newTerminal(alt: true) else { env += 1; return }
    paint(t, wideEra)
    t.resize(cols: NARROW, rows: ROWS)
    // tmux gets SIGWINCH and repaints the whole screen at the new width.
    paint(t) { r in String(format: "N%02d", r) + String(repeating: "n", count: NARROW - 3) }
    t.resize(cols: BACK, rows: ROWS)
    // tmux repaints again at the newest width.
    paint(t) { r in String(format: "W%02d", r) + String(repeating: "w", count: NARROW - 3) }

    let after = rows(t, .alt)
    let haunted = after.indices.filter { after[$0].contains("GHOST") }
    if haunted.isEmpty {
        print("  ✓ case 2  no wide-era content resurrected by narrow(\(WIDE)->\(NARROW))+widen(->\(BACK))")
    } else {
        failures += 1
        print("  ✗ case 2  \(haunted.count)/\(after.count) rows resurrected WIDE-era text")
        print("            row \(haunted[0]): \(after[haunted[0]])")
        print("            ^ tmux painted cols 0..<\(NARROW); \(NARROW)..<\(BACK) predate the narrowing")
    }
}

// ---------------------------------------------------------------- case 3
// CONTROL: identical sequence on the NORMAL buffer, where reflow IS enabled and the trim
// therefore runs. Wide-era text legitimately survives in HISTORY there — what must not
// happen is a row wider than cols. If this fails too, the harness is suspect, not the code.
func case3() {
    guard let t = newTerminal(alt: false) else { env += 1; return }
    paint(t, wideEra)
    t.resize(cols: NARROW, rows: ROWS)
    paint(t) { r in String(format: "N%02d", r) + String(repeating: "n", count: NARROW - 3) }
    t.resize(cols: BACK, rows: ROWS)
    paint(t) { r in String(format: "W%02d", r) + String(repeating: "w", count: NARROW - 3) }

    let after = rows(t, .normal)
    let overlong = after.filter { $0.count > BACK }
    let history = after.filter { $0.contains("GHOST") }.count
    if overlong.isEmpty {
        print("  ✓ case 3  (control) no normal-buffer row wider than cols=\(BACK) "
              + "[\(history) history rows still mention GHOST — correct, it has scrollback]")
    } else {
        failures += 1
        print("  ✗ case 3  (control) normal buffer ALSO has \(overlong.count) overlong rows")
        print("            the harness is measuring the wrong thing — do not trust 1 and 2")
    }
}

// ---------------------------------------------------------------- case 4
// Does narrowing ALONE already show it, with no widen? It must not: the stale cells are
// out of render range. This pins visibility to the widen step.
func case4() {
    guard let t = newTerminal(alt: true) else { env += 1; return }
    paint(t, wideEra)
    t.resize(cols: NARROW, rows: ROWS)
    paint(t) { r in String(format: "N%02d", r) + String(repeating: "n", count: NARROW - 3) }
    let visible = rows(t, .alt).map { String($0.prefix(NARROW)) }
    let haunted = visible.filter { $0.contains("GHOST") }
    if haunted.isEmpty {
        print("  ✓ case 4  while narrow, stale cells sit OUTSIDE cols and are not rendered")
    } else {
        failures += 1
        print("  ✗ case 4  stale text is already inside the visible \(NARROW) cols: \(haunted[0])")
    }
}

print("alt-buffer resize gate — cols \(WIDE) -> \(NARROW) -> \(BACK), \(ROWS) rows")
case1(); case2(); case3(); case4()

if env > 0 {
    print("\(env) case(s) could not construct a terminal — environment failure")
    exit(2)
}
print(failures == 0
      ? "all 4 alt-buffer resize cases passed"
      : "\(failures) of 4 case(s) FAILED — the alt buffer resurrects content across a resize")
exit(failures == 0 ? 0 : 1)
SWIFT

if ! swiftc -O -o "$TMP/altcheck" "$TMP/main.swift" \
  -I "$PRODUCTS" -L "$PRODUCTS" "$PRODUCTS/SwiftTerm.o" \
  -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the alt-buffer harness did not compile — treating as environment failure," >&2
  echo "       not as a passing gate. SwiftTerm's API may have moved." >&2
  sed 's/^/  /' "$TMP/compile.log" >&2
  exit 2
fi

if [[ "$QUIET" == "1" ]]; then
  # Keep failures and the summary; drop the per-case ✓ rows.
  "$TMP/altcheck" | grep -v '^  ✓'
else
  "$TMP/altcheck"
fi
