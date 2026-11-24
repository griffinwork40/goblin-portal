// KeyLatencyModel.swift
// Owns timestamp pairing and log formatting, separate from AppKit so the headless
// check-key-latency.sh can exercise the shipped recorder without a window server.
//
// Measurement biases (hooks: AppleTerminalView.swift:1514,
// MetalTerminalRenderer.swift:1483, MacTerminalView.swift:1939):
// 1. GPU command-buffer completion is not photons: compositor and scan-out delay
//    are excluded (Core Text instead reports the end of draw).
// 2. A frame already in flight when output arrives can complete a key, under-
//    reporting by up to one frame.
// 3. When keys outpace echoes, one batch credits several keys: p50 under-reports;
//    max is the trustworthy figure.
// 4. Unrelated output in the same pane (a running build) pairs falsely; measure
//    at a quiet prompt. No key characters are retained.
// 5. frameCompleted is dispatched via DispatchQueue.main.async while the
//    1-second drain timer fires synchronously on the main RunLoop; a frame
//    completing just before the timer fires can land in the next drain window,
//    deferring at most one frame per second.
import Foundation

struct KeyLatencyModel {
    struct Pending {
        let key: TimeInterval
        var output: TimeInterval?
    }

    struct Sample {
        let keyToOutput: TimeInterval
        let outputToFrame: TimeInterval
        let keyToFrame: TimeInterval
    }

    struct Percentiles {
        let p50: Double
        let p95: Double
        let max: Double

        // Nearest rank keeps the tail visible for small typing windows, unlike
        // interpolation (check-key-latency.sh, percentile-known-set).
        init(seconds: [TimeInterval]) {
            let ms = seconds.map { $0 * 1000 }.sorted()
            func rank(_ p: Double) -> Double {
                guard !ms.isEmpty else { return 0 }
                return ms[Swift.max(0, Int(ceil(Double(ms.count) * p)) - 1)]
            }
            p50 = rank(0.50)
            p95 = rank(0.95)
            max = ms.last ?? 0
        }
    }

    struct Summary {
        let keys: Int
        let paired: Int
        let unechoed: Int
        let droppedFrames: Int
        let keyToOutput: Percentiles
        let outputToFrame: Percentiles
        let keyToFrame: Percentiles
    }

    struct Context {
        var fullscreen = false
        var screen = "unknown"
        var fps = 0
        var visible = false
        var ticks = 0
        var frames = 0
        var idle = 0
        var immediate = 0
        var renders = 0
    }

    let echoTimeout: TimeInterval = 2.0
    let frameTimeout: TimeInterval = 5.0
    let pendingCap: Int = 256
    private(set) var pending: [Pending] = []
    private var samples: [Sample] = []
    private var keys = 0
    private var unechoed = 0
    private var droppedFrames = 0

    mutating func keyDown(at time: TimeInterval) {
        expire(at: time)
        keys += 1
        if pending.count >= pendingCap {
            // Bound held-key memory even if no frame ever arrives. An evicted
            // key is unmeasured, never credited with an invented latency.
            pending.removeFirst()
            unechoed += 1
        }
        pending.append(Pending(key: time))
    }

    mutating func outputArrived(at time: TimeInterval) {
        expire(at: time)
        for index in pending.indices where pending[index].output == nil && pending[index].key <= time {
            pending[index].output = time
        }
    }

    mutating func frameCompleted(at time: TimeInterval) {
        expire(at: time)
        pending.removeAll { key in
            guard let output = key.output, output <= time else { return false }
            samples.append(Sample(keyToOutput: output - key.key,
                                  outputToFrame: time - output, keyToFrame: time - key.key))
            return true
        }
    }

    private mutating func expire(at time: TimeInterval) {
        pending.removeAll { key in
            if key.output == nil, time - key.key > echoTimeout {
                unechoed += 1
                return true
            }
            if let output = key.output, time - output > frameTimeout {
                droppedFrames += 1
                return true
            }
            return false
        }
    }

    mutating func drain(at time: TimeInterval) -> Summary? {
        expire(at: time)
        // Pending keys survive a reporting boundary. Late echoes/timeouts must
        // still be reported even when no NEW key arrived in that second.
        guard keys > 0 || !samples.isEmpty || unechoed > 0 || droppedFrames > 0 else { return nil }
        let result = Summary(keys: keys, paired: samples.count, unechoed: unechoed,
                             droppedFrames: droppedFrames,
                             keyToOutput: Percentiles(seconds: samples.map(\.keyToOutput)),
                             outputToFrame: Percentiles(seconds: samples.map(\.outputToFrame)),
                             keyToFrame: Percentiles(seconds: samples.map(\.keyToFrame)))
        keys = 0
        unechoed = 0
        droppedFrames = 0
        samples.removeAll(keepingCapacity: true)
        return result
    }

    static func counterDelta(_ current: Int, previous: Int) -> Int {
        current >= previous ? current - previous : current
    }

    static func format(_ summary: Summary, context: Context) -> String {
        func triple(_ name: String, _ values: Percentiles) -> String {
            let f = { (value: Double) in String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
            return "\(name)_p50=\(f(values.p50)) \(name)_p95=\(f(values.p95)) \(name)_max=\(f(values.max))"
        }
        // Quoting preserves spaces in localized screen names; escaping prevents
        // a display name from injecting a second log line (format-fields gate).
        let screen = context.screen.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        return "[diag] keys: keys=\(summary.keys) paired=\(summary.paired) unechoed=\(summary.unechoed) dropped=\(summary.droppedFrames) "
            + triple("key_output", summary.keyToOutput) + " "
            + triple("output_frame", summary.outputToFrame) + " "
            + triple("key_frame", summary.keyToFrame)
            + " fullscreen=\(context.fullscreen) screen=\"\(screen)\" fps=\(context.fps) visible=\(context.visible)"
            + " ticks=\(context.ticks) frames=\(context.frames) idle=\(context.idle)"
            + " immediate=\(context.immediate) renders=\(context.renders)"
    }
}
