//
//  check-session-stage-harness.swift
//  Assertions for check-session-stage.sh: the T5.5 "Stage Session Changes" policy (#298).
//
//  A real file rather than a heredoc, the same split check-git-status.sh makes: the shell
//  half (mutants, compile, exit codes) and this half (cases) together would cross the
//  350-line ceiling. Copied to `main.swift` by the script and compiled against the
//  shipped SessionStagePolicy.swift, SessionHighlightPolicy.swift, GitStatus.swift,
//  GitStatus+Rollup.swift, GitStatusReader.swift and GitOperations.swift (or a mutated
//  COPY of one of them).
//
//  Two halves. T cases are a truth table over hand-built entries, one row per rule of
//  `SessionStagePolicy.pathsToStage`. G cases build a real repository with real `git`
//  under $GIT_GATE_WORK, run the real store and policy over real snapshots, stage with
//  the real `GitOperations.stage(paths:in:)`, and read the index back. Every label is
//  printed as `FAIL  <label>:` on failure so the script can attribute a mutant to its
//  declared case.
//

import Foundation

// `nonisolated(unsafe)`: the counter is only touched from this file's top-level code,
// one thread. Unannotated, Swift 6 mode treats it as main-actor state and rejects the
// mutation inside `expect` (measured with `swiftc -swift-version 6`); `@MainActor` on
// the helpers instead breaks the script's default Swift 5 mode, where top-level code is
// not main-actor isolated.
nonisolated(unsafe) var failed = 0
func expect(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("  ok  \(label)") } else { print("  FAIL  \(label): \(detail())"); failed += 1 }
}
func expectPaths(_ label: String, _ got: [String], _ want: [String]) {
    expect(label, got == want, "got \(got), want \(want)")
}

// ── truth table ─────────────────────────────────────────────────────────────

func entry(_ path: String, _ status: GitFileStatus, staged: Bool, worktree: Bool,
           from original: String? = nil) -> GitFileEntry {
    GitFileEntry(path: path, status: status, isStaged: staged,
                 hasWorkingTreeChange: worktree, originalPath: original)
}
func snap(_ entries: [GitFileEntry]) -> GitStatusSnapshot {
    GitStatusSnapshot(
        branch: "main", isDetached: false, ahead: nil, behind: nil, hasUpstream: false,
        entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) }),
        directories: [:])
}
// Literal defaults rather than a shared global: a default argument may not read a
// top-level variable of main.swift under strict concurrency checking.
func pick(_ session: Set<String>, _ entries: [GitFileEntry],
          sessionRoot: String? = "/tmp/repo-a", panelRoot: String? = "/tmp/repo-a") -> [String] {
    SessionStagePolicy.pathsToStage(
        sessionPaths: session, sessionRoot: sessionRoot, snapshot: snap(entries),
        panelRoot: panelRoot)
}

print("truth table")
// Candidates: untracked, or an unstaged worktree change (modified, deleted, type change).
expectPaths("T1 untracked", pick(["n.txt"], [entry("n.txt", .untracked, staged: false, worktree: true)]), ["n.txt"])
expectPaths("T2 unstaged modified", pick(["m.txt"], [entry("m.txt", .modified, staged: false, worktree: true)]), ["m.txt"])
expectPaths("T3 unstaged deleted", pick(["d.txt"], [entry("d.txt", .deleted, staged: false, worktree: true)]), ["d.txt"])
expectPaths("T4 unstaged type change", pick(["t"], [entry("t", .typeChanged, staged: false, worktree: true)]), ["t"])
// Staged-only: nothing left to add.
expectPaths("T5 staged only", pick(["s.txt"], [entry("s.txt", .modified, staged: true, worktree: false)]), [])
// Partially staged (MM, AM): `git add` would overwrite the user's hunk-level choice.
expectPaths("T6 partial MM", pick(["p.txt"], [entry("p.txt", .modified, staged: true, worktree: true)]), [])
expectPaths("T7 partial AM", pick(["a.txt"], [entry("a.txt", .modified, staged: true, worktree: true)]), [])
// Conflicted: `git add` would mark it resolved.
expectPaths("T8 conflicted", pick(["c.txt"], [entry("c.txt", .conflicted, staged: false, worktree: true)]), [])
// Repository identity: paths are repo-relative, so any mismatch stages nothing.
let dirty = [entry("x.txt", .modified, staged: false, worktree: true)]
expectPaths("T9 root mismatch", pick(["x.txt"], dirty, panelRoot: "/tmp/repo-b"), [])
expectPaths("T10 no session root", pick(["x.txt"], dirty, sessionRoot: nil), [])
expectPaths("T11 no panel repository", pick(["x.txt"], dirty, panelRoot: nil), [])
// Empty results.
expectPaths("T12 no session", pick([], dirty), [])
expectPaths("T13 nothing dirty", pick(["x.txt", "y.txt"], []), [])
// Only session paths: a dirty file outside the session is never staged.
expectPaths("T14 outside session",
            pick(["x.txt"], dirty + [entry("other.txt", .modified, staged: false, worktree: true)]), ["x.txt"])
// A rename's ORIGINAL path is never added through `originalPath` (an intent-to-add
// worktree rename, `.R`, is the one shape where a rename is not staged-only).
expectPaths("T15 rename original not added",
            pick(["new.txt"], [entry("new.txt", .renamed, staged: false, worktree: true, from: "old.txt")]),
            ["new.txt"])
