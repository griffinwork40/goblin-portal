// check-key-latency-harness.swift
// Owns the timestamp truth table, separate from shell mutation orchestration so
// assertions compile against shipped KeyLatencyModel.swift (AFK.md Conventions).
import Foundation

var passed = 0
var failed = 0
@MainActor
func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        passed += 1
        print("ok \(name)")
    } else {
        failed += 1
        print("FAIL \(name)")
    }
}
func near(_ value: Double?, _ target: Double) -> Bool {
    guard let value else { return false }
    return abs(value - target) < 0.00001
}
func sample() -> KeyLatencyModel.Summary? {
    var model = KeyLatencyModel()
    model.keyDown(at: 10)
    model.outputArrived(at: 10.025)
    model.frameCompleted(at: 10.040)
    return model.drain(at: 10.1)
}
let one = sample()
expect("single-key-paired", one?.keys == 1 && one?.paired == 1 && one?.unechoed == 0)
expect("key-output-duration", near(one?.keyToOutput.p50, 25))
expect("output-frame-duration", near(one?.outputToFrame.p50, 15))
expect("key-frame-duration", near(one?.keyToFrame.max, 40))

do {
    var model = KeyLatencyModel()
    model.keyDown(at: 10)
    model.outputArrived(at: 9)
    model.frameCompleted(at: 10.5)
    expect("output-before-key", model.drain(at: 10.6)?.paired == 0)
    model.outputArrived(at: 10.7)
    model.frameCompleted(at: 10.8)
    expect("later-valid-output", model.drain(at: 10.9)?.paired == 1)
}
do {
    var model = KeyLatencyModel()
    model.keyDown(at: 10)
    model.outputArrived(at: 10.5)
    model.frameCompleted(at: 10.4)
    expect("frame-before-output", model.drain(at: 10.6)?.paired == 0 && model.pending.count == 1)
    model.frameCompleted(at: 10.7)
    expect("later-valid-frame", model.drain(at: 10.8)?.paired == 1)
}
do {
    var model = KeyLatencyModel()
    model.keyDown(at: 10)
    model.keyDown(at: 10.1)
    model.outputArrived(at: 10.2)
    model.frameCompleted(at: 10.3)
    let summary = model.drain(at: 10.4)
    expect("two-keys-one-batch", summary?.keys == 2 && summary?.paired == 2)
    expect("batch-tail-max", near(summary?.keyToFrame.max, 300))
}
do {
    var model = KeyLatencyModel()
    model.keyDown(at: 10)
    expect("timeout-boundary", model.drain(at: 12)?.unechoed == 0 && model.pending.count == 1)
    let summary = model.drain(at: 12.001)
    expect("unechoed-timeout", summary?.unechoed == 1 && model.pending.isEmpty)
    expect("timeout-reported-once", model.drain(at: 13) == nil)
}
do {
    var model = KeyLatencyModel()
    for _ in 0..<300 { model.keyDown(at: 10) }
    let summary = model.drain(at: 10.1)
    expect("pending-cap", model.pending.count == 256 && summary?.unechoed == 44 && summary?.keys == 300)
}
do {
    var model = KeyLatencyModel()
    expect("no-keys-nil", model.drain(at: 10) == nil)
    model.keyDown(at: 10)
    model.outputArrived(at: 10.1)
    model.frameCompleted(at: 10.2)
    _ = model.drain(at: 10.3)
    expect("drain-resets-window", model.drain(at: 10.4) == nil)
    model.keyDown(at: 11)
    expect("next-window-count", model.drain(at: 11.1)?.keys == 1)
}
do {
    var model = KeyLatencyModel()
    model.keyDown(at: 10)
    _ = model.drain(at: 10.1)
    model.outputArrived(at: 10.2)
    model.frameCompleted(at: 10.3)
    let summary = model.drain(at: 10.4)
    expect("pending-survives-drain", summary?.keys == 0 && summary?.paired == 1)
}
do {
    var model = KeyLatencyModel()
    model.keyDown(at: 10)
    model.outputArrived(at: 12.1)
    model.frameCompleted(at: 12.2)
    let summary = model.drain(at: 12.3)
    expect("late-output-expires", summary?.paired == 0 && summary?.unechoed == 1)
}
do {
    var model = KeyLatencyModel()
    model.keyDown(at: 10)
    model.outputArrived(at: 10)
    model.outputArrived(at: 10.1)
    model.frameCompleted(at: 10.2)
    expect("first-output-kept", near(model.drain(at: 10.3)?.keyToOutput.max, 0))
}
let percentiles = KeyLatencyModel.Percentiles(seconds: (1...20).reversed().map { Double($0) / 1000 })
expect("percentile-known-set", near(percentiles.p50, 10) && near(percentiles.p95, 19) && near(percentiles.max, 20))
let empty = KeyLatencyModel.Percentiles(seconds: [])
expect("empty-percentiles", empty.p50 == 0 && empty.p95 == 0 && empty.max == 0)
expect("counter-delta", KeyLatencyModel.counterDelta(17, previous: 10) == 7)
expect("counter-reset", KeyLatencyModel.counterDelta(3, previous: 10) == 3)
if let one {
    var context = KeyLatencyModel.Context()
    context.fullscreen = true
    context.screen = "Built-in\nDisplay"
    context.fps = 120
    context.visible = true
    context.ticks = 120
    context.frames = 4
    context.idle = 116
    context.immediate = 2
    context.renders = 4
    let line = KeyLatencyModel.format(one, context: context)
    let fields = ["[diag] keys: keys=1", "paired=1", "unechoed=0",
                  "key_output_p50=25.00", "key_output_p95=25.00", "key_output_max=25.00",
                  "output_frame_p50=15.00", "output_frame_p95=15.00", "output_frame_max=15.00",
                  "key_frame_p50=40.00", "key_frame_p95=40.00", "key_frame_max=40.00",
                  "fullscreen=true", "screen=\"Built-in\\nDisplay\"", "fps=120", "visible=true",
                  "ticks=120", "frames=4", "idle=116", "immediate=2", "renders=4"]
    expect("format-fields", fields.allSatisfy { line.contains($0) } && !line.contains("\n"))
} else {
    expect("format-fields", false)
}
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
