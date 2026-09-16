//
//  check-git-status-harness.swift
//  The assertion half of Scripts/check-git-status.sh.
//
//  Not part of the app: `Package.swift` globs `Sources/GoblinPortal` only, so nothing here is
//  ever linked into Goblin Portal. `check-git-status.sh` copies this file to `main.swift` in its
//  temp dir and compiles it against the two shipped sources under test.
//
//  WHY IT IS NOT A HEREDOC, unlike every other check script's harness. The shell half
//  plus this Swift came to 358 lines in one file, over `check-file-size.sh`'s 350-line
//  ceiling, and AFK.md's rule for that is explicit: find the seam and pull one whole
//  concern out — never shave comments, never raise LIMIT. The seam was already here and
//  is a clean one: the shell builds real repositories with real git, and this file makes
//  assertions about what the parser saw in them. Splitting on it also buys something a
//  heredoc cannot — this is real Swift that a formatter and an editor can both read,
//  where `<<'SWIFT'` swallows every syntax error silently until swiftc finally runs.
//
//  It must be COPIED to `main.swift` rather than compiled under its own name: Swift
//  allows top-level statements only in a file literally called main.swift, and this
//  harness is top-level code driving real subprocesses.
//
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ✓ " : "  ✗ ") + name + (detail.isEmpty ? "" : "   [\(detail)]"))
    if !ok { failures += 1 }
}

let work = ProcessInfo.processInfo.environment["GIT_GATE_WORK"] ?? ""
guard !work.isEmpty else { print("ENV: GIT_GATE_WORK unset"); exit(2) }
func fixture(_ name: String) -> URL { URL(fileURLWithPath: work + "/" + name) }

func snapshot(_ name: String) -> (GitRepository, GitStatusSnapshot)? {
    guard let repo = GitStatusReader.discoverRepository(at: fixture(name)),
          let snap = GitStatusReader.snapshot(of: repo) else { return nil }
    return (repo, snap)
}

guard let (plainRepo, plain) = snapshot("plain") else {
    print("ENV: could not read the plain fixture at all"); exit(2)
}

let weird = "sp ace's $weird`one.txt"
let emoji = "café-😀.txt"

// CONTROL. Boring ASCII add/modify/delete/untracked, no renames, no conflicts, no
// non-ASCII. Its job is the same as check-altbuffer-resize.sh's control case (:192-195):
// it must pass under a DELIBERATELY NAIVE parser too. If the control ever goes red
// alongside the edge cases, the rig is measuring the wrong thing and the whole run's
// verdict must be discarded rather than read as a real defect.
print("CONTROL — a boring repo any parser should manage")
check("modified file is .modified", plain.entries["control-mod.txt"]?.status == .modified,
      String(describing: plain.entries["control-mod.txt"]?.status))
check("deleted file is .deleted", plain.entries["control-del.txt"]?.status == .deleted)
check("untracked file is .untracked", plain.entries["control-new.txt"]?.status == .untracked)
check("staged add is .added and isStaged", plain.entries["staged-add.txt"]?.status == .added
      && plain.entries["staged-add.txt"]?.isStaged == true)
check("unmodified file gets no entry", plain.entries["control-keep.txt"] == nil)
check("worktree-only edit is not staged", plain.entries["control-mod.txt"]?.isStaged == false)

// THE RENAME RECORD — the single sharpest edge in the grammar. Under -z the TAB between
// the new and original path becomes a NUL, so one logical record spans TWO tokens. A
// parser that splits the blob on NUL and treats each piece as a record reads
// `rename-src.txt` as a record of its own; because every record is self-describing it
// does not cascade loudly, it just invents one path and drops another.
print("RENAME — the two-token record")
check("new path is present and .renamed", plain.entries["rename-dst.txt"]?.status == .renamed,
      String(describing: plain.entries["rename-dst.txt"]?.status))
check("original path is recorded on the entry",
      plain.entries["rename-dst.txt"]?.originalPath == "rename-src.txt",
      plain.entries["rename-dst.txt"]?.originalPath ?? "nil")
check("original path did NOT leak in as its own entry",
      plain.entries["rename-src.txt"] == nil,
      String(describing: plain.entries["rename-src.txt"]))
check("rename is staged (git mv writes the index)",
      plain.entries["rename-dst.txt"]?.isStaged == true)

// ADVERSARIAL PATHS — what -z buys. Without it these arrive C-octal-quoted (or not,
// depending on core.quotePath), and a parser that splits fixed fields on whitespace
// truncates the first one at its first space.
print("PATHS — spaces, quotes, and non-ASCII bytes")
check("space + ' + $ + backtick survives verbatim", plain.entries[weird]?.status == .modified,
      "keys=\(plain.entries.keys.filter { $0.contains("weird") })")