expectPaths("T16 ignored", pick(["i.log"], [entry("i.log", .ignored, staged: false, worktree: true)]), [])
// Mixed, and sorted so the one `git add` argument list is deterministic.
expectPaths("T17 mixed sorted", pick(
    ["z.txt", "b.txt", "p.txt", "c.txt", "s.txt", "gone.txt"],
    [entry("z.txt", .untracked, staged: false, worktree: true),
     entry("b.txt", .modified, staged: false, worktree: true),
     entry("p.txt", .modified, staged: true, worktree: true),
     entry("c.txt", .conflicted, staged: false, worktree: true),
     entry("s.txt", .added, staged: true, worktree: false)]),
    ["b.txt", "z.txt"])

// ── real repository ─────────────────────────────────────────────────────────

/// Run a shell line in `dir`; stdout, or nil on a non-zero exit. Fixture failures are
/// environmental, so the caller exits 2 rather than reporting a red case.
@discardableResult
func sh(_ line: String, in dir: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", line]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}
func envFail(_ why: String) -> Never { print("ENV: \(why)"); exit(2) }

guard let work = ProcessInfo.processInfo.environment["GIT_GATE_WORK"] else { envFail("GIT_GATE_WORK unset") }
let dir = work + "/repo"
print("\nreal repository")
guard sh("""
    mkdir -p repo && cd repo && git init -q -b main . &&
    for f in keep gone part old base-dirty; do printf '%s\\n' "$f line" > "$f.txt"; done &&
    git add -A && git commit -q -m init &&
    printf 'pre-session\\n' >> base-dirty.txt && printf 'pre\\n' > starX.md
    """, in: work) != nil else { envFail("fixture repository would not build") }

guard let repo = GitStatusReader.discoverRepository(at: URL(fileURLWithPath: dir)),
      let s0 = GitStatusReader.snapshot(of: repo) else { envFail("git status failed") }
var store = SessionHighlightStore()
store.accumulate(entryKeys: Set(s0.entries.keys), repositoryRoot: repo.root.path)

// The session's changes: a deletion, a new file, a partial staging, an unstaged rename
// (old path deleted, new path untracked), and a file whose name is a glob.
guard sh("""
    rm gone.txt && printf 'new\\n' > new.txt &&
    printf 'staged hunk\\n' >> part.txt && git add part.txt && printf 'unstaged hunk\\n' >> part.txt &&
    mv old.txt renamed.txt && printf 'glob\\n' > 'star*.md'
    """, in: dir) != nil, let s1 = GitStatusReader.snapshot(of: repo)
else { envFail("session changes would not apply") }
store.accumulate(entryKeys: Set(s1.entries.keys), repositoryRoot: repo.root.path)

let chosen = SessionStagePolicy.pathsToStage(
    sessionPaths: store.effectivePaths, sessionRoot: store.repositoryRoot,
    snapshot: s1, panelRoot: repo.root.path)
expectPaths("G1 selection", chosen, ["gone.txt", "new.txt", "old.txt", "renamed.txt", "star*.md"])

guard let partBefore = sh("git ls-files -s -- part.txt", in: dir), !partBefore.isEmpty
else { envFail("ls-files failed") }
if case .failure(let e) = GitOperations.stage(paths: chosen, in: repo) {
    expect("G2 git add succeeded", false, e.message)
} else { expect("G2 git add succeeded", true) }
guard let s2 = GitStatusReader.snapshot(of: repo) else { envFail("git status failed after stage") }

let gone = s2.entries["gone.txt"]
expect("G3 deletion staged", gone?.status == .deleted && gone?.isStaged == true
       && gone?.hasWorkingTreeChange == false, "\(String(describing: gone))")
let added = s2.entries["new.txt"]
expect("G4 untracked added", added?.status == .added && added?.isStaged == true
       && added?.hasWorkingTreeChange == false, "\(String(describing: added))")
let partAfter = sh("git ls-files -s -- part.txt", in: dir)
expect("G5 partial index byte-identical", partAfter == partBefore,
       "before \(partBefore) after \(partAfter ?? "nil")")
expect("G5b partial still partial", s2.entries["part.txt"]?.isStaged == true
       && s2.entries["part.txt"]?.hasWorkingTreeChange == true)
let renamed = s2.entries["renamed.txt"]
expect("G6 rename fully staged", renamed?.status == .renamed && renamed?.isStaged == true
       && renamed?.hasWorkingTreeChange == false && renamed?.originalPath == "old.txt"
       && s2.entries["old.txt"] == nil, "\(String(describing: renamed))")
// `--literal-pathspecs`: the file named `star*.md` is a path, not a glob that also
// stages the pre-session `starX.md`.
expect("G7 literal pathspec", s2.entries["starX.md"]?.status == .untracked
       && s2.entries["star*.md"]?.isStaged == true, "\(String(describing: s2.entries["starX.md"]))")
expect("G8 baseline dirt untouched", s2.entries["base-dirty.txt"]?.isStaged == false)

// Nothing to stage does nothing: no session after a clear, and an empty list spawns no git.
guard let indexBefore = sh("git ls-files -s", in: dir) else { envFail("ls-files failed") }
store.reset()
expectPaths("G9 cleared session stages nothing", SessionStagePolicy.pathsToStage(
    sessionPaths: store.effectivePaths, sessionRoot: store.repositoryRoot,
    snapshot: s2, panelRoot: repo.root.path), [])
var emptyOK = false
if case .success = GitOperations.stage(paths: [], in: repo) { emptyOK = true }
expect("G10 empty stage is a no-op", emptyOK && sh("git ls-files -s", in: dir) == indexBefore)

print("\n\(failed) failed")
exit(failed > 0 ? 1 : 0)
