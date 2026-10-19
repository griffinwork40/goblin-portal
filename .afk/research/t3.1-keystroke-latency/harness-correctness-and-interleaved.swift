// check-input-latency-harness.swift — compiled by check-input-latency.sh as main.swift
// against the vendored SwiftTerm.o. Exit 0 = pass, 1 = assertion failure, 2 = environment.
//
// WHAT IT MEASURES (T3.1, .afk/research/best-mac-terminal-roadmap-2026-10-07.md Tranche 3):
// the keystroke round trip the app actually runs — `LocalProcess.send(data:)` called on the
// MAIN thread (as `TerminalView.send` does from keyDown) until the echoed byte is handed to
// the delegate's `dataReceived` on the MAIN queue (`dispatchQueue: nil` → `.main`,
// LocalProcess.swift:127, exactly how `LocalProcessTerminalView` builds it). The child is a
// raw-mode, no-tty-echo `cat`, so the echo is produced by a separate process that has to be
// scheduled — the shape of zsh's line editor echoing a key, not the kernel's line
// discipline echoing it inside write(2), which would hide the child-wakeup cost.
//
// Modes (argv[1]):
//   latency   N interleaved pairs, one keystroke per arm (direct write vs DispatchIO),
//             random order within each pair; direct must win at p50 by >= 20 µs and
//             not lose at p95. Exit code is the verdict.
//   order     a 64 KiB paste immediately followed by 200 single-byte keystrokes; every
//             byte must come back in the order sent (a sync write overtaking an in-flight
//             DispatchIO paste would reorder them).
//   full      child stops reading (SIGSTOP) and the pty input queue is filled by raw
//             write(2) until EAGAIN; further small send()s must return promptly (never
//             block the main thread), and every byte must arrive, in order, after resume.
//   control   latency with BOTH arms on upstream DispatchIO; must show no delta.
//   fdflags   prints whether the pty master carries O_NONBLOCK (the precondition of the
//             sync path; the patch refuses to write synchronously without it).
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

/// Spin the MAIN run loop (which drains the main dispatch queue, where LocalProcess
/// delivers data) until `done()` or the deadline. Wakes on the mach port, not on a poll.
@discardableResult
func pump(timeout: Double, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() {
        if Date() >= deadline { return false }
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }
    return true
}

let mode = CommandLine.arguments.dropFirst().first ?? "latency"
let probe = Probe()
let proc = LocalProcess(delegate: probe)
// Raw + no echo: bytes reach cat unbuffered (VMIN=1) and only cat's own write echoes them.
// `R` is the ready marker so no sample is timed before cat is actually reading.
proc.startProcess(executable: "/bin/sh",
                  args: ["-c", "stty raw -echo; printf R; exec /bin/cat"],
                  environment: ["PATH=/bin:/usr/bin", "TERM=dumb"])
guard proc.running else { envFail("child did not start") }
guard pump(timeout: 5, until: { probe.received.contains(UInt8(ascii: "R")) }) else {
    envFail("child never printed its ready marker")
}
probe.received.removeAll()

let nonblocking = (fcntl(proc.childfd, F_GETFL) & O_NONBLOCK) != 0

switch mode {
case "fdflags":
    print("O_NONBLOCK on pty master: \(nonblocking)")
    exit(0)

case "latency", "control":
    // PAIRED, INTERLEAVED design: every pair sends one keystroke down each path, in a
    // random order, inside ONE process. Separate runs per mode drifted 109-165 µs at p50
    // between rounds on the same code (machine load), which is the size of the effect
    // being measured; interleaving cancels that drift. `control` sends BOTH arms down the
    // upstream DispatchIO path and must show NO delta, or the threshold is measuring noise.
    let pairs = Int(ProcessInfo.processInfo.environment["SAMPLES"] ?? "") ?? 600
    let minDeltaUs = 20.0
    var arm: [[Double]] = [[], []]           // [0] = DispatchIO (upstream), [1] = direct write
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
        if probe.received.last != b { print("FAIL: wrong byte echoed"); exit(1) }
        usleep(2000)                         // typing cadence; lets the echo path go idle
        return dt
    }
    for i in 0..<(pairs + 20) {              // first 20 pairs are warm-up, discarded
        let directArm = mode == "latency"
        let order = Bool.random() ? [0, 1] : [1, 0]
        var got = [0.0, 0.0]
        for a in order { got[a] = sample(direct: a == 1 && directArm) }
        if i >= 20 { arm[0].append(got[0]); arm[1].append(got[1]) }
    }
    LocalProcess.synchronousSmallWritesEnabled = true
    func pct(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
    }
    let names = mode == "latency" ? ["dispatchio", "direct"] : ["dispatchio-A", "dispatchio-B"]
    for a in 0...1 {
        print(String(format: "  %-13@ p50 %7.1f  p95 %7.1f  p99 %7.1f  max %8.1f µs",
                     names[a] as NSString, pct(arm[a], 0.5), pct(arm[a], 0.95), pct(arm[a], 0.99), arm[a].max()!))
    }
    let delta = pct(arm[0], 0.5) - pct(arm[1], 0.5)
    let p95delta = pct(arm[0], 0.95) - pct(arm[1], 0.95)
    print(String(format: "RESULT {\"mode\":\"%@\",\"pairs\":%d,\"p50_delta_us\":%.1f,\"p95_delta_us\":%.1f}",
                 mode as NSString, pairs, delta, p95delta))
    if mode == "latency" {
        // The roadmap's bar: show a delta or drop the patch. Direct must beat DispatchIO
        // at the median by minDeltaUs, and must not be worse in the tail.
        if delta < minDeltaUs { print(String(format: "FAIL: p50 delta %.1f µs < %.0f µs — the patch earns nothing", delta, minDeltaUs)); exit(1) }
        if p95delta < 0 { print(String(format: "FAIL: direct write is WORSE at p95 by %.1f µs", -p95delta)); exit(1) }
        print("ok latency: direct write beats DispatchIO at p50 and is no worse at p95")
    } else {
        if abs(delta) >= minDeltaUs { print(String(format: "FAIL: control shows a %.1f µs delta between two IDENTICAL paths — the threshold is inside the noise", delta)); exit(1) }
        print("ok control: identical paths are within the threshold of each other")
    }
    exit(0)

