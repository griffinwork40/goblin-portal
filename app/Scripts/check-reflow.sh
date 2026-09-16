#!/bin/bash
#
# Assert buffer reflow does not mangle SCROLLBACK when the window is narrowed.
#
# This is the gate for SwiftTerm issue #494 and for the local fix
# patches/swiftterm/0002-index-iswrapped-buffer-absolute.patch, which changes
# Buffer.swift:1171 and :1211 from the screen-relative `_lines[_y].isWrapped` to
# the buffer-absolute `_lines[_y + _yBase].isWrapped`. Same technique as
# check-keybindings.sh and check-space-restore.sh: no test target exists, so
# compile a throwaway harness against the SHIPPED vendored SwiftTerm and run a
# truth table. The unit under test is the vendored emulator itself, which is why
# this script links .build/out/Products/Debug/SwiftTerm.o rather than any file
# from Sources/GoblinPortal.
#
# WHY THIS SCRIPT IS SHAPED THE WAY IT IS
# A previous gate (spike/Tests/SpikeGatesTests/ReflowGateTests.swift, deleted at
# 1e84dd0) claimed to cover #494 and was blind three separate ways. Each of its
# mistakes is inverted below, deliberately:
#
#   1. It never produced the state the defect needs. The buggy line sits in the
#      `else` of `if _y >= _scrollBottom` (Buffer.swift:1167, :1205), so it only
#      runs when the cursor is ABOVE the last row. Feeding "line\r\n" repeatedly
#      pins the cursor to the bottom row, where wrapping goes through
#      `scroll(true)` instead and the buggy line never executes at all. So its
#      `rows: 10, scrollback: 500` case could not express the bug even in
#      principle: `_yBase > 0` and the faulty branch were mutually exclusive
#      under that input. Verified — the old shape still passes UNPATCHED.
#      Every case here therefore seeds scrollback first, then uses absolute CUP
#      to put the cursor mid-screen before writing the wrapping line.
#   2. Its read-back was on-screen only: `terminal.getLine(row:)` returns nil for
#      `row >= rows` (Terminal.swift:759) and indexes `row + buffer.yDisp`
#      (:762), so it could never see the scrollback region where the corruption
#      lands. This uses `getBufferAsData(kind: .normal)` (Terminal.swift:5947),
#      whose loop is `for row in 0..<b.lines.count` (:5953) — the WHOLE buffer,
#      scrollback included. It is public; no @testable needed.
#   3. It asserted only that tokens were not DUPLICATED, never that they were not
#      MISSING. Both are asserted here, plus two stronger properties (below).
#
# WHAT IS ASSERTED, AND WHY IT IS THE RIGHT PROPERTY
# Token counts alone are NOT sufficient: the observed corruption keeps every
# token exactly once and still wrecks history. Narrowing 80->40 with 20 seeded
# lines and the cursor CUP'd to row 5 produces, pre-patch, a blank row spliced
# into the middle of scrollback (row 5 becomes empty and every later line shifts
# down by one). So the load-bearing assertion is the INTERIOR HOLE check: no
# blank row may appear before the last non-blank row. The hole index equals the
# screen-relative `_y` the buggy flag wrote to, which is the defect's signature.
#
# On "missing tokens": a token vanishing is only unambiguous corruption when the
# reflowed content cannot have overflowed the scrollback cap. Grid search found
# 24 apparent "missing" hits that were all legitimate trimming (72 lines x 79
# cols reflowed to 10 cols is ~576 rows against a 500-line cap; the same input at
# scrollback 8000 loses nothing). That confound is what the old test cited as its
# excuse for dropping the assertion. The fix is not to drop it: every case here
# sizes scrollback with headroom, and the harness ASSERTS that headroom as a
# precondition (exit 2, environment) so a future edit that starves scrollback
# reports itself instead of masquerading as corruption.
#
# Usage:
#   ./Scripts/check-reflow.sh            # build if needed, run the truth table
#   ./Scripts/check-reflow.sh --quiet    # only the summary line and failures
#
# Exit codes (mirrors verify-vendor.sh / check-keys-e2e.sh: environment failure
# must never be confusable with an assertion failure):
#   0  every case passed
#   1  a real ASSERTION failure — reflow corrupted the buffer
#   2  ENVIRONMENT failure: vendor/ missing, no toolchain, harness would not
#      compile, or a case's own capacity precondition did not hold
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

