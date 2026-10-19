// harness-block-counterbalanced.swift
// Counterbalanced blocked design: runs AB order OR BA order depending on argv[1].
// AB = direct first, then DispatchIO. BA = DispatchIO first, then direct.
// 120 samples per block, first 20 discarded as warmup → 100 kept.
// Exit 0 always (verdict applied externally).
import Foundation
import SwiftTerm

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func envFail(_ msg: String) -> Never { print("ENV: \(msg)"); exit(2) }

final class Probe: LocalProcessDelegate {
    var received: [UInt8] = []
    var terminated = false
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { terminated = true }
    func dataReceived(slice: ArraySlice<UInt8>) { received.append(contentsOf: slice) }
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
}

@discardableResult
func pump(timeout: Double, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() {
        if Date() >= deadline { return false }
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }
    return true
}

let order = CommandLine.arguments.dropFirst().first ?? "AB"  // AB or BA
let probe = Probe()
let proc = LocalProcess(delegate: probe)
proc.startProcess(executable: "/bin/sh",
                  args: ["-c", "stty raw -echo; printf R; exec /bin/cat"],
                  environment: ["PATH=/bin:/usr/bin", "TERM=dumb"])
guard proc.running else { envFail("child did not start") }
guard pump(timeout: 5, until: { probe.received.contains(UInt8(ascii: "R")) }) else {
    envFail("child never printed ready marker")
}
probe.received.removeAll()

let blkN = 120; let blkWarmup = 20
let letters = Array("abcdefghijklmnopqrstuvwxyz".utf8)
var k = 0

func sample(direct: Bool) -> Double {
    LocalProcess.synchronousSmallWritesEnabled = direct
    let b = letters[k % letters.count]; k += 1
    let before = probe.received.count
    let t0 = now()
    proc.send(data: [b][...])
    guard pump(timeout: 2, until: { probe.received.count > before }) else {
        print("FAIL: keystroke \(k) never echoed"); exit(1)
    }
    let dt = Double(now() - t0) / 1000
    usleep(2000)
    return dt
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted(); return s[min(s.count-1, Int(Double(s.count)*p))]
}

var blockA: [Double] = []   // first block
var blockB: [Double] = []   // second block
let aIsDirect = (order == "AB")

// Block A
for i in 0..<blkN {
    let s = sample(direct: aIsDirect)
    if i >= blkWarmup { blockA.append(s) }
}
// brief pause between blocks
usleep(200_000)
// Block B
for i in 0..<blkN {
    let s = sample(direct: !aIsDirect)
    if i >= blkWarmup { blockB.append(s) }
}

let directSamples  = aIsDirect ? blockA : blockB
let dispatchSamples = aIsDirect ? blockB : blockA

for (xs, name) in [(directSamples, "direct"), (dispatchSamples, "dispatchio")] {
    print(String(format: "  %-13@ p50 %7.1f  p95 %7.1f  p99 %7.1f  max %8.1f µs",
                 name as NSString, pct(xs,0.5), pct(xs,0.95), pct(xs,0.99), xs.max()!))
}
let delta = pct(dispatchSamples, 0.5) - pct(directSamples, 0.5)
print(String(format: "RESULT {\"order\":\"%@\",\"n\":%d,\"p50_delta_us\":%.1f}", order as NSString, blockA.count, delta))
exit(0)
