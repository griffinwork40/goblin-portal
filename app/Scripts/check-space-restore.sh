#!/bin/bash
#
# Assert the Space-restore persistence layer keeps its promises.
#
# Same technique as check-keybindings.sh, and for the same reason: this app has no
# test target, and `OpenSpaceRoots` is a near-pure function of (stored strings,
# what exists on disk) — so instead of standing up XCTest, compile the SHIPPED
# Sources/GoblinPortal/Defaults.swift together with a throwaway harness and run a truth
# table. Nothing is stubbed or restated: a change to the real store shows up here.
#
# The compiled unit was Sources/GoblinPortal/Config.swift until 2026-07-28, when the
# 350-LOC ceiling split the UserDefaults stores out into Defaults.swift. Only the
# file name moved; `OpenSpaceRoots` itself is unchanged, which is why all 12 cases
# below are untouched.
#
# Why this script exists at all: restore is the one feature whose payoff is only
# observable ACROSS a quit/relaunch boundary, which no headless check can drive.
# The window/tab half genuinely cannot be verified here (see the PR body) — but the
# half that decides *what* comes back is ordinary logic, and leaving it unverified
# because its sibling is untestable would be the worse trade. In particular the
# fail-soft cases below are the ones that would otherwise only be discovered by a
# user whose app opened to nothing.
#
# Runs against a temp directory and its own defaults domain, NOT
# com.griffinlong.goblin-portal: a check that trashed your real remembered Spaces would be
# a bad check. The last assertion proves that isolation held.
#
# Usage: ./Scripts/check-space-restore.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# No SwiftTerm prebuild any more. Config.swift imported it for `CursorStyle` and
# the `Color` conversion, so compiling that file dragged in the whole module and
# its object file; Defaults.swift imports only AppKit, because a UserDefaults store
# has no business knowing about the emulator. That is a property worth keeping — it
# is what lets this check run without building SwiftTerm at all. If a future edit
# makes this script need `-I .build/out/Products/Debug` again, the store has grown
# a dependency it should not have.

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit

var failures = 0

func check(_ label: String, _ got: [String], _ expect: [String]) {
    let ok = got == expect
    if !ok { failures += 1 }
    print("\(ok ? "✓" : "✗") \(label)")
    if !ok {
        print("    expected \(expect)")
        print("    got      \(got)")
    }
}

/// Snapshot the real app's remembered Spaces BEFORE this harness writes anything,
/// so the isolation assertion at the bottom can compare a delta.
///
/// This used to assert the key was *absent* from com.griffinlong.goblin-portal, which was
/// wrong and made the check fail on any machine where Goblin Portal had actually been used
/// — `GoblinPortal.openSpaceRoots` is exactly what a real launch is supposed to write, so
/// the gate went permanently red for the correct reason and reported it as
/// pollution (found 2026-07-28 by three independent readers during the 350-LOC
/// split). A red gate nobody can fix is worse than no gate: it trains you to skip
/// the one signal that would have caught a real regression. Absence was never the
/// property worth asserting — "the harness did not write here" is.
let realDomain = UserDefaults(suiteName: "com.griffinlong.goblin-portal")
let realSpacesBefore = realDomain?.stringArray(forKey: "GoblinPortal.openSpaceRoots")

let fm = FileManager.default
let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("goblin-portal-restore-check-\(getpid())")