# The harness links the compiled vendored module, so SwiftTerm must be built.
#
# ALWAYS build — never skip on "the .o already exists". That guard was this
# script's own first bug, and it was the exact silent-failure shape the vendor
# pin exists to kill: `.build` is warm in every real working copy, so the gate
# linked whatever was compiled LAST rather than the vendor tree under test. A
# re-vendored SwiftTerm missing patch 0002 therefore passed 8/8 against a stale
# patched object file. SwiftPM is incremental (~1.6s no-op here), so building
# unconditionally costs nothing and is the only way the gate's subject is the
# tree on disk. Verified by reverting 0002 and re-running with no manual build:
# 6 of 8 cases fail, as they must.
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
var preconditionFailures = 0

/// The WHOLE normal buffer as rows, scrollback included.
///
/// `getBufferAsData` is public (Terminal.swift:5947) and its loop runs
/// `for row in 0..<b.lines.count` (Terminal.swift:5953), so unlike
/// `getLine(row:)` — capped at `row >= rows` (Terminal.swift:759) and offset by
/// `buffer.yDisp` (:762) — it reaches the scrollback region where #494 corrupts.
/// Trailing blank rows are dropped: the buffer is allocated to a row count, so
/// blanks at the END are normal padding. Blanks in the MIDDLE are not.
func bufferRows(_ t: Terminal) -> [String] {
    let s = String(data: t.getBufferAsData(kind: .normal), encoding: .utf8) ?? ""
    var rows = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while let last = rows.last, last.isEmpty { rows.removeLast() }
    return rows
}

/// Every `Tnnnn` marker in order of appearance. Order matters: a transcript whose
/// tokens are all present but reordered is still mangled history.
func tokens(in text: String) -> [String] {
    let re = try! NSRegularExpression(pattern: "T[0-9]{4}")
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
}

/// Blank rows BEFORE the last non-blank row — a hole punched into the middle of
/// history. This is the signature of the #494 defect: the falsely-flagged line is
/// joined to its neighbour and re-split, leaving an empty row at the index the
/// screen-relative `_y` addressed instead of `_y + _yBase`.
func interiorHoles(_ rows: [String]) -> [Int] {
    guard let last = rows.lastIndex(where: { !$0.isEmpty }) else { return [] }
    return (0..<last).filter { rows[$0].isEmpty }
}

/// Rows carrying two different tokens — two unrelated lines were joined into one.
func mergedRows(_ rows: [String]) -> [Int] {
    rows.indices.filter { tokens(in: rows[$0]).count > 1 }
}

struct Case {
    let label: String
    let cols: Int, rows: Int, scrollback: Int
    let seedLines: Int, seedLen: Int
    let cursorRow: Int          // 1-based CUP target, must be < rows to hit the bug
    let longLen: Int            // length of the wrapping write; must exceed cols
    let newCols: Int
}