check("emoji filename survives verbatim", plain.entries[emoji]?.status == .modified,
      "keys=\(plain.entries.keys.filter { $0.contains("caf") })")
check("no key arrived octal-escaped",
      !plain.entries.keys.contains { $0.contains("\\3") || $0.hasPrefix("\"") })

// DIRECTORY ROLLUP — the outline view cannot walk children to answer a parent's
// decoration, because FileNode.children is nil for an unexpanded directory
// (FileNode.swift:97). So the snapshot must roll up eagerly.
print("ROLLUP — ancestors of a change")
check("immediate parent inherits", plain.directories["nested/deep"] == .modified,
      String(describing: plain.directories["nested/deep"]))
check("grandparent inherits too", plain.directories["nested"] == .modified)
check("a clean sibling directory gets nothing", plain.directories["not-a-dir"] == nil)
check("deleted does NOT roll up to its parent", plain.directories["doomed"] == nil,
      String(describing: plain.directories["doomed"]))
check("status(forRelativePath:) answers files and dirs through one call",
      plain.status(forRelativePath: "nested") == .modified
      && plain.status(forRelativePath: "control-mod.txt") == .modified
      && plain.status(forRelativePath: "control-keep.txt") == nil)

// BRANCH HEADERS. The absent-not-zero case is the one that breaks on exactly the
// freshly-created local branches an agent workflow produces constantly.
print("BRANCH — head, and ahead/behind that may not exist")
check("branch.head is parsed", plain.branch != nil && plain.isDetached == false,
      plain.branch ?? "nil")
check("no upstream -> ahead/behind are nil, NOT zero",
      plain.ahead == nil && plain.behind == nil,
      "ahead=\(String(describing: plain.ahead)) behind=\(String(describing: plain.behind))")
if let (_, upstream) = snapshot("upstream") {
    check("with an upstream, ahead/behind are parsed",
          upstream.ahead == 2 && upstream.behind == 0,
          "ahead=\(String(describing: upstream.ahead)) behind=\(String(describing: upstream.behind))")
} else {
    print("  ✗ upstream fixture unreadable"); failures += 1
}
if let (_, detached) = snapshot("detached") {
    check("detached HEAD -> isDetached, branch nil",
          detached.isDetached && detached.branch == nil, detached.branch ?? "nil")
} else {
    print("  ✗ detached fixture unreadable"); failures += 1
}

// UPSTREAM PRESENCE is a different question from ahead/behind, and git answers the two
// with two header lines under two conditions: `# branch.upstream` "If upstream is set",
// `# branch.ab` only "If upstream is set AND the commit is present" (git-status(1)).
// Reading the second as an answer to the first mislabels a branch whose remote was
// deleted and pruned — it still HAS an upstream — as having none, which is the state
// the sidebar header prints "no upstream" over.
print("UPSTREAM — configured is not the same as measurable")
check("no upstream at all -> hasUpstream is false", plain.hasUpstream == false)
if let (_, upstream) = snapshot("upstream") {
    check("a live upstream -> hasUpstream is true", upstream.hasUpstream == true)
}
if let (_, pruned) = snapshot("pruned") {
    check("a pruned upstream is still an upstream", pruned.hasUpstream == true,
          "hasUpstream=\(pruned.hasUpstream)")
    check("a pruned upstream reports no ahead/behind",
          pruned.ahead == nil && pruned.behind == nil,
          "ahead=\(String(describing: pruned.ahead))")
    // THE FALSIFICATION, and the only row in this gate that can catch the header
    // regressing to `ahead == nil`. Both halves must hold at once: the old test fires
    // (`ahead == nil`) on a branch that demonstrably HAS an upstream. Anywhere else in
    // the suite those two agree, so anywhere else the regression is invisible. If this
    // goes red because `hasUpstream` is false, the fixture stopped reproducing the
    // pruned state and the case is measuring nothing — check the fixture, not the parser.
    check("...so the old `ahead == nil` test would have called this 'no upstream'",
          pruned.ahead == nil && pruned.hasUpstream)
} else {
    print("  ✗ pruned fixture unreadable"); failures += 1
}

