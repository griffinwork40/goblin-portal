//
//  GitStatusWatch.swift
//  When the git sidebar should read again: FSEvents first, a slow timer behind it.
//
//  One concern, "is it time to run `git status`?", and nothing about what the read does.
//  `GitStatusFollow` owns the read; this owns the three things that can ask for one and the
//  single start/stop switch over all of them:
//
//    1. an FSEvents stream over the repository's directories (the primary signal),
//    2. a 2s backstop timer for what FSEvents cannot see (NFS/SMB mounts, a volume that
//       silently stops generating events),
//    3. `fireNow()`, for the owner's own "read immediately" moments.
//
//  WHY THE TIMER LIVES HERE AND NOT IN THE FOLLOWER.  The first cut kept the timer in
//  `GitStatusFollow` and the stream here.  `stop()` (window resigned key) tore down both,
//  `start()` re-created only the timer, and the stream was re-opened only when the
//  repository CHANGED, so after one deactivate/activate cycle the app was silently back
//  on the 2s poll.  Two switches for one state is the bug; one object with one `isRunning`
//  cannot express it.  `check-git-watch.sh` case W3 pins the restart.
//
//  WHY A RATE FLOOR.  The stream is recursive over the worktree root, because untracked
//  files never touch `.git`.  That root also holds `.build/` and `node_modules/`, so a
//  build is a continuous event source, and FSEvents' own coalescing (0.3s) would turn it
//  into about three `git status` spawns a second.  At the ~92ms measured on a 60k-file repo
//  (`git-sidebar-external-mechanism-2026-07-31.md` §1.16) that is near 30% of a core for
//  as long as the build runs, against under 5% for the old 2s poll.  So: the first event
//  after a quiet spell reads at once, and further events inside `minimumInterval` collapse
//  into ONE trailing read at the end of it.  The trailing read is what keeps the floor
//  from being lossy: the last change in a burst is always followed by a read.
//
//  PATHS.  The caller provides the set: `gitDirectory` (index, refs, HEAD),
//  `commonDirectory` (differs from gitDirectory in a worktree; one alone is half-blind)
//  and the worktree root.  See the header of `FileTreeViewController+Git.swift`.
//

import CoreServices
import Foundation

/// Decides when the git poller reads. `@MainActor`; every callback arrives on main.
@MainActor
final class GitStatusWatch {
    /// The backstop cadence. Reasoned, not tuned: a fork/exec costing ~6.6ms on this
    /// checkout and ~92ms on a 60k-file repo, so 2s is under 5% of one core at worst.
    nonisolated static let backstopInterval: TimeInterval = 2.0
    /// The most often filesystem churn may cause a read. See "WHY A RATE FLOOR".
    nonisolated static let minimumInterval: TimeInterval = 1.0
    /// FSEvents' own coalescing window: small enough to feel instant after a quiet spell.
    nonisolated static let streamLatency: TimeInterval = 0.3

    private let backstopInterval: TimeInterval
    private let minimumInterval: TimeInterval
    private let streamLatency: TimeInterval
    /// Returns false when the owner is gone, and the watch then stops itself. That is the
    /// only way out when the owner is released without calling `stop()`: an open stream
    /// retains this object (see `openStream`), so nothing else would ever end it.
    private let onEvent: @MainActor () -> Bool

    private(set) var isRunning = false
    /// Whether an FSEvents stream is open. False while stopped, and outside a repository.
    var isStreaming: Bool { streamRef != nil }

    private var directories: [String] = []
    private var streamRef: FSEventStreamRef?
    /// Streams closed from inside their own callback, released one turn later.
    private var retired: [FSEventStreamRef] = []
    private var isDelivering = false
    private var backstop: Timer?
    private var trailing: Timer?
    /// `systemUptime` of the last read request: monotonic, so a clock change cannot stall it.
    private var lastFire: TimeInterval = -.infinity

    private static let diag = ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil

    /// The intervals are parameters only so `check-git-watch.sh` can run in seconds;
    /// production passes none of them.
    init(
        backstopInterval: TimeInterval = GitStatusWatch.backstopInterval,
        minimumInterval: TimeInterval = GitStatusWatch.minimumInterval,
        streamLatency: TimeInterval = GitStatusWatch.streamLatency,
        onEvent: @escaping @MainActor () -> Bool
    ) {
        self.backstopInterval = backstopInterval
        self.minimumInterval = minimumInterval
        self.streamLatency = streamLatency
        self.onEvent = onEvent
    }

