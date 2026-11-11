//
//  check-git-watch-harness.swift
//  The assertions for check-git-watch.sh. Not part of the app; never built by SwiftPM.
//
//  Its own file for the reason check-git-status-harness.swift is: inline in the shell
//  script the two halves cross the 350-line ceiling. The shell half compiles this as
//  main.swift beside the SHIPPED GitStatusWatch.swift (or a mutated copy of it).
//
//  Every case drives a real FSEvents stream over real directories and pumps the main run
//  loop; nothing is simulated. Intervals are shortened through the initialiser so the
//  whole table runs in well under a minute. The assertions are bounds that load can only
//  make easier (an upper bound on reads, "at least one read within 5s"), never tight
//  timings, so a busy machine does not turn this red.
//
//  argv[1] = scratch directory. GATE_ONLY=<case id> runs one case (used per mutant).
//

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let work = URL(fileURLWithPath: CommandLine.arguments[1])
let only = ProcessInfo.processInfo.environment["GATE_ONLY"]
var failures = 0
var ran = 0
var serial = 0

final class Counter {
    var fires = 0
    var last: TimeInterval = 0
    func hit() { fires += 1; last = ProcessInfo.processInfo.systemUptime }
    func reset() { fires = 0 }
}

func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  ✓ \(label)" : "  ✗ FAIL \(label)  \(detail)")
    if !ok { failures += 1 }
}

func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func pump(upTo seconds: TimeInterval, until done: () -> Bool) {
    let end = now() + seconds
    while !done() && now() < end { pump(0.02) }
}

/// Let events from building the fixture drain, then start counting from zero.
func settle(_ counter: Counter) { pump(0.7); counter.reset() }