// PHRASING — the sentence the tooltip and VoiceOver both read, and the one place
// `isStaged` and `originalPath` reach a user. Gateable at all only since 2026-08-02:
// this logic touches no AppKit type but used to live behind an `import AppKit`, which
// is the only reason it was ever untested.
print("PHRASING — what a row says")
check("a worktree-only edit reads as one word",
      plain.entries["control-mod.txt"]?.statusPhrase == "modified",
      plain.entries["control-mod.txt"]?.statusPhrase ?? "nil")
check("staged is a qualifier appended after the noun, not a status of its own",
      plain.entries["staged-add.txt"]?.statusPhrase == "added, staged",
      plain.entries["staged-add.txt"]?.statusPhrase ?? "nil")
check("a rename names where it came from",
      plain.entries["rename-dst.txt"]?.statusPhrase == "renamed, staged, from rename-src.txt",
      plain.entries["rename-dst.txt"]?.statusPhrase ?? "nil")
check("an untracked row is never called staged",
      plain.entries["control-new.txt"]?.statusPhrase == "untracked",
      plain.entries["control-new.txt"]?.statusPhrase ?? "nil")
// The RM row. Its status is .modified, yet it carries an origin — which is why the
// comment on `originalPath` says "record", not "status".
check("a renamed-then-edited row is .modified but still names its origin",
      plain.entries["readd-dst.txt"]?.status == .modified
      && plain.entries["readd-dst.txt"]?.originalPath == "readd-src.txt",
      "\(String(describing: plain.entries["readd-dst.txt"]?.status)) "
      + "from=\(plain.entries["readd-dst.txt"]?.originalPath ?? "nil")")
check("...and reads as one honest sentence",
      plain.entries["readd-dst.txt"]?.statusPhrase == "modified, staged, from readd-src.txt",
      plain.entries["readd-dst.txt"]?.statusPhrase ?? "nil")
check("the tooltip capitalises the first character only, never the path",
      plain.entries["rename-dst.txt"]?.tooltip == "Renamed, staged, from rename-src.txt",
      plain.entries["rename-dst.txt"]?.tooltip ?? "nil")
// Listed here rather than by making GitFileStatus CaseIterable: the app never needs to
// enumerate them, and production surface added only for a gate is surface all the same.
// A case added upstream without a line here silently escapes this check — which the
// `letter` assertion below is the backstop for.
let everyStatus: [GitFileStatus] = [
    .conflicted, .added, .modified, .deleted, .renamed, .copied, .typeChanged,
    .untracked, .ignored,
]
check("every status word starts lower-case, so a tooltip cannot double-capitalise",
      everyStatus.allSatisfy { $0.accessibilityDescription.first?.isUppercase == false },
      everyStatus.map(\.accessibilityDescription).filter { $0.first?.isUppercase == true }
          .joined(separator: ","))
check("every status has a distinct one-character letter",
      Set(everyStatus.map(\.letter)).count == everyStatus.count
      && everyStatus.allSatisfy { $0.letter.count == 1 })

// UNMERGED RECORDS have a different field count than ordinary ones (three stage modes
// and three stage hashes, so the path is token 10 not 8). A parser reusing the ordinary
// layout silently drops every conflicted file — at the single moment a git sidebar's
// correctness matters most, and the moment least likely to be manually re-checked.
print("CONFLICT — the u record")
if let (_, conflicted) = snapshot("conflicted") {
    check("conflicted file is present", conflicted.entries["c.txt"] != nil,
          "keys=\(Array(conflicted.entries.keys))")
    check("conflicted file is .conflicted", conflicted.entries["c.txt"]?.status == .conflicted,
          String(describing: conflicted.entries["c.txt"]?.status))
    check("conflict outranks everything in a rollup",
          GitFileStatus.conflicted.rollupPrecedence < GitFileStatus.modified.rollupPrecedence)
} else {
    print("  ✗ conflicted fixture unreadable"); failures += 1
}

// DISCOVERY. The bug this replaces would have passed every manual test from an ordinary
// clone and failed on every worktree, including Goblin Portal's own development checkout.
print("DISCOVERY — including the worktree landmine")
check("plain repo root is found", plainRepo.root.lastPathComponent == "plain",
      plainRepo.root.path)
check("in an ordinary clone, git-dir == common-dir",
      plainRepo.gitDirectory == plainRepo.commonDirectory,
      "\(plainRepo.gitDirectory.path) vs \(plainRepo.commonDirectory.path)")