func run(_ c: Case) {
    let h = HeadlessTerminal(
        options: TerminalOptions(cols: c.cols, rows: c.rows, scrollback: c.scrollback)
    ) { _ in }
    guard let t = h.terminal else {
        print("  \(c.label): could not construct terminal")
        preconditionFailures += 1
        return
    }

    // 1. Seed MORE lines than `rows` so content scrolls off and _yBase > 0.
    //    Without this the defect is structurally inexpressible.
    for i in 1...c.seedLines {
        let tok = String(format: "T%04d", i)
        t.feed(text: tok + String(repeating: "s", count: max(0, c.seedLen - tok.count)) + "\r\n")
    }

    // 2. Absolute CUP to a row ABOVE the last one, so the wrapping write takes the
    //    `else` branch at Buffer.swift:1167/:1205 (the buggy one) rather than
    //    scroll(true). This is the step the old gate never performed.
    t.feed(text: "\u{1b}[\(c.cursorRow);1H")

    // 3. A uniquely-tokenized line longer than cols, so it wraps and the
    //    isWrapped flag is actually set.
    t.feed(text: "T9999" + String(repeating: "w", count: max(0, c.longLen - 5)))

    let before = bufferRows(t)
    let beforeTokens = tokens(in: before.joined(separator: "\n"))

    // Capacity precondition: if the reflowed height could exceed the scrollback
    // cap, legitimate trimming can drop tokens and "missing" stops being
    // evidence of corruption. Assert the headroom instead of silently dropping
    // the assertion the way the old gate did.
    let worstCaseRows = before.count * ((c.cols / c.newCols) + 2)
    let capacityOK = worstCaseRows <= c.scrollback
    if !capacityOK {
        print("  ✗ \(c.label): PRECONDITION — scrollback \(c.scrollback) < worst-case "
            + "reflowed height \(worstCaseRows); raise scrollback for this case")
        preconditionFailures += 1
        return
    }
    // Sanity: the wrapping write must actually have wrapped, or the case proves nothing.
    guard c.longLen > c.cols, c.cursorRow < c.rows else {
        print("  ✗ \(c.label): PRECONDITION — case cannot reach the defect "
            + "(longLen \(c.longLen) <= cols \(c.cols), or cursorRow \(c.cursorRow) >= rows \(c.rows))")
        preconditionFailures += 1
        return
    }

    // 4. Narrow.
    t.resize(cols: c.newCols, rows: c.rows)

    let after = bufferRows(t)
    let afterTokens = tokens(in: after.joined(separator: "\n"))

    var counts: [String: Int] = [:]
    for tok in afterTokens { counts[tok, default: 0] += 1 }

    // Every token emitted must survive EXACTLY once: not duplicated, and — the
    // half the old gate omitted — not missing.
    let missing = beforeTokens.filter { (counts[$0] ?? 0) == 0 }
    let duplicated = counts.filter { $0.value > 1 }.keys.sorted()
    let holes = interiorHoles(after)
    let merged = mergedRows(after)
    let reordered = beforeTokens != afterTokens

    let ok = missing.isEmpty && duplicated.isEmpty && holes.isEmpty
        && merged.isEmpty && !reordered
    if !ok { failures += 1 }

    print("\(ok ? "  ✓" : "  ✗") \(c.label.padding(toLength: 26, withPad: " ", startingAt: 0))"
        + "missing \(String(missing.count).padding(toLength: 4, withPad: " ", startingAt: 0))"
        + "dup \(String(duplicated.count).padding(toLength: 4, withPad: " ", startingAt: 0))"
        + "holes \(String(holes.count).padding(toLength: 4, withPad: " ", startingAt: 0))"
        + "merged \(String(merged.count).padding(toLength: 4, withPad: " ", startingAt: 0))"
        + "reordered \(reordered)")

    if !ok {
        print("      FAIL \(c.label): reflow \(c.cols)->\(c.newCols) cols corrupted the buffer")
        if !missing.isEmpty {
            print("        MISSING tokens (present before narrowing, gone after): \(missing.prefix(10))")
            print("        scrollback \(c.scrollback) had headroom for \(worstCaseRows) rows, so this is not trimming")
        }
        if !duplicated.isEmpty {
            print("        DUPLICATED tokens: \(duplicated.prefix(10))")
        }
        if !holes.isEmpty {
            print("        INTERIOR BLANK ROWS at \(holes.prefix(10)) — a hole punched into scrollback;")
            print("        history below the hole is shifted. Row \(holes[0]) was:")
            let wasIdx = holes[0]
            if wasIdx < before.count {
                print("          before: |\(before[wasIdx])|")
            }
            print("          after : |\(after[wasIdx])|")
        }
        if !merged.isEmpty {
            print("        MERGED rows at \(merged.prefix(10)) — two unrelated lines joined:")
            for i in merged.prefix(3) { print("          row \(i): |\(after[i])|") }
        }
        if reordered {
            print("        TOKEN ORDER changed — history was rearranged")
        }
    }
}

