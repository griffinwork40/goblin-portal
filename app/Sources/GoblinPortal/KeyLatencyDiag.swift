// KeyLatencyDiag.swift
// Owns the opt-in AppKit hooks and sinks for KeyLatencyModel. Kept separate from
// FramePacingDiag because paint cadence cannot establish key-to-echo latency
// (FramePacingDiag.swift:113); both consumers share the single presentation hook.
import AppKit
import QuartzCore
import SwiftTerm

@MainActor
enum KeyLatencyDiag {
    private static var installed = false
    private static var stderrEnabled = false
    private static var fileEnabled = false
    private static var monitor: Any?
    private static var timer: Timer?
    private static var model = KeyLatencyModel()
    private static weak var previousView: TerminalView?
    private static var previousCounters: [Int] = []
    private static let dateFormatter = ISO8601DateFormatter()
    private static var logHandle: FileHandle?

    static func installIfRequested() {
        guard !installed else { return }
        stderrEnabled = ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil
        fileEnabled = UserDefaults.standard.bool(forKey: "GoblinPortal.keyLatencyLog")
        guard stderrEnabled || fileEnabled else { return }
        installed = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.window?.firstResponder is TerminalView,
                   !event.modifierFlags.contains(.command) {
                    // NSEvent.timestamp and CACurrentMediaTime are assumed to be
                    // seconds on the same mach uptime clock. The event timestamp
                    // intentionally includes queue delay, unlike monitor entry time.
                    model.keyDown(at: event.timestamp)
                }
            }
            return event
        }
        // One slot, not a multicast observer (AppleTerminalView.swift:1514).
        // main.swift installs us AFTER FramePacingDiag so neither consumer is lost.
        let previous = TerminalView.onFramePresented
        TerminalView.onFramePresented = {
            let now = CACurrentMediaTime()
            previous?()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.frameCompleted(at: now) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { flush() }
        }
    }

    static func noteOutput(at time: TimeInterval) {
        guard installed else { return }
        model.outputArrived(at: time)
    }

    private static func flush() {
        let window = NSApp.keyWindow
        let view = window?.firstResponder as? TerminalView
        let screen = window?.screen
        var context = KeyLatencyModel.Context()
        context.fullscreen = window?.styleMask.contains(.fullScreen) ?? false
        context.screen = screen?.localizedName ?? "unknown"
        context.fps = screen?.maximumFramesPerSecond ?? 0
        context.visible = window?.occlusionState.contains(.visible) ?? false
        if let view {
            let d = view.diagnostics
            let current = [d.ticks, d.frames, d.idleTicks, d.immediateTicks, d.renders]
            // Independent snapshots: FramePacingDiag must not reset shared counters.
            // Still tolerate an external reset: a backwards count is the raw new value.
            let baseline = previousView === view ? previousCounters : []
            let delta = current.enumerated().map { index, count in
                KeyLatencyModel.counterDelta(count, previous: baseline.indices.contains(index) ? baseline[index] : 0)
            }
            context.ticks = delta[0]
            context.frames = delta[1]
            context.idle = delta[2]
            context.immediate = delta[3]
            context.renders = delta[4]
            previousView = view
            previousCounters = current
        } else {
            previousView = nil
            previousCounters = []
        }
        // Snapshot even in idle seconds, so the next typing window's counters
        // describe that second rather than all activity since the last key.
        guard let summary = model.drain(at: CACurrentMediaTime()) else { return }
        let line = KeyLatencyModel.format(summary, context: context)
        if stderrEnabled { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        if fileEnabled { appendLog(line) }
    }

    private static func appendLog(_ line: String) {
        if logHandle == nil {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/GoblinPortal", isDirectory: true)
            // Logging must never prevent typing or launch if the home is unwritable.
            // Filesystem operations fail soft, as required by AFK.md Conventions.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("key-latency.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data().write(to: url)
            }
            logHandle = try? FileHandle(forWritingTo: url)
        }
        guard let handle = logHandle else { return }
        // seekToEnd both positions the cursor for writing and returns the size
        // for the rotation check. The handle stays open for the app's lifetime
        // (KeyLatencyDiag is an enum with no deinit; acceptable for opt-in diag).
        if let size = try? handle.seekToEnd(), size > 1_048_576 {
            try? handle.truncate(atOffset: 0)
            try? handle.seek(toOffset: 0)
        }
        let timestamp = dateFormatter.string(from: Date())
        try? handle.write(contentsOf: Data("\(timestamp) \(line)\n".utf8))
    }
}