func freshDir(_ name: String) -> URL {
    let url = work.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func touch(_ dir: URL) {
    serial += 1
    try? Data("\(serial)".utf8).write(to: dir.appendingPathComponent("f-\(serial)"))
}

@discardableResult
func git(_ arguments: [String], in dir: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid"]
        + arguments
    process.currentDirectoryURL = dir
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Top-level code in a swiftc-built main.swift runs on the main thread but is not typed
/// `@MainActor`, so each case states the fact once here instead of at every call.
func run(_ id: String, _ body: @MainActor () -> Void) {
    guard only == nil || only == id else { return }
    ran += 1
    print("\(id)")
    MainActor.assumeIsolated { body() }
}

/// A watch with no backstop to speak of, so only FSEvents can explain a read.
@MainActor func quickWatch(
    _ counter: Counter, floor: TimeInterval = 0.2, backstop: TimeInterval = 60
) -> GitStatusWatch {
    GitStatusWatch(backstopInterval: backstop, minimumInterval: floor, streamLatency: 0.05) {
        counter.hit()
        return true
    }
}

print("==> check-git-watch.sh (GitStatusWatch, real FSEvents)")

// The scratch directory is mktemp's /var/folders/... path, which is a symlink into
// /private. No case resolves it, so every case below also shows that a symlinked watch
// path works, which is what a Space opened through a symlink hands the app.

run("W1") {
    let dir = freshDir("w1"), counter = Counter(), watch = quickWatch(counter)
    watch.watch(directories: [dir])
    watch.start()
    settle(counter)
    check("W1a a stream is open while running with directories", watch.isStreaming)
    touch(dir)
    pump(upTo: 5) { counter.fires >= 1 }
    check("W1b a write under a watched directory asks for a read", counter.fires >= 1)
    watch.stop()
}

run("W2") {
    let dir = freshDir("w2"), counter = Counter(), watch = quickWatch(counter, backstop: 0.3)
    watch.watch(directories: [dir])
    watch.start()
    settle(counter)
    watch.stop()
    counter.reset()
    touch(dir)
    pump(1.5)
    check("W2a stop() silences the stream and the backstop", counter.fires == 0,
        "fires=\(counter.fires)")
    check("W2b stop() closes the stream", !watch.isStreaming && !watch.isRunning)
}

// THE BUG THIS GATE WAS WRITTEN FOR: resign key, become key, same repository. Nothing
// calls watch(directories:) again, because the repository did not change.
run("W3") {
    let dir = freshDir("w3"), counter = Counter(), watch = quickWatch(counter)
    watch.watch(directories: [dir])
    watch.start()
    settle(counter)
    watch.stop()
    watch.start()
    settle(counter)
    check("W3a start() after stop() re-opens the stream", watch.isStreaming)
    touch(dir)
    pump(upTo: 5) { counter.fires >= 1 }
    check("W3b a write after stop()/start() asks for a read", counter.fires >= 1)
    watch.stop()
}

run("W4") {
    let first = freshDir("w4a"), second = freshDir("w4b")
    let counter = Counter(), watch = quickWatch(counter)
    watch.watch(directories: [first])
    pump(0.5)
    touch(first)
    pump(1.2)
    check("W4a directories given while stopped open no stream", !watch.isStreaming)
    check("W4b ...and ask for no read", counter.fires == 0, "fires=\(counter.fires)")
    watch.start()
    settle(counter)
    watch.watch(directories: [second])
    settle(counter)
    touch(first)
    pump(1.2)
    check("W4c after repointing, the old directory is no longer watched",
        counter.fires == 0, "fires=\(counter.fires)")
    touch(second)
    pump(upTo: 5) { counter.fires >= 1 }
    check("W4d ...and the new one is", counter.fires >= 1)
    watch.watch(directories: [])
    check("W4e an empty set (not in a repository) closes the stream", !watch.isStreaming)
    watch.stop()
}

// A build: continuous writes. The loop ends 0.3-0.6s after a read, inside the floor, so
// the final writes can only be picked up by the trailing read.
run("W5") {
    let dir = freshDir("w5"), counter = Counter(), watch = quickWatch(counter, floor: 1.0)
    watch.watch(directories: [dir])
    watch.start()
    settle(counter)
    let begin = now()
    var lastWrite = begin
    while now() - begin < 8 {
        touch(dir)
        lastWrite = now()
        pump(0.02)
        if now() - begin >= 3, (0.3...0.6).contains(now() - counter.last) { break }
    }
    let burst = now() - begin
    pump(2.0)
    let ceiling = Int(burst) + 3
    check("W5a churn is held to the rate floor", (2...ceiling).contains(counter.fires),
        "fires=\(counter.fires) over \(String(format: "%.1f", burst))s, allowed 2...\(ceiling)")
    check("W5b the last write of a burst is followed by a read", counter.last > lastWrite,
        "last read \(String(format: "%.2f", lastWrite - counter.last))s BEFORE the last write")
    watch.stop()
}

run("W6") {
    let counter = Counter(), watch = quickWatch(counter, floor: 0.1, backstop: 0.4)
    watch.start()
    pump(1.6)
    check("W6a the backstop asks for reads with no stream at all", counter.fires >= 2,
        "fires=\(counter.fires)")
    check("W6b no directories means no stream", !watch.isStreaming)
    watch.stop()
}

run("W7") {
    let dir = freshDir("w7"), cookies = freshDir("w7/fsmonitor--daemon/cookies")
    let counter = Counter(), watch = quickWatch(counter)
    watch.watch(directories: [dir])
    watch.start()
    settle(counter)
    touch(cookies)
    pump(1.2)
    check("W7a an fsmonitor cookie write asks for no read", counter.fires == 0,
        "fires=\(counter.fires)")
    touch(dir)
    pump(upTo: 5) { counter.fires >= 1 }
    check("W7b control: an ordinary write beside it still does", counter.fires >= 1)
    check("W7c isNoise is narrow",
        GitStatusWatch.isNoise("/r/.git/fsmonitor--daemon/cookies/")
            && !GitStatusWatch.isNoise("/r/.git/") && !GitStatusWatch.isNoise("/r/src/"))
    watch.stop()
}

// An owner released without stop(). The stream holds a raw pointer to the watch.
run("W8") {
    let dir = freshDir("w8"), counter = Counter()
    var ownerAlive = true
    var strong: GitStatusWatch? = GitStatusWatch(
        backstopInterval: 60, minimumInterval: 0.1, streamLatency: 0.05
    ) {
        counter.hit()
        return ownerAlive
    }
    weak var ref = strong
    strong?.watch(directories: [dir])
    strong?.start()
    settle(counter)
    strong = nil
    check("W8a an open stream keeps its watch alive", ref != nil)
    // Without that, the stream now points at freed memory: stop before any event lands.
    guard ref != nil else { print("\n1 FAILED (stopping: dangling stream)"); exit(1) }
    ownerAlive = false
    touch(dir)
    pump(upTo: 5) { ref == nil }
    check("W8b owner gone: the watch stops itself and is released", ref == nil)
    let after = counter.fires
    touch(dir)
    pump(0.8)
    check("W8c ...and a later write reaches nothing", counter.fires == after && after >= 1,
        "fires \(after) -> \(counter.fires)")
}

// The real reader in the callback, on a real repository: does reading cause a read?
run("W9") {
    let repo = freshDir("w9")
    guard git(["init", "-q"], in: repo), (try? Data("a".utf8).write(
            to: repo.appendingPathComponent("tracked"))) != nil,
        git(["add", "-A"], in: repo), git(["commit", "-q", "-m", "one"], in: repo),
        let found = GitStatusReader.discoverRepository(at: repo)
    else { print("ENV: could not build the git fixture"); exit(2) }
    let counter = Counter()
    let watch = GitStatusWatch(backstopInterval: 60, minimumInterval: 0.2, streamLatency: 0.05) {
        counter.hit()
        _ = GitStatusReader.snapshot(of: found)
        return true
    }
    watch.watch(directories: [found.gitDirectory, found.commonDirectory, found.root])
    watch.start()
    settle(counter)
    touch(repo)
    pump(upTo: 5) { counter.fires >= 1 }
    check("W9a an untracked file in the worktree asks for a read", counter.fires >= 1)
    pump(3.0)
    check("W9b running git status does not itself ask for another read", counter.fires <= 3,
        "fires=\(counter.fires) in 3s of idle; a loop at this floor would be about 15")
    counter.reset()
    git(["add", "-A"], in: repo)
    pump(upTo: 5) { counter.fires >= 1 }
    check("W9c a staging change (the index only) asks for a read", counter.fires >= 1)
    watch.stop()
}

print("")
if ran == 0 { print("ENV: no case ran (GATE_ONLY=\(only ?? "-") matched nothing)"); exit(2) }
if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("all checks passed")
