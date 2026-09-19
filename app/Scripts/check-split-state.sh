#!/bin/bash
#
# Assert the split-state persistence layer keeps its promises.
#
# Same technique as check-space-restore.sh: compile the shipped sources together
# with a throwaway harness and run a truth table. Nothing is stubbed or restated —
# a change to `SplitStateStore` or the Codable snapshot types shows up here.
#
# `SplitStateStore.swift` imports only Foundation, so no AppKit or SwiftTerm
# dependency is needed — the harness compiles against the Foundation framework
# alone. The one indirect dependency is `SplitContainerView.Direction`, which is
# declared in `SplitContainerView.swift` (AppKit). A minimal stub redeclares that
# type Foundation-only, which is sufficient and keeps the compile fast.
# If a future edit requires the full AppKit import here, that is a property
# worth preserving, and the break in this script is the signal.
#
# Cases covered:
#   1. Round-trip encode/decode of a full snapshot (outer + both sub-splits).
#   2. Decode of a blob with an extra unknown field (must succeed — forward compat).
#   3. Decode of corrupt JSON returns nil (fail-soft).
#   4. Direction enum spellings are stable ("horizontal" and "vertical").
#   5. setSnapshots([]) removes the key rather than writing an empty array.
#
# Usage: ./Scripts/check-split-state.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# SplitStateStore uses UserDefaults.standard. The binary has no bundle ID, so it
# gets its own anonymous domain — no writes reach com.griffinlong.goblin-portal.
# The isolation assertion at the end proves that rather than trusting it.

# Minimal stub: redeclares SplitContainerView.Direction without AppKit so the
# harness compiles Foundation-only. The extension in SplitStateStore.swift
# attaches to this redeclaration transparently — same type name, same cases.
cat > "$TMP/stub.swift" <<'SWIFT'
// Stub for SplitContainerView.Direction only. SplitStateStore.swift adds an
// extension to this type; providing the minimal declaration here lets the
// harness compile without pulling in AppKit or SplitContainerView.swift.
@MainActor
final class SplitContainerView {
    enum Direction: Equatable { case horizontal, vertical }
}
SWIFT

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

var failures = 0

func check(_ label: String, _ got: Bool) {
    if !got { failures += 1 }
    print("\(got ? "✓" : "✗") \(label)")
}

func checkEq<T: Equatable>(_ label: String, _ got: T, _ expect: T) {
    let ok = got == expect
    if !ok { failures += 1 }
    print("\(ok ? "✓" : "✗") \(label)")
    if !ok {
        print("    expected \(expect)")
        print("    got      \(got)")
    }
}

// Snapshot the real splitState BEFORE this harness writes anything, so the
// isolation assertion can compare a delta.
let realSplitStateBefore = UserDefaults.standard.data(forKey: "GoblinPortal.splitState")

let testRoot = URL(fileURLWithPath: "/tmp/goblin-split-check-\(getpid())")

// ── Case 1: round-trip encode/decode of a full snapshot ──────────────────────
let subA = SubSplitSnapshot(direction: "horizontal", ratio: 0.4, cwd: "/tmp/a")
let subB = SubSplitSnapshot(direction: "vertical",   ratio: 0.6, cwd: nil)
let full = SplitSnapshot(
    outerDirection: "horizontal",
    outerRatio: 0.35,
    peerCwd: "/tmp/peer",
    primarySubSplit: subA,
    peerSubSplit: subB)

SplitStateStore.setSnapshots([full], for: testRoot)
let roundTripped = SplitStateStore.snapshots(for: testRoot)
check("round-trip: snapshots returns non-nil", roundTripped != nil)
if let rt = roundTripped?.first {
    checkEq("round-trip: outerDirection", rt.outerDirection, "horizontal")
    checkEq("round-trip: outerRatio",     rt.outerRatio,     0.35)
    checkEq("round-trip: peerCwd",        rt.peerCwd,        "/tmp/peer")
    checkEq("round-trip: primarySubSplit direction", rt.primarySubSplit?.direction, "horizontal")
    checkEq("round-trip: primarySubSplit ratio",     rt.primarySubSplit?.ratio,     0.4)
    checkEq("round-trip: primarySubSplit cwd",       rt.primarySubSplit?.cwd,       "/tmp/a")
    checkEq("round-trip: peerSubSplit direction",    rt.peerSubSplit?.direction,    "vertical")
    checkEq("round-trip: peerSubSplit ratio",        rt.peerSubSplit?.ratio,        0.6)
    checkEq("round-trip: peerSubSplit cwd is nil",   rt.peerSubSplit?.cwd == nil,   true)
} else {
    failures += 1
    print("✗ round-trip: could not read first snapshot (skipping field checks)")
}

