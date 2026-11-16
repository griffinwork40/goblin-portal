//
//  check-session-stage-harness.swift
//  Assertions for check-session-stage.sh: the T5.5 "Stage Session Changes" policy (#298).
//
//  A real file rather than a heredoc, the same split check-git-status.sh makes: the shell
//  half (mutants, compile, exit codes) and this half (cases) together would cross the
//  350-line ceiling. Copied to `main.swift` by the script and compiled against the
//  shipped SessionStageOperation.swift, SessionStagePolicy.swift,
//  SessionHighlightPolicy.swift, GitStatus.swift, GitStatus+Rollup.swift,
//  GitStatusReader.swift and GitOperations.swift (or a mutated COPY of one of them).
//
//  Two halves. T cases are a truth table over hand-built entries, one row per rule of
//  `SessionStagePolicy.pathsToStage`. G cases build a real repository with real `git`
//  under $GIT_GATE_WORK, run the real store and policy over real snapshots, stage with
//  the real `GitOperations.stage(paths:in:)`, and read the index back; G11–G12 drive the
//  shipped `SessionStageOperation` after a stale snapshot. Every label is
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

/// The snapshot a caller would have passed under the pre-fix design (the panel's cached
/// read). Defined here, never in shipped code: only mutant m6's copy of
/// `SessionStageOperation.swift` reads it. `nonisolated(unsafe)` for the same reason as
/// `failed` above: one thread, Swift 5 and 6 modes.
enum CallerSnapshot { nonisolated(unsafe) static var value: GitStatusSnapshot? }
extension GitRepository {
    static func discoverForGate(_ path: String) -> GitRepository? {
        GitStatusReader.discoverRepository(at: URL(fileURLWithPath: path))
    }
}

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
// The empty-list guard in `stage(paths:in:)` is what this checks: run against a repository
// whose root does not exist, a spawned `git` could not even start (`Process.run` fails to
// chdir) and the call would report failure, so success means nothing was spawned. Against
// the real repository a bare `git add --` would change nothing either way, which is why
// the index check alone could not see the guard go missing.
let missing = URL(fileURLWithPath: work + "/no-such-repo")
let nowhere = GitRepository(root: missing, gitDirectory: missing, commonDirectory: missing)
var emptyOK = false
if case .success = GitOperations.stage(paths: [], in: nowhere) { emptyOK = true }
expect("G10 empty stage spawns nothing", emptyOK
       && sh("git ls-files -s", in: dir) == indexBefore)

// ── stale snapshot, fresh read (the race the click-time snapshot lost) ──────────

// A session file is plainly unstaged when a snapshot is taken; THEN one of its two hunks is
// staged (what `git add -p`, or the agent in the terminal, does between two poller reads);
// then Stage Session Changes runs. Deciding from the earlier snapshot would `git add` the
// whole file over the hunk-level choice. The shipped `SessionStageOperation` reads status
// itself, so it must see the partial staging, skip that file, and still stage the other.
print("\nstale snapshot")
let dir2 = work + "/repo2"
guard sh("""
    mkdir -p repo2 && cd repo2 && git init -q -b main . &&
    seq 1 20 > late.txt && printf 'peer\\n' > peer.txt && git add -A && git commit -q -m init
    """, in: work) != nil,
      let repo2 = GitRepository.discoverForGate(dir2),
      let base2 = GitStatusReader.snapshot(of: repo2)
else { envFail("second fixture repository would not build") }
var store2 = SessionHighlightStore()
store2.accumulate(entryKeys: Set(base2.entries.keys), repositoryRoot: repo2.root.path)
// Two hunks far apart (lines 1 and 20), and an unstaged edit to a second session file.
guard sh("sed -i '' -e '1s/.*/first/' -e '20s/.*/last/' late.txt && printf 'more\\n' >> peer.txt",
         in: dir2) != nil, let stale = GitStatusReader.snapshot(of: repo2),
      stale.entries["late.txt"]?.isStaged == false, stale.entries["peer.txt"]?.isStaged == false
else { envFail("stale snapshot precondition: both files plainly unstaged") }
store2.accumulate(entryKeys: Set(stale.entries.keys), repositoryRoot: repo2.root.path)
// Stage only the first hunk: index = HEAD with line 1 changed, worktree also changes 20.
guard sh("""
    seq 1 20 | sed '1s/.*/first/' > ../hunk1 &&
    git update-index --cacheinfo "100644,$(git hash-object -w ../hunk1),late.txt"
    """, in: dir2) != nil,
      let lateBefore = sh("git ls-files -s -- late.txt", in: dir2), !lateBefore.isEmpty,
      let blobBefore = sh("git show :late.txt", in: dir2)
else { envFail("partial staging of late.txt failed") }

// What a caller-supplied snapshot would carry: the stale read. Shipped code never reads
// this; mutant m6 makes `SessionStageOperation` decide from it, the pre-fix behaviour.
CallerSnapshot.value = stale
let result = SessionStageOperation.stageFromFreshRead(
    sessionPaths: store2.effectivePaths, sessionRoot: store2.repositoryRoot, in: repo2)
let lateAfter = sh("git ls-files -s -- late.txt", in: dir2)
let blobAfter = sh("git show :late.txt", in: dir2)
expect("G11 late partial staging survives a stale snapshot",
       lateAfter == lateBefore && blobAfter == blobBefore,
       "ls-files before \(lateBefore) after \(lateAfter ?? "nil")")
let peer = GitStatusReader.snapshot(of: repo2)?.entries["peer.txt"]
var resultOK = false
if case .success = result { resultOK = true }
expect("G12 same call stages the eligible peer", resultOK && peer?.isStaged == true
       && peer?.hasWorkingTreeChange == false, "\(String(describing: peer))")

print("\n\(failed) failed")
exit(failed > 0 ? 1 : 0)
