//
//  check-file-ops-harness.swift
//  The assertions for `check-file-ops.sh`, compiled against FileOperationPolicy.swift.
//
//  A separate file, not a heredoc, for two reasons: the driver plus 15 cases would
//  cross the 350-line ceiling, and the driver compiles this SAME file twice — once
//  against the shipped policy and once against a sed-mutated copy that must fail —
//  which is only clean when the harness is a file both builds can name.
//
//  Exit 0 = all cases passed, 1 = an assertion failed. Anything else is a crash,
//  which the driver maps to 2 (environmental).
//

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

// ── CASE 8: case-only rename on real temp dir — the EXACT new case on disk ──
// `fileExists` proves nothing here: on a case-insensitive volume it is true for
// "CASEFOO" while only "casefoo" exists. Only the directory listing shows case.
let src8 = dir6.appendingPathComponent("casefoo")
let dst8 = dir6.appendingPathComponent("CASEFOO")
do {
    try FileOperationPolicy.createFile(at: src8)
    try FileOperationPolicy.rename(from: src8, to: dst8)
    let names8 = (try? FileManager.default.contentsOfDirectory(atPath: dir6.path)) ?? []
    if !names8.contains("CASEFOO") { fail("CASE8", "listing lacks exact 'CASEFOO': \(names8)") }
    if names8.contains("casefoo")  { fail("CASE8", "old spelling 'casefoo' still listed") }
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

// ── CASE 12: paste keeps the name when it is free (M1) ────────────────────
let pasteSrc = dir6.appendingPathComponent("p_src"), pasteDst = dir6.appendingPathComponent("p_dst")
do {
    try FileOperationPolicy.createDirectory(at: pasteSrc)
    try FileOperationPolicy.createDirectory(at: pasteDst)
    let f = pasteSrc.appendingPathComponent("keep.txt")
    try FileOperationPolicy.createFile(at: f)
    let out = try FileOperationPolicy.copy(from: f, into: pasteDst)
    if out.lastPathComponent != "keep.txt" { fail("CASE12", "pasted as '\(out.lastPathComponent)', expected 'keep.txt'") }
    if FileOperationPolicy.availableName(base: "untitled", existingNames: ["x"]) != "untitled" {
        fail("CASE12", "availableName suffixed a free name")
    }
    if FileOperationPolicy.availableName(base: "a.txt", existingNames: ["A.TXT"]) != "a copy.txt" {
        fail("CASE12", "availableName ignored a case-insensitive clash")
    }
    // Pasting the same file again must suffix, not overwrite.
    let again = try FileOperationPolicy.copy(from: f, into: pasteDst)
    if again.lastPathComponent != "keep copy.txt" { fail("CASE12", "second paste got '\(again.lastPathComponent)'") }
} catch { fail("CASE12", "\(error)") }

// ── CASE 13: duplicate ALWAYS suffixes, even when the name is free elsewhere ──
do {
    let f = pasteSrc.appendingPathComponent("dup.txt")
    try FileOperationPolicy.createFile(at: f)
    let d1 = try FileOperationPolicy.copy(from: f, into: pasteSrc, alwaysSuffix: true)
    let d2 = try FileOperationPolicy.copy(from: f, into: pasteSrc, alwaysSuffix: true)
    if d1.lastPathComponent != "dup copy.txt"   { fail("CASE13", "first duplicate '\(d1.lastPathComponent)'") }
    if d2.lastPathComponent != "dup copy 2.txt" { fail("CASE13", "second duplicate '\(d2.lastPathComponent)'") }
} catch { fail("CASE13", "\(error)") }

// ── CASE 14: collisions never overwrite — original content intact ─────────
let col = dir6.appendingPathComponent("col")
do {
    try FileOperationPolicy.createDirectory(at: col)
    let keep = col.appendingPathComponent("Keep.txt"), other = col.appendingPathComponent("other.txt")
    try Data("ORIGINAL".utf8).write(to: keep)
    try Data("INTRUDER".utf8).write(to: other)
    var threw = 0
    do { try FileOperationPolicy.rename(from: other, to: col.appendingPathComponent("keep.txt")) } catch { threw += 1 }
    do { try FileOperationPolicy.createFile(at: col.appendingPathComponent("KEEP.txt")) } catch { threw += 1 }
    do { try FileOperationPolicy.createDirectory(at: col.appendingPathComponent("keep.TXT")) } catch { threw += 1 }
    if threw != 3 { fail("CASE14", "only \(threw)/3 colliding operations refused") }
    let content = (try? String(contentsOf: keep, encoding: .utf8)) ?? "<unreadable>"
    if content != "ORIGINAL" { fail("CASE14", "original content now '\(content)'") }
    if !FileManager.default.fileExists(atPath: other.path) { fail("CASE14", "refused rename lost its source") }
} catch { fail("CASE14", "setup: \(error)") }

// ── CASE 15: case-only rename rolls back when step 2 fails (S-2) ──────────
// Reached through the `FileOperationPolicy.moveItem` seam: the second call (tmp -> new
// name) is made to throw, which a healthy disk never does on its own.
let rb = dir6.appendingPathComponent("rb")
do {
    try FileOperationPolicy.createDirectory(at: rb)
    try Data("PAYLOAD".utf8).write(to: rb.appendingPathComponent("lower.txt"))
    let realMove = FileOperationPolicy.moveItem
    var calls = 0
    FileOperationPolicy.moveItem = { a, b in
        calls += 1
        if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
        try realMove(a, b)
    }
    var threw = false
    do { try FileOperationPolicy.rename(from: rb.appendingPathComponent("lower.txt"),
                                        to: rb.appendingPathComponent("LOWER.txt")) } catch { threw = true }
    FileOperationPolicy.moveItem = realMove
    let names = (try? FileManager.default.contentsOfDirectory(atPath: rb.path)) ?? []
    if !threw { fail("CASE15", "injected step-2 failure was swallowed") }
    if names != ["lower.txt"] { fail("CASE15", "after rollback the folder holds \(names), expected [lower.txt]") }
} catch { fail("CASE15", "setup: \(error)") }

_ = try? FileManager.default.removeItem(at: dir6)  // harness scratch only

// ── CASE 16: caseSensitiveFSAtRoot — returns a Bool, no crash ─────────────
// macOS temp dirs live on the boot volume (APFS, case-insensitive by default).
// We cannot assert a hard true/false because a CI machine may be on a CS volume;
// we assert only that the function returns *some* Bool without throwing or crashing.
// (The compile-time type constraint already guarantees Bool, but the runtime query
// must not crash — the earlier body used `try?` which masked a nil chain; the new
// helper uses flatMap and ?? so it is safe on any volume.)
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
let cs16 = FileOperationPolicy.caseSensitiveFSAtRoot(tmpDir)
// `cs16` is a Bool — the assignment alone proves it compiled and ran.
// Report the measured value so CI logs make the volume's actual semantics visible.
print("  case16 caseSensitiveFSAtRoot(\(tmpDir.lastPathComponent)) = \(cs16) (informational)")

// ── Result ────────────────────────────────────────────────────────────────
if bad == 0 {
    print("check-file-ops: ALL 16 CASES PASSED")
} else {
    print("check-file-ops: \(bad) FAILURE(S)")
}
exit(bad > 0 ? 1 : 0)