if let subRepo = GitStatusReader.discoverRepository(at: fixture("plain/nested/deep")) {
    check("discovery from a subdirectory finds the same root", subRepo.root == plainRepo.root,
          subRepo.root.path)
} else {
    print("  ✗ discovery from a subdirectory returned nil"); failures += 1
}
if let linked = GitStatusReader.discoverRepository(at: fixture("linked")) {
    // `.git` here is an ASCII file containing `gitdir:`, which is why `test -d .git` is
    // the wrong question. Asserted, not assumed — if git ever changes this, the fixture
    // builder refuses first.
    check("a linked worktree IS recognised as a repo", linked.root.lastPathComponent == "linked",
          linked.root.path)
    check("in a worktree, git-dir != common-dir (a watcher needs BOTH)",
          linked.gitDirectory != linked.commonDirectory,
          "\(linked.gitDirectory.path) vs \(linked.commonDirectory.path)")
    check("the worktree's common-dir is the main repo's git dir",
          linked.commonDirectory == plainRepo.commonDirectory,
          linked.commonDirectory.path)
} else {
    print("  ✗ a linked worktree was not recognised as a repository"); failures += 1
}
check("a plain directory is not a repo",
      GitStatusReader.discoverRepository(at: fixture("notrepo")) == nil)
check("a subdirectory of a plain directory is not a repo either",
      GitStatusReader.discoverRepository(at: fixture("notrepo/sub")) == nil)

// NESTED REPOSITORIES — a repo inside another repo's working tree, which is this project's
// own layout. Discovery is not the bug here: asked directly, it answers correctly, and case
// one proves it. What the other two cases pin is the reason a CONTAINMENT test cannot be
// substituted for asking — because containment stays true while the answer changes, and a
// cache keyed on it returns the outer repo forever once the tree root moves inward. That is
// a real defect that shipped in `GitStatusFollow.tick()` and is why it now keys its cache on
// the root it was answered for. These cases cannot reach that AppKit code; they assert the
// property underneath it, which is the part a `swiftc` harness can hold.
if let outer = GitStatusReader.discoverRepository(at: fixture("outer")),
    let inner = GitStatusReader.discoverRepository(at: fixture("outer/inner-wt"))
{
    check("a nested worktree resolves to ITSELF, not to the repo containing it",
          inner.root.lastPathComponent == "inner-wt", inner.root.path)
    check("the outer repo still CONTAINS the inner root — containment is not identity",
          outer.relativePath(for: fixture("outer/inner-wt")) == "inner-wt",
          outer.relativePath(for: fixture("outer/inner-wt")) ?? "nil")
    // The cost of reusing the outer repo is not a mislabelled branch alone: the outer repo
    // ignores the worktree, so every decoration inside it silently disappears.
    if let outerSnapshot = GitStatusReader.snapshot(of: outer) {
        check("the outer repo reports NO status for the inner worktree's dirty file",
              outerSnapshot.status(forRelativePath: "inner-wt/o.txt") == nil)
    } else {
        print("  ✗ the outer repo's snapshot was unreadable"); failures += 1
    }
} else {
    print("  ✗ the nested-worktree fixture was not recognised as two repositories")
    failures += 1
}

print("RELATIVE PATHS — how a tree node finds its decoration")
check("a file inside the repo resolves",
      plainRepo.relativePath(for: fixture("plain/nested/deep/buried.txt"))
          == "nested/deep/buried.txt",
      plainRepo.relativePath(for: fixture("plain/nested/deep/buried.txt")) ?? "nil")
check("the root itself resolves to the empty string",
      plainRepo.relativePath(for: fixture("plain")) == "")
check("a path outside the repo resolves to nil",
      plainRepo.relativePath(for: fixture("notrepo")) == nil)
check("a sibling with the root as a string prefix is NOT inside it",
      plainRepo.relativePath(for: URL(fileURLWithPath: work + "/plainer/x.txt")) == nil,
      "guards against dropFirst on a bare hasPrefix")

print("DEGENERATE INPUT — must not trap")
check("empty bytes -> empty snapshot", GitStatus.parse(porcelain: [UInt8]()) == .empty)
check("garbage -> empty entries, no crash",
      GitStatus.parse(porcelain: Array("not porcelain at all".utf8)).entries.isEmpty)
check("a truncated record is skipped, not fatal",
      GitStatus.parse(porcelain: Array("1 .M N... 100644\u{0}".utf8)).entries.isEmpty)
check("a rename record with no second token does not read past the end",
      GitStatus.parse(porcelain: Array(
          "2 R. N... 100644 100644 100644 aaa bbb R100 only.txt\u{0}".utf8))
          .entries["only.txt"]?.status == .renamed)

print("")
if failures == 0 {
    print("all checks passed")
    exit(0)
}
print("\(failures) check(s) failed")
exit(1)