case "order":
    var expected: [UInt8] = []
    let paste = (0..<65536).map { UInt8(ascii: "A") + UInt8($0 % 26) }
    proc.send(data: paste[...]); expected += paste
    for i in 0..<200 {
        let b = UInt8(ascii: "a") + UInt8(i % 26)
        proc.send(data: [b][...]); expected.append(b)
    }
    guard pump(timeout: 10, until: { probe.received.count >= expected.count }) else {
        print("FAIL: only \(probe.received.count)/\(expected.count) bytes came back"); exit(1)
    }
    if probe.received != expected {
        let first = probe.received.indices.first(where: { probe.received[$0] != expected[$0] }) ?? -1
        print("FAIL: bytes reordered — first mismatch at offset \(first) of \(expected.count)")
        exit(1)
    }
    print("ok order: 64 KiB paste + 200 keystrokes came back byte-identical, in order")
    exit(0)

case "full":
    // Stop the child so nothing drains the pty's input queue, then fill it.
    kill(proc.shellPid, SIGSTOP)
    var expected: [UInt8] = []
    // Fill the pty's input queue with RAW write(2) on the master, not proc.send: that way
    // no DispatchIO write is in flight, so the next send() takes the direct path and has
    // to meet EAGAIN itself — the branch a DispatchIO-filled queue would skip entirely.
    let filler = [UInt8](repeating: UInt8(ascii: "x"), count: 256)
    var spins = 0
    while spins < 100_000 {
        spins += 1
        let n = filler.withUnsafeBytes { write(proc.childfd, $0.baseAddress, $0.count) }
        if n > 0 { expected += filler[0..<n]; continue }
        if n < 0 && errno == EAGAIN { break }
        envFail("raw fill write failed, errno \(errno)")
    }
    print("pty input queue full after \(expected.count) bytes")
    _ = pump(timeout: 0.3, until: { false })                              // let DispatchIO hit EAGAIN
    var worst: UInt64 = 0
    for i in 0..<50 {
        let b = UInt8(ascii: "a") + UInt8(i % 26)
        let t0 = now()
        proc.send(data: [b][...])
        worst = max(worst, now() - t0)
        expected.append(b)
    }
    print(String(format: "worst send() with a full pty: %.1f µs", Double(worst) / 1000))
    // 5 ms is three orders of magnitude above a non-blocking write and far below what a
    // blocking write into a stopped reader would cost (forever). It is the regression line.
    if worst > 5_000_000 { print("FAIL: send() blocked the calling thread"); kill(proc.shellPid, SIGCONT); exit(1) }
    kill(proc.shellPid, SIGCONT)
    guard pump(timeout: 20, until: { probe.received.count >= expected.count }) else {
        print("FAIL: only \(probe.received.count)/\(expected.count) bytes arrived after resume"); exit(1)
    }
    if probe.received != expected { print("FAIL: bytes lost or reordered behind a full pty"); exit(1) }
    print("ok full: send() never blocked; all \(expected.count) bytes arrived in order after resume")
    exit(0)

