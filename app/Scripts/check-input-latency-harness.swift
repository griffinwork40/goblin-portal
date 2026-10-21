// check-input-latency-harness.swift
//
// Measures the key-to-echo round trip through a REAL pty, using the SAME write path the
// app uses, and asserts that a large paste followed by keystrokes arrives in order.
// Linked against the vendored RELEASE SwiftTerm.o by check-input-latency.sh.
//
// WHY: roadmap T3.1 (.afk/research/best-mac-terminal-roadmap-2026-10-07.md §Tranche 3)
// proposed replacing SwiftTerm's DispatchIO keystroke write with a synchronous
// non-blocking write(2), on the strength of A1a GAP 3, whose latency number ("45-65 ms
// structural") was an ESTIMATE. The roadmap's own rule: "must show a delta or the patch
// is dropped". This harness is that measurement.
//
// WHAT IS MEASURED, per sample, alternating the two arms so drift cancels:
//   app   — LocalProcess.send(data:) (LocalProcess.swift:215), which is exactly what
//           MacLocalTerminalView.send(source:data:) calls for every keystroke
//           (Mac/MacLocalTerminalView.swift:145-147). It wraps the bytes in DispatchData
//           and hands them to DispatchIO.write (:229).
//   write — a direct write(2) of the same byte on the same childfd. This is the FLOOR any
//           synchronous-write patch could reach: a patch adds a branch on top of it, never
//           removes work beneath it. So (app - write) is an UPPER BOUND on what T3.1 can win.
// Both arms share everything else: the child (`stty raw -echo; exec cat`, a process that
// must wake, read and write, like zsh's ZLE echoing a key), LocalProcess's read loop on its
// own queue, and the hop onto the main queue where dataReceived fires — the same hop the
// app's echo takes before SwiftTerm can feed it. The clock stops when dataReceived has the
// echoed byte, and that byte is checked against the one sent.
// Two regimes: "burst" (back-to-back keys, warm threads) and "typing" (a gap between keys
// so dispatch's worker threads go idle, the case GAP 3 worried about).
//
// WHAT IS NOT MEASURED: keyDown → send (identical for both arms), SwiftTerm's feed and
// the display-link paint (identical for both arms, and up to one frame, which is why the
// floor below is set against the frame). No photons.
//
// MEANINGFUL FLOOR: 1,000 µs — one eighth of a 120 Hz frame (8,333 µs). The echo is
// painted on the next display-link tick (patch 0010), so a write-path win smaller than
// a fraction of a frame moves which tick catches the echo only rarely. Below the floor,
// a vendor patch (a permanent maintenance cost, see AFK.md on re-vendoring) is not bought.
//
// ORDERING CASE: 256 KiB pasted through the app path, then 32 keystrokes through the app
// path; the echo must equal paste+keys byte for byte. INPUT_LATENCY_FALSIFY=naive sends the
// keystrokes through a bare write(2) instead — the naive T3.1 patch with no regard for the
// DispatchIO writes still queued — and the case must FAIL (bytes reordered or dropped:
// libdispatch makes a stream channel's fd O_NONBLOCK, so a bare write can also EAGAIN).
//
// INPUT_LATENCY_INJECT_US=N delays every app-arm send by N µs (asyncAfter on a global
// queue). The shell wrapper uses it to prove the harness can SEE a delta at the floor.
//
// Exit codes: 0 measured and in order · 1 ordering/echo assertion failed · 2 environmental
// (load > 0.70/CPU, child never started, echo timed out).

import Foundation
import SwiftTerm

let env = ProcessInfo.processInfo.environment
let falsifyNaive = env["INPUT_LATENCY_FALSIFY"] == "naive"
let injectUs = Int(env["INPUT_LATENCY_INJECT_US"] ?? "") ?? 0
let ignoreLoad = env["INPUT_LATENCY_IGNORE_LOAD"] == "1"
let floorUs = 1_000.0
let loadCeiling = 0.70

func loadAvg1m() -> Double {
    var info = host_load_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<host_load_info>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_LOAD_INFO, $0, &count)
        }
    }
    guard r == KERN_SUCCESS else { return 0 }
    return Double(info.avenrun.0) / Double(LOAD_SCALE)
}
let ncpu = Double(ProcessInfo.processInfo.activeProcessorCount)

/// N6 lesson (AFK.md, check-metal-throughput.sh): under scheduler contention the timed
/// interval measures wait, not the write path. Over the ceiling is exit 2, never 1.
func loadGuard(_ when: String) {
    let per = loadAvg1m() / ncpu
    print(String(format: "load (%@): %.2f/CPU (%.0f CPUs)", when, per, ncpu))
    if per > loadCeiling {
        if ignoreLoad { print("  INPUT_LATENCY_IGNORE_LOAD=1 — UNGUARDED, numbers are not evidence"); return }
        print("environmental: load above \(loadCeiling)/CPU — timing would measure contention")
        exit(2)
    }
}

final class Sink: LocalProcessDelegate {
    var buf: [UInt8] = []
    func processTerminated(_ s: LocalProcess, exitCode: Int32?) {}
    func dataReceived(slice: ArraySlice<UInt8>) { buf.append(contentsOf: slice) }
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
}

/// Turn the main run loop until `cond` holds — the app's main thread is likewise idle in
/// its run loop when the echo's main-queue block arrives.
func pump(timeout: Double, until cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > end { return false }
        CFRunLoopRunInMode(.defaultMode, 0.0005, true)
    }
    return true
}