    /// Begin signalling. Idempotent. Re-opens the stream for the directories last given to
    /// `watch(directories:)`, which is the whole fix for the restart bug in the header.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        backstop = Timer.scheduledTimer(withTimeInterval: backstopInterval, repeats: true) {
            [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.signal("backstop") }
        }
        openStream()
        note("start streaming=\(isStreaming) dirs=\(directories.count)")
    }

    /// Stop signalling and release the timer and the stream. The directories are kept.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        backstop?.invalidate()
        backstop = nil
        trailing?.invalidate()
        trailing = nil
        closeStream()
        note("stop")
    }

    /// Point the stream at a new set of directories; `[]` means "not in a repository".
    /// While stopped this only remembers them: a background Space opens no stream.
    func watch(directories next: [URL]) {
        let paths = next.map(\.path)
        guard paths != directories else { return }
        directories = paths
        if isRunning { closeStream(); openStream() }
        note("watch streaming=\(isStreaming) dirs=\(paths.count)")
    }

    /// Ask for a read right now, whether or not the watch is running. Stamped like any
    /// other request, so an event that lands while this read is in flight earns a
    /// trailing read instead of being dropped by the owner's in-flight guard.
    func fireNow() { fire("now") }

    // MARK: - The rate floor

    private func signal(_ source: String) {
        guard isRunning else { return }
        let wait = lastFire + minimumInterval - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else { return fire(source) }
        guard trailing == nil else { return }
        trailing = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.fire("trailing") }
        }
    }

    private func fire(_ source: String) {
        trailing?.invalidate()
        trailing = nil
        lastFire = ProcessInfo.processInfo.systemUptime
        // The backstop is silent: one line every 2s forever would bury the others.
        if source != "backstop" { note("read source=\(source)") }
        if !onEvent() { stop() }
    }

    // MARK: - The stream

    private func openStream() {
        guard streamRef == nil, !directories.isEmpty else { return }
        // The stream RETAINS this object for as long as it exists. It holds a raw pointer
        // to it, so anything weaker is a use-after-free on the first event after the owner
        // forgets to call `stop()`. `onEvent` returning false is what ends the cycle.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: Self.retainInfo, release: Self.releaseInfo, copyDescription: nil)
        // UseCFTypes: paths arrive as CFStrings.  NoDefer: the first event after a quiet
        // spell is delivered at once, then coalesced for `streamLatency`.  WatchRoot: say
        // so when a watched directory itself is renamed or deleted.  Deliberately not
        // FileEvents: "something under here changed" is all a full re-read needs, and
        // directory-level events are far cheaper on a large tree.
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            nil, Self.eventCallback, &context, directories as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), streamLatency, flags)
        else { return }
        streamRef = stream
        // The main queue, so the callback is on the main thread and `assumeIsolated`
        // states a fact. (`FSEventStreamScheduleWithRunLoop` is deprecated since macOS 13.)
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func closeStream() {
        guard let stream = streamRef else { return }
        streamRef = nil
        // Never tear a stream down inside its own callback: FSEvents still uses it after
        // the callback returns. Park it and release it on the next turn instead.
        guard isDelivering else { return Self.dispose(stream) }
        retired.append(stream)
        Task { @MainActor in
            self.retired.forEach(Self.dispose)
            self.retired.removeAll()
        }
    }

    private static func dispose(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func received(_ paths: [String]) {
        guard paths.isEmpty || !paths.allSatisfy(Self.isNoise) else { return }
        isDelivering = true
        defer { isDelivering = false }
        signal("fsevents")
    }

    /// Paths whose changes are caused by reading git, not by anything the user did.
    ///
    /// With `core.fsmonitor` on, every `git status` writes a cookie file under
    /// `.git/fsmonitor--daemon/cookies/`. Treating that as a change makes each read
    /// schedule the next one: a loop at the rate floor, forever, on exactly the large
    /// repositories where fsmonitor is switched on.
    nonisolated static func isNoise(_ path: String) -> Bool {
        path.contains("/fsmonitor--daemon/")
    }

    private func note(_ message: String) {
        guard Self.diag else { return }
        FileHandle.standardError.write(Data("[diag] git-watch: \(message)\n".utf8))
    }

    // MARK: - C callbacks

    private static let retainInfo: CFAllocatorRetainCallBack = { info in
        guard let info else { return nil }
        _ = Unmanaged<GitStatusWatch>.fromOpaque(info).retain()
        return info
    }

    private static let releaseInfo: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<GitStatusWatch>.fromOpaque(info).release()
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, _, paths, _, _ in
        guard let info else { return }
        let watch = Unmanaged<GitStatusWatch>.fromOpaque(info).takeUnretainedValue()
        let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        let names = changed as? [String] ?? []
        MainActor.assumeIsolated { watch.received(names) }
    }
}
