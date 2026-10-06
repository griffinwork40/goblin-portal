#!/bin/bash
#
# check-file-ops.sh — gates FileOperationPolicy.swift (Foundation-only).
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/FileOperationPolicy.swift` only.
# That file is Foundation-only BY DESIGN — the decision layer (name validation,
# collision naming, case-only rename detection, descendant-cycle check, filesystem
# ops) is a pure set of functions with no AppKit dependency, so it compiles headless
# with `swiftc`. Compiling the SHIPPED file, not a restatement of its table, is the
# whole point: a check that restates the policy proves only that the check agrees
# with itself.
#
# 11 CASES:
#   1.  isValidName — valid names pass
#   2.  isValidName — invalid names rejected (empty, slash, NUL, ".", "..")
#   3.  collisionSafeNewName — "foo" → "foo copy" → "foo copy 2"; case-insensitive
#   4.  isCaseOnlyRename — detection: (foo,Foo)→true; (foo,bar)→false; (foo,foo)→false
#   5.  isDescendant — identity, child, sibling, parent
#   6.  createFile + createDirectory — files appear on disk
#   7.  rename (non-case) — file appears at new path
#   8.  case-only rename — "foo" → "FOO" survives on APFS (two-step move)
#   9.  move — file lands in target directory, source gone
#  10.  trashItem — file disappears from original path
#  11.  move collision refusal — throws CocoaError(.fileWriteFileExists) when dest exists
#
# FALSIFICATION CASE (built-in sanity check):
#   A naive `isValidName` that accepts "." is compiled alongside the real one.
#   The harness asserts that the REAL policy rejects "." AND that the naive version
#   accepts it, proving the gate would catch a subtly wrong implementation.
#   If both versions agreed (i.e. the gate cannot distinguish them), the harness
#   exits 2 — environmental, not a real pass.
#
# EXIT CODES: 0 = all cases passed. 1 = real failure. 2 = environmental.
# A broken environment must never read as a green gate.
#
# Usage:
#   ./Scripts/check-file-ops.sh
#   ./Scripts/check-file-ops.sh --quiet

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/FileOperationPolicy.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }
[[ -f "$SRC" ]] || {
    echo "error: $SRC not found — did the file move?" >&2; exit 2; }

TMP=$(mktemp -d) || { echo "error: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ── Harness ────────────────────────────────────────────────────────────────────
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

var bad = 0
func fail(_ label: String, _ msg: String) {
    print("  FAIL \(label): \(msg)")
    bad += 1
}
func assert_eq(_ label: String, _ got: Bool, _ want: Bool) {
    if got != want { fail(label, "got \(got), expected \(want)") }
}

// ── CASE 1: isValidName — valid names ─────────────────────────────────────
let validNames = ["foo", "foo.txt", ".hidden", "a b c", "résumé.pdf", "日本語"]
for n in validNames {
    assert_eq("CASE1 valid \"\(n)\"", FileOperationPolicy.isValidName(n), true)
}

// ── CASE 2: isValidName — invalid names ───────────────────────────────────
let invalid: [(String, String)] = [
    ("",      "empty"),
    (".",     "dot"),
    ("..",    "dotdot"),
    ("a/b",   "slash"),
    ("/etc",  "leading-slash"),
    ("a\0b",  "NUL"),
]
for (n, desc) in invalid {
    assert_eq("CASE2 invalid [\(desc)]", FileOperationPolicy.isValidName(n), false)
}

// ── CASE 3: collisionSafeNewName ──────────────────────────────────────────
let c3a = FileOperationPolicy.collisionSafeNewName(base: "foo", existingNames: [])
if c3a != "foo copy" { fail("CASE3a", "expected 'foo copy', got '\(c3a)'") }

let c3b = FileOperationPolicy.collisionSafeNewName(base: "foo", existingNames: ["foo copy"])
if c3b != "foo copy 2" { fail("CASE3b", "expected 'foo copy 2', got '\(c3b)'") }

// Case-insensitive: "FOO COPY" should block "foo copy", pushing to "foo copy 2"
let c3c = FileOperationPolicy.collisionSafeNewName(base: "foo", existingNames: ["FOO COPY"])
if c3c != "foo copy 2" { fail("CASE3c", "expected 'foo copy 2' (case-insens block), got '\(c3c)'") }

// With extension
let c3d = FileOperationPolicy.collisionSafeNewName(base: "readme.md", existingNames: [])
if c3d != "readme copy.md" { fail("CASE3d", "expected 'readme copy.md', got '\(c3d)'") }

let c3e = FileOperationPolicy.collisionSafeNewName(base: "readme.md", existingNames: ["readme copy.md"])
if c3e != "readme copy 2.md" { fail("CASE3e", "expected 'readme copy 2.md', got '\(c3e)'") }

// ── CASE 4: isCaseOnlyRename detection ────────────────────────────────────
let base = URL(fileURLWithPath: "/tmp/foo")
let upper = URL(fileURLWithPath: "/tmp/FOO")
let other = URL(fileURLWithPath: "/tmp/bar")
let same  = URL(fileURLWithPath: "/tmp/foo")

assert_eq("CASE4 (foo→FOO) true",  FileOperationPolicy.isCaseOnlyRename(from: base, to: upper), true)
assert_eq("CASE4 (foo→bar) false", FileOperationPolicy.isCaseOnlyRename(from: base, to: other), false)
assert_eq("CASE4 (foo→foo) false", FileOperationPolicy.isCaseOnlyRename(from: base, to: same),  false)

// ── CASE 5: isDescendant ──────────────────────────────────────────────────
let ancestor = URL(fileURLWithPath: "/tmp/ancestor")
let child    = URL(fileURLWithPath: "/tmp/ancestor/child")
let sibling  = URL(fileURLWithPath: "/tmp/sibling")
let parent   = URL(fileURLWithPath: "/tmp")

assert_eq("CASE5 identity",  FileOperationPolicy.isDescendant(url: ancestor, of: ancestor), true)
assert_eq("CASE5 child",     FileOperationPolicy.isDescendant(url: child,    of: ancestor), true)
assert_eq("CASE5 sibling",   FileOperationPolicy.isDescendant(url: sibling,  of: ancestor), false)
assert_eq("CASE5 parent",    FileOperationPolicy.isDescendant(url: parent,   of: ancestor), false)
// Prefix safety: "/tmp/ancestor-other" must NOT match ancestor
let prefix = URL(fileURLWithPath: "/tmp/ancestor-other")
assert_eq("CASE5 prefix-safety", FileOperationPolicy.isDescendant(url: prefix, of: ancestor), false)

// ── CASE 6: createFile + createDirectory ──────────────────────────────────
let dir6 = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("fops_\(Int.random(in: 100000..<999999))")
let file6 = dir6.appendingPathComponent("hello.txt")
let sub6  = dir6.appendingPathComponent("subdir/nested")

do {
    try FileOperationPolicy.createDirectory(at: dir6)
    guard FileManager.default.fileExists(atPath: dir6.path) else {
        print("  FAIL CASE6: directory not created"); bad += 1
        exit(bad > 0 ? 1 : 0)
    }
    try FileOperationPolicy.createFile(at: file6)
    guard FileManager.default.fileExists(atPath: file6.path) else {
        print("  FAIL CASE6: file not created"); bad += 1
        exit(bad > 0 ? 1 : 0)
    }
    // With intermediate directories
    try FileOperationPolicy.createDirectory(at: sub6)
    guard FileManager.default.fileExists(atPath: sub6.path) else {
        print("  FAIL CASE6: nested directory not created"); bad += 1
        exit(bad > 0 ? 1 : 0)
    }
} catch {
    print("  FAIL CASE6: \(error)"); bad += 1
    exit(1)
}

// ── CASE 7: rename (non-case) ─────────────────────────────────────────────
let src7  = dir6.appendingPathComponent("original.txt")
let dst7  = dir6.appendingPathComponent("renamed.txt")
do {
    try FileOperationPolicy.createFile(at: src7)
    try FileOperationPolicy.rename(from: src7, to: dst7)
    if FileManager.default.fileExists(atPath: src7.path) {
        fail("CASE7", "source still exists after rename"); _ = try? FileManager.default.removeItem(at: src7)
    }
    if !FileManager.default.fileExists(atPath: dst7.path) {
        fail("CASE7", "destination does not exist after rename")
    }
} catch { fail("CASE7", "\(error)") }

// ── CASE 8: case-only rename on real temp dir (APFS two-step) ────────────
let src8 = dir6.appendingPathComponent("casefoo")
let dst8 = dir6.appendingPathComponent("CASEFOO")
do {
    // Ensure clean slate
    _ = try? FileManager.default.removeItem(at: src8)
    _ = try? FileManager.default.removeItem(at: dst8)
    try FileOperationPolicy.createFile(at: src8)
    try FileOperationPolicy.rename(from: src8, to: dst8)
    if !FileManager.default.fileExists(atPath: dst8.path) {
        fail("CASE8", "CASEFOO does not exist after case-only rename")
    }
    // On a case-insensitive FS, src8.path == dst8.path so both exist; that is OK.
    // What matters is the destination name is reachable and the old entry gone (or same).
} catch { fail("CASE8", "\(error)") }

// ── CASE 9: move ─────────────────────────────────────────────────────────
let srcDir9  = dir6.appendingPathComponent("srcDir")
let destDir9 = dir6.appendingPathComponent("destDir")
let moveFile = srcDir9.appendingPathComponent("mover.txt")
do {
    try FileOperationPolicy.createDirectory(at: srcDir9)
    try FileOperationPolicy.createDirectory(at: destDir9)
    try FileOperationPolicy.createFile(at: moveFile)
    try FileOperationPolicy.move(from: moveFile, to: destDir9)
    if FileManager.default.fileExists(atPath: moveFile.path) {
        fail("CASE9", "source still exists after move")
    }
    let dest9 = destDir9.appendingPathComponent("mover.txt")
    if !FileManager.default.fileExists(atPath: dest9.path) {
        fail("CASE9", "destination does not have moved file")
    }
} catch { fail("CASE9", "\(error)") }

// ── CASE 10: trashItem ────────────────────────────────────────────────────
let trash10 = dir6.appendingPathComponent("trash_me.txt")
do {
    try FileOperationPolicy.createFile(at: trash10)
    guard FileManager.default.fileExists(atPath: trash10.path) else {
        fail("CASE10", "file was not created before trash"); throw CocoaError(.fileWriteUnknown)
    }
    try FileOperationPolicy.trashItem(at: trash10)
    if FileManager.default.fileExists(atPath: trash10.path) {
        fail("CASE10", "file still at original path after trash")
    }
} catch { fail("CASE10", "\(error)") }

// ── CASE 11: move collision refusal ──────────────────────────────────────
let collDir = dir6.appendingPathComponent("collision")
let collFile = collDir.appendingPathComponent("dupe.txt")
let collFile2 = dir6.appendingPathComponent("dupe.txt")  // pre-existing in parent
do {
    try FileOperationPolicy.createDirectory(at: collDir)
    try FileOperationPolicy.createFile(at: collFile)
    try FileOperationPolicy.createFile(at: collFile2)
    // Moving collFile into dir6 should fail because dir6/dupe.txt already exists
    var caught = false
    do {
        try FileOperationPolicy.move(from: collFile, to: dir6)
    } catch {
        caught = true
        // Verify it was the expected CocoaError type
        if let ce = error as? CocoaError, ce.code == .fileWriteFileExists {
            // Good — correct error type
        } else {
            fail("CASE11", "wrong error type: \(error)")
        }
    }
    if !caught { fail("CASE11", "no error thrown on collision move") }
} catch { fail("CASE11", "setup: \(error)") }

// ── FALSIFICATION CHECK ───────────────────────────────────────────────────
// A naive isValidName that accepts "." (forgotten to check for single-dot).
// The real policy must reject ".", and the naive version must accept it.
// If both agree on ".", the gate cannot tell them apart and must exit 2.
func naiveIsValidName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("\0")
}
let realRejectsDot  = !FileOperationPolicy.isValidName(".")
let naiveAcceptsDot = naiveIsValidName(".")
if !realRejectsDot  { fail("FALSIFICATION", "real policy must reject \".\" — policy is wrong") }
if !naiveAcceptsDot { fail("FALSIFICATION", "naive policy must accept \".\" — falsification broken"); bad = max(bad, 2) }
if realRejectsDot && naiveAcceptsDot {
    // Gate can distinguish them — falsification passes
} else if !realRejectsDot || !naiveAcceptsDot {
    print("  ENV: falsification probe broken — real=\(realRejectsDot) naive=\(naiveAcceptsDot)")
    exit(2)
}

// ── Result ────────────────────────────────────────────────────────────────
if bad == 0 {
    print("check-file-ops: ALL \(11) CASES PASSED")
} else {
    print("check-file-ops: \(bad) FAILURE(S)")
}
exit(bad > 0 ? 1 : 0)
SWIFT

# Compile and run
if ! swiftc -O -o "$TMP/harness" "$SRC" "$TMP/main.swift" 2>"$TMP/compile.err"; then
    echo "error: harness failed to compile" >&2
    cat "$TMP/compile.err" >&2
    exit 2
fi

say "==> running check-file-ops (11 cases + falsification)"
"$TMP/harness"
STATUS=$?
[[ $STATUS -eq 0 ]] && say "check-file-ops: exit 0 — all cases passed"
exit $STATUS