func dir(_ name: String) -> URL {
    let url = sandbox.appendingPathComponent(name)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let alpha = dir("alpha"), beta = dir("beta"), gamma = dir("gamma")
/// Never created — stands in for a project deleted between launches.
let deleted = sandbox.appendingPathComponent("deleted-project")

func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

// The base case: tab order is the point. Restoring the right roots in the wrong
// order rearranges the user's tab bar on every launch.
OpenSpaceRoots.urls = [alpha, beta, gamma]
check("round-trips in tab order", names(OpenSpaceRoots.urls), ["alpha", "beta", "gamma"])

// Checked, not trusted — the LastSpaceRoot rule applied per element. A root that
// is gone would otherwise open a Space onto an empty tree with no explanation.
OpenSpaceRoots.urls = [alpha, beta, deleted, gamma]
check("drops a deleted root, keeps the rest", names(OpenSpaceRoots.urls), ["alpha", "beta", "gamma"])

// isDirectory is not incidental: a project directory replaced by a file of the
// same name passes fileExists() alone.
let asFile = sandbox.appendingPathComponent("was-a-directory")
try? "not a directory".write(to: asFile, atomically: true, encoding: .utf8)
OpenSpaceRoots.urls = [alpha, asFile]
check("rejects a file where a directory was", names(OpenSpaceRoots.urls), ["alpha"])

// Two Spaces on one root rebuild the indistinguishable pair openFolder's dedupe
// explicitly refuses to create.
OpenSpaceRoots.urls = [alpha, beta, alpha, beta, gamma]
check("collapses duplicate roots", names(OpenSpaceRoots.urls), ["alpha", "beta", "gamma"])

// /tmp vs /private/tmp, or any symlinked checkout, must not read as two roots.
let link = sandbox.appendingPathComponent("alpha-symlink")
try? fm.createSymbolicLink(at: link, withDestinationURL: alpha)
OpenSpaceRoots.urls = [alpha, link, beta]
check("a symlink to a root is not a second root", names(OpenSpaceRoots.urls), ["alpha", "beta"])

// Overflow must drop the LEFTMOST tabs and keep order — each Space costs a login
// shell, and scrambling the survivors would be worse than capping.
let many = (1...20).map { dir("p\($0)") }
OpenSpaceRoots.urls = many
let capped = OpenSpaceRoots.urls
check(
    "caps at limit, keeping the most recent in order",
    [String(capped.count), capped.first?.lastPathComponent ?? "-", capped.last?.lastPathComponent ?? "-"],
    [String(OpenSpaceRoots.limit), "p\(20 - OpenSpaceRoots.limit + 1)", "p20"])

// Closing your last Space is you saying you are done; the next launch should be
// one fresh Space, not a resurrection.
OpenSpaceRoots.urls = []
check("an empty list stays empty", OpenSpaceRoots.urls.map(\.path), [])

// The both-empty-cases path AppDelegate.restoreSpaces() depends on: a list whose
// every entry is gone has to read as "nothing to restore", not as N dead Spaces.
OpenSpaceRoots.urls = [deleted]
check("every-root-deleted reads as empty", OpenSpaceRoots.urls.map(\.path), [])

// Fail-soft, the AppConfig.load() contract applied to persistence. A key someone
// hand-edited (or a future version wrote differently) must degrade to a working
// app, not trap on launch — stringArray(forKey:) returns nil for a non-array.
let key = "GoblinPortal.openSpaceRoots"
UserDefaults.standard.set("a-bare-string", forKey: key)
check("a string where an array belongs degrades to empty", OpenSpaceRoots.urls.map(\.path), [])
UserDefaults.standard.set(42, forKey: key)
check("a number where an array belongs degrades to empty", OpenSpaceRoots.urls.map(\.path), [])
UserDefaults.standard.set([1, 2, 3], forKey: key)
check("an array of non-strings degrades to empty", OpenSpaceRoots.urls.map(\.path), [])

UserDefaults.standard.removeObject(forKey: key)

// access(path, X_OK) guard: a directory that exists but has no execute bit
// must be rejected. Without the guard, fileExists says yes, chdir fails
// silently inside SwiftTerm's forkpty child (Pty.swift:103:
// `_ = chdir(cCurrentDirectory)`), and the shell starts in the app's cwd
// with no diagnostic. chmod is run as root-is-not-required: the real-UID
// access(2) check matches what the forked shell will see (#8).
let noExec = sandbox.appendingPathComponent("no-exec-dir")
try? fm.createDirectory(at: noExec, withIntermediateDirectories: true)
// 0o000 = no read, no write, no execute for anyone.
try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: noExec.path)
OpenSpaceRoots.urls = [alpha, noExec]
check("rejects a directory without execute permission", names(OpenSpaceRoots.urls), ["alpha"])
// Restore permissions so the sandbox cleanup (removeItem) can actually delete it.
try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noExec.path)

// The check must not have touched the real app's remembered Spaces. A bundle-less
// binary gets its own defaults domain, so this asserts that assumption rather
// than trusting it. Compared as a delta against the snapshot taken before any of
// the writes above — whatever the real domain held, it must still hold, whether
// that is nothing or a dozen roots from daily use.
let realSpacesAfter = realDomain?.stringArray(forKey: "GoblinPortal.openSpaceRoots")
check(
    "the real com.griffinlong.goblin-portal domain was not written",
    [realSpacesBefore == realSpacesAfter ? "unchanged" : "POLLUTED"],
    ["unchanged"])

try? fm.removeItem(at: sandbox)

print("")
print(failures == 0 ? "all checks passed" : "\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
SWIFT

swiftc -o "$TMP/harness" \
  Sources/GoblinPortal/Defaults.swift "$TMP/main.swift" \
  -framework AppKit

"$TMP/harness"