func spawnCat() -> (LocalProcess, Sink) {
    let sink = Sink()
    let p = LocalProcess(delegate: sink)
    p.startProcess(executable: "/bin/sh", args: ["-c", "stty raw -echo; printf READY; exec cat"])
    guard pump(timeout: 5, until: { sink.buf.count >= 5 }), sink.buf == Array("READY".utf8) else {
        print("environmental: child shell never printed READY (got \(sink.buf.count) bytes)")
        exit(2)
    }
    // stty has run before READY is printed, but give `exec cat` a moment to be reading.
    usleep(50_000)
    sink.buf.removeAll()
    return (p, sink)
}

func appSend(_ p: LocalProcess, _ bytes: [UInt8]) {
    if injectUs > 0 {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .microseconds(injectUs)) { p.send(data: bytes[...]) }
    } else {
        p.send(data: bytes[...])
    }
}

/// Bare write(2), looping on partial writes and EAGAIN; returns false only on a hard error.
func bareWrite(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n > 0 { off += n } else if n < 0 && (errno == EAGAIN || errno == EINTR) { usleep(50) } else { return false }
    }
    return true
}

func pct(_ s: [Double], _ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * q))] }

var failures = 0

// MARK: latency

func measure(regime: String, samples: Int, gapUs: UInt32) -> (Double, Double) {
    let (p, sink) = spawnCat()
    var app: [Double] = [], raw: [Double] = []
    for i in 0..<(samples * 2) {
        let byte = UInt8(0x61 + (i / 2) % 26)
        let before = sink.buf.count
        let useApp = i % 2 == 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        if useApp { appSend(p, [byte]) } else if !bareWrite(p.childfd, [byte]) {
            print("environmental: write(2) failed errno=\(errno)"); exit(2)
        }
        guard pump(timeout: 2, until: { sink.buf.count > before }) else {
            print("environmental: no echo within 2 s (sample \(i))"); exit(2)
        }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
        if sink.buf.count != before + 1 || sink.buf[before] != byte {
            print("FAIL echo: sent \(byte), received \(Array(sink.buf[before...]))"); failures += 1
        }
        if i >= 20 { (useApp ? { app.append(us) } : { raw.append(us) })() }   // drop warm-up
        if gapUs > 0 { usleep(gapUs) }
    }
    p.terminate()
    app.sort(); raw.sort()
    func row(_ name: String, _ s: [Double]) {
        print(String(format: "  %-26@ n=%4d  p50 %8.1f  p95 %8.1f  p99 %8.1f  max %9.1f µs",
                     name, s.count, pct(s, 0.5), pct(s, 0.95), pct(s, 0.99), s.last ?? 0))
    }
    print("\(regime):")
    row("app  (LocalProcess.send)", app)
    row("floor (bare write(2))", raw)
    let d50 = pct(app, 0.5) - pct(raw, 0.5), d95 = pct(app, 0.95) - pct(raw, 0.95)
    print(String(format: "  delta (upper bound on T3.1's win): p50 %+.1f µs, p95 %+.1f µs", d50, d95))
    return (d50, d95)
}

// MARK: ordering

func orderingCase() {
    let (p, sink) = spawnCat()
    // Printable bytes only: raw mode disables ISIG/ICANON, but keep clear of control bytes.
    let paste = (0..<(256 * 1024)).map { UInt8(0x41 + $0 % 26) }
    let keys = (0..<32).map { UInt8(0x30 + $0 % 10) }
    appSend(p, paste)
    for k in keys {
        if falsifyNaive { _ = bareWrite(p.childfd, [k]) } else { appSend(p, [k]) }
    }
    let want = paste + keys
    let arrived = pump(timeout: 20, until: { sink.buf.count >= want.count })
    p.terminate()
    if arrived && sink.buf == want {
        print("ok    ordering: 256 KiB paste + 32 keys echoed in order (\(want.count) bytes)")
        return
    }
    let firstKey = sink.buf.firstIndex(where: { $0 >= 0x30 && $0 <= 0x39 })
    print("FAIL  ordering: received \(sink.buf.count)/\(want.count) bytes; first keystroke at "
        + "offset \(firstKey.map(String.init) ?? "none") (expected \(paste.count))")
    failures += 1
}

// MARK: main

loadGuard("before")
// The injected delay rides a concurrent queue, so it would reorder by construction; the
// sensitivity run measures latency only.
if injectUs == 0 { orderingCase() }
if falsifyNaive { exit(failures > 0 ? 1 : 0) }
let samples = Int(env["INPUT_LATENCY_SAMPLES"] ?? "") ?? 400
let (burst50, _) = measure(regime: "burst (no gap)", samples: samples, gapUs: 0)
let (typing50, typing95) = measure(regime: "typing (20 ms gap)", samples: samples, gapUs: 20_000)
loadGuard("after")
print("DELTA_P50_US=\(Int(max(burst50, typing50)))")
print("DELTA_TYPING_P95_US=\(Int(typing95))")
let worst = max(burst50, typing50)
print(worst >= floorUs
    ? "verdict: write-path delta \(Int(worst)) µs ≥ \(Int(floorUs)) µs floor — a patch is justified"
    : "verdict: write-path delta \(Int(worst)) µs < \(Int(floorUs)) µs floor — patch NOT justified")
exit(failures > 0 ? 1 : 0)