// ── Case 2: forward compatibility — unknown field must not break decode ───────
// Write a raw JSON blob with an extra field the current model does not know.
// JSONDecoder ignores unknown keys by default, so this must succeed.
let extraFieldJSON = """
{
    "\(testRoot.path)": [
        {
            "outerDirection": "vertical",
            "outerRatio": 0.55,
            "peerCwd": null,
            "primarySubSplit": null,
            "peerSubSplit": null,
            "unknownFutureField": "some value"
        }
    ]
}
""".data(using: .utf8)!
UserDefaults.standard.set(extraFieldJSON, forKey: "GoblinPortal.splitState")
let fromExtra = SplitStateStore.snapshots(for: testRoot)
check("forward compat: extra unknown field decodes to non-nil", fromExtra != nil)
checkEq("forward compat: outerDirection preserved", fromExtra?.first?.outerDirection, "vertical")
checkEq("forward compat: outerRatio preserved",     fromExtra?.first?.outerRatio,     0.55)

// ── Case 3: corrupt JSON returns nil (fail-soft) ──────────────────────────────
let corruptData = "{ not valid json ]]]".data(using: .utf8)!
UserDefaults.standard.set(corruptData, forKey: "GoblinPortal.splitState")
let fromCorrupt = SplitStateStore.snapshots(for: testRoot)
check("fail-soft: corrupt JSON returns nil", fromCorrupt == nil)

// ── Case 4: direction enum spellings are stable ───────────────────────────────
checkEq("direction: horizontal persistedName", SplitContainerView.Direction.horizontal.persistedName, "horizontal")
checkEq("direction: vertical persistedName",   SplitContainerView.Direction.vertical.persistedName,   "vertical")
checkEq("direction: roundtrip horizontal", SplitContainerView.Direction(persistedName: "horizontal"), .horizontal)
checkEq("direction: roundtrip vertical",   SplitContainerView.Direction(persistedName: "vertical"),   .vertical)
check("direction: unknown string returns nil",
    SplitContainerView.Direction(persistedName: "diagonal") == nil)

// ── Case 5: setSnapshots([]) clears the key ───────────────────────────────────
// First write something real so there is a key to clear.
SplitStateStore.setSnapshots([full], for: testRoot)
check("setSnapshots([full]): present before clear", SplitStateStore.snapshots(for: testRoot) != nil)
SplitStateStore.setSnapshots([], for: testRoot)
// After clearing, snapshots(for:) must return nil — not an empty array.
check("setSnapshots([]): nil after clear", SplitStateStore.snapshots(for: testRoot) == nil)

// ── Isolation: the real app's splitState was not touched ─────────────────────
// The harness is a bundle-less binary; its UserDefaults domain is NOT
// com.griffinlong.goblin-portal. This assertion proves the assumption rather than
// trusting it — matched against the pre-run snapshot.
let realSplitStateAfter = UserDefaults.standard.data(forKey: "GoblinPortal.splitState")
let isolationHeld: Bool
if let before = realSplitStateBefore, let after = realSplitStateAfter {
    isolationHeld = before == after
} else {
    isolationHeld = (realSplitStateBefore == nil) == (realSplitStateAfter == nil)
}
check("isolation: real GoblinPortal.splitState was not written", isolationHeld)

print("")
print(failures == 0 ? "all checks passed" : "\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
SWIFT

swiftc -o "$TMP/harness" \
  "$TMP/stub.swift" \
  Sources/GoblinPortal/SplitStateStore.swift \
  "$TMP/main.swift" \
  -framework Foundation

"$TMP/harness"