// Each case seeds > rows lines (so _yBase > 0), CUPs above the last row (so the
// faulty branch runs), writes a line longer than cols (so it wraps), then
// narrows. Scrollback is sized with headroom so trimming cannot confound.
let cases: [Case] = [
    // The canonical repro: pre-patch this splices a blank row in at index 5.
    Case(label: "80->40 mid-screen CUP", cols: 80, rows: 10, scrollback: 5000,
         seedLines: 20, seedLen: 8, cursorRow: 5, longLen: 100, newCols: 40),
    // Halving twice as far — pre-patch yields 3 holes, so the damage scales.
    Case(label: "80->20 mid-screen CUP", cols: 80, rows: 10, scrollback: 5000,
         seedLines: 20, seedLen: 8, cursorRow: 5, longLen: 100, newCols: 20),
    // The cursor near the TOP of the screen: a different _y, same defect.
    Case(label: "80->40 cursor row 2", cols: 80, rows: 10, scrollback: 5000,
         seedLines: 20, seedLen: 8, cursorRow: 2, longLen: 100, newCols: 40),
    // Cursor on the last addressable row above scrollBottom.
    Case(label: "80->40 cursor row 9", cols: 80, rows: 10, scrollback: 5000,
         seedLines: 20, seedLen: 8, cursorRow: 9, longLen: 100, newCols: 40),
    // A taller screen and a longer wrapping run — 2 holes pre-patch.
    Case(label: "80->40 rows 24", cols: 80, rows: 24, scrollback: 5000,
         seedLines: 40, seedLen: 8, cursorRow: 12, longLen: 200, newCols: 40),
    // Seed lines that themselves nearly fill the width, so seeded rows are
    // re-wrapped too and the wrapped-flag bookkeeping is exercised end to end.
    Case(label: "80->20 wide seeds", cols: 80, rows: 10, scrollback: 5000,
         seedLines: 30, seedLen: 40, cursorRow: 4, longLen: 160, newCols: 20),
    // Small geometry: guards against the assertions only holding at 80 cols.
    Case(label: "40->20 rows 6", cols: 40, rows: 6, scrollback: 5000,
         seedLines: 12, seedLen: 30, cursorRow: 3, longLen: 60, newCols: 20),
    Case(label: "20->10 rows 5", cols: 20, rows: 5, scrollback: 5000,
         seedLines: 8, seedLen: 18, cursorRow: 2, longLen: 30, newCols: 10),
]

print("reflow gate — SwiftTerm #494, full normal buffer incl. scrollback")
print("")
for c in cases { run(c) }
print("")

if preconditionFailures > 0 {
    print("\(preconditionFailures) case(s) could not run — ENVIRONMENT/PRECONDITION failure")
    exit(2)
}
print(failures == 0
    ? "all \(cases.count) reflow cases passed"
    : "\(failures) of \(cases.count) reflow case(s) FAILED — scrollback is being corrupted")
exit(failures == 0 ? 0 : 1)
SWIFT

if ! swiftc -O -o "$TMP/reflowcheck" "$TMP/main.swift" \
  -I "$PRODUCTS" -L "$PRODUCTS" "$PRODUCTS/SwiftTerm.o" \
  -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the reflow harness did not compile — treating as environment failure," >&2
  echo "       not as a passing gate. SwiftTerm's API may have moved." >&2
  sed 's/^/  /' "$TMP/compile.log" >&2
  exit 2
fi

if [[ "$QUIET" == "1" ]]; then
  # Keep failures and the summary; drop the per-case ✓ rows.
  "$TMP/reflowcheck" | grep -v '^  ✓'
else
  "$TMP/reflowcheck"
fi