case "gap":
    // Probe (b): 50ms gap lets DispatchIO state drain between samples — reveals delta
    // hidden by fd-entry contamination in the 2ms interleaved design. Identical logic to
    // "latency" but with an additional 48ms outer sleep after each pair (the inner
    // sample() already sleeps 2ms, totalling 50ms per pair). The shell wrapper checks
    // the delta; the harness exits 0 as long as a RESULT line is produced.
    let gapPairs = Int(ProcessInfo.processInfo.environment["SAMPLES"] ?? "") ?? 300
    let gapMinDeltaUs = 20.0
    var gapArm: [[Double]] = [[], []]
    let gapLetters = Array("abcdefghijklmnopqrstuvwxyz".utf8)
    var gk = 0
    func gapSample(direct: Bool) -> Double {
        LocalProcess.synchronousSmallWritesEnabled = direct
        let b = gapLetters[gk % gapLetters.count]; gk += 1
        let before = probe.received.count
        let t0 = now()
        proc.send(data: [b][...])
        guard pump(timeout: 2, until: { probe.received.count > before }) else {
            print("FAIL: gap keystroke \(gk) never echoed"); exit(1)
        }
        let dt = Double(now() - t0) / 1000
        if probe.received.last != b { print("FAIL: gap wrong byte echoed"); exit(1) }
        usleep(2000)
        return dt
    }
    for i in 0..<(gapPairs + 20) {
        let order = Bool.random() ? [0, 1] : [1, 0]
        var got = [0.0, 0.0]
        for a in order { got[a] = gapSample(direct: a == 1) }
        if i >= 20 { gapArm[0].append(got[0]); gapArm[1].append(got[1]) }
        usleep(48_000)   // extra 48ms on top of the 2ms in gapSample → ~50ms total gap
    }
    LocalProcess.synchronousSmallWritesEnabled = true
    func gapPct(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
    }
    let gapDelta = gapPct(gapArm[0], 0.5) - gapPct(gapArm[1], 0.5)
    let gapP95delta = gapPct(gapArm[0], 0.95) - gapPct(gapArm[1], 0.95)
    for (a, name) in [(0, "dispatchio"), (1, "direct")] {
        print(String(format: "  %-13@ p50 %7.1f  p95 %7.1f  p99 %7.1f  max %8.1f µs",
                     name as NSString, gapPct(gapArm[a], 0.5), gapPct(gapArm[a], 0.95),
                     gapPct(gapArm[a], 0.99), gapArm[a].max()!))
    }
    print(String(format: "RESULT {\"mode\":\"gap\",\"pairs\":%d,\"p50_delta_us\":%.1f,\"p95_delta_us\":%.1f}",
                 gapPairs, gapDelta, gapP95delta))
    // Harness always exits 0 for gap — pass threshold is enforced by the shell wrapper.
    if gapDelta >= gapMinDeltaUs && gapP95delta >= 0 {
        print("ok gap: direct write beats DispatchIO at p50 and is no worse at p95")
    } else {
        print(String(format: "note gap: p50 delta %.1f µs (threshold %.0f µs) — shell wrapper decides verdict", gapDelta, gapMinDeltaUs))
    }
    exit(0)

case "block":
    // Probe (c): separated blocks eliminate arm-to-arm contamination from interleaved
    // design. Block A: 120 samples with direct write. Block B: 120 samples with
    // DispatchIO. Discard first 20 of each block as warm-up. Higher tail variance than
    // interleaved; shell wrapper checks the delta.
    let blkN = 120
    let blkWarmup = 20
    let blkKeep = blkN - blkWarmup
    let blkMinDeltaUs = 20.0
    var blkDirect: [Double] = []
    var blkDispatch: [Double] = []
    let blkLetters = Array("abcdefghijklmnopqrstuvwxyz".utf8)
    var bk = 0
    func blkSample(direct: Bool) -> Double {
        LocalProcess.synchronousSmallWritesEnabled = direct
        let b = blkLetters[bk % blkLetters.count]; bk += 1
        let before = probe.received.count
        let t0 = now()
        proc.send(data: [b][...])
        guard pump(timeout: 2, until: { probe.received.count > before }) else {
            print("FAIL: block keystroke \(bk) never echoed"); exit(1)
        }
        let dt = Double(now() - t0) / 1000
        if probe.received.last != b { print("FAIL: block wrong byte echoed"); exit(1) }
        usleep(2000)
        return dt
    }
    // Block A: direct write
    for i in 0..<blkN {
        let s = blkSample(direct: true)
        if i >= blkWarmup { blkDirect.append(s) }
    }
    // Block B: DispatchIO
    for i in 0..<blkN {
        let s = blkSample(direct: false)
        if i >= blkWarmup { blkDispatch.append(s) }
    }
    LocalProcess.synchronousSmallWritesEnabled = true
    func blkPct(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
    }
    let blkDelta = blkPct(blkDispatch, 0.5) - blkPct(blkDirect, 0.5)
    let blkP95delta = blkPct(blkDispatch, 0.95) - blkPct(blkDirect, 0.95)
    for (xs, name) in [(blkDirect, "direct"), (blkDispatch, "dispatchio")] {
        print(String(format: "  %-13@ p50 %7.1f  p95 %7.1f  p99 %7.1f  max %8.1f µs",
                     name as NSString, blkPct(xs, 0.5), blkPct(xs, 0.95),
                     blkPct(xs, 0.99), xs.max()!))
    }
    print(String(format: "RESULT {\"mode\":\"block\",\"pairs\":%d,\"p50_delta_us\":%.1f,\"p95_delta_us\":%.1f}",
                 blkKeep, blkDelta, blkP95delta))
    if blkDelta >= blkMinDeltaUs {
        print("ok block: direct write beats DispatchIO at p50 in separated blocks")
    } else {
        print(String(format: "note block: p50 delta %.1f µs (threshold %.0f µs) — shell wrapper decides verdict", blkDelta, blkMinDeltaUs))
    }
    exit(0)

default:
    envFail("unknown mode \(mode)")
}
