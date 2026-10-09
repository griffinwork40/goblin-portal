// check-scrollback-cost-harness.swift
//
// Asserts that scrollback memory footprint and Terminal.resize cost stay below
// defined ceilings, catching regressions if scrollback semantics or CharData layout
// changes in the vendor.
//
// Linked against the vendored SwiftTerm.o (release build) by check-scrollback-cost.sh.
//
// WHY: T2.4 (best-mac-terminal roadmap) raises the default scrollback from 1000 lines
// to 5000 for agent REPL sessions. The roadmap requires measured evidence:
// (A) resident memory per 1k scrollback lines — task_info(TASK_VM_INFO).phys_footprint
//     delta, measured with a fresh terminal per size at 80 cols and 200 cols.
//     MemoryLayout<CharData>.stride × cols × lines is reported as a LOWER BOUND; the
//     measured footprint includes BufferLine object overhead and is the authoritative figure.
// (B) Terminal.resize narrow→widen cost at 1k, 3.5k, 5k, 10k, 20k lines — Buffer.resize
//     walks lines.count in the reflow path (Buffer.swift:522-531, guarded by
//     `hasScrollback` which is true for the normal buffer, Buffer.swift:419-421) so cost
//     scales O(N); at 60 fps live drag the per-frame budget is 16,700 µs.
//
// RELEASE CEILINGS — rationale and method
// Baselines measured on M4 Pro (load 0.38/CPU, release SwiftTerm.o, -O harness):
//   1k lines:  p50 ≈   483 µs, p95 ≈   561 µs
//   3.5k:      p50 ≈ 2,656 µs, p95 ≈ 3,593 µs
//   5k:        p50 ≈ 5,098 µs, p95 ≈ 5,888 µs
//   10k:       p50 ≈10,852 µs, p95 ≈11,990 µs
//   20k:       p50 ≈22,052 µs, p95 ≈22,799 µs
//
// Ceilings = 3× p95 (factor stated here so reviewers can audit the reasoning):
//   3× gives headroom for machine-to-machine variation (~2×), scheduler noise, and a
//   genuine regression of less than 2× on the O(N) walk. It is tight enough to catch
//   a quadratic regression at the 5k default or a hash/copy change in CharData: if
//   the reflow walk doubles (upstream changes to Buffer.resize), p50 at 5k moves to
//   ~10 ms, well above the 17,664 µs ceiling. The debug SwiftTerm falsification (see
//   check-scrollback-cost.sh FALSIFY=1) proves the ceilings are not vacuous:
//   1k debug p50 ≈12,900 µs exceeds the 1,683 µs ceiling by 7.7×.
//
// MEMORY metric
// task_info(TASK_VM_INFO).phys_footprint delta: process RSS including object overhead.
// MemoryLayout<CharData>.stride × cols × (scrollback+rows) is the CharData lower bound.
// Measured at 80 cols (1k, 5k, 10k) and 200 cols (1k, 5k, 10k).
// Memory ceiling: measured phys_footprint per 1k scrollback ≤ 8 MB.
//   Measured: 80 cols → 2.2 MB/1k; 200 cols → 5.4 MB/1k. Ceiling at 8 MB catches
//   a ~1.5× growth (struct field added, or layout change) before it becomes a problem.
//   A 5000-line default at 200 cols: ~27 MB phys_footprint per pane — within budget
//   for a terminal that also carries a Metal atlas (~5-10 MB).
//
// FALSIFICATION
// FALSIFY_DEBUG_TIMING=1: check-scrollback-cost.sh compiles this file against debug
//   SwiftTerm.o and passes this env var. Timing assertions run with release ceilings;
//   debug is ~25x slower so they must fail (exit 1). The shell wrapper inverts the
//   exit code: falsification success = harness exits 1. Memory assertions are skipped.
//
// LOAD GUARD: if per-CPU load > 0.70, timing exits 2, not 1 (N6 lesson from
//   check-metal-throughput.sh). Memory assertions are load-independent.
//
// Exit codes:
//   0  all assertions passed
//   1  assertion failure (ceiling breached, or falsification would not fire)
//   2  environmental (load too high for timing; memory cases still run)

import Foundation
import SwiftTerm

// MARK: — Memory measurement via task_info

func currentPhysFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard r == KERN_SUCCESS else { return 0 }
    return Int64(info.phys_footprint)
}

// MARK: — Load guard

func loadAvg1m() -> Double {
    var info = host_load_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<host_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0.0 }
    return Double(info.avenrun.0) / Double(LOAD_SCALE)
}

// MARK: — Helpers

/// Fill the terminal with `count` lines. Every 5th line is short (realistic agent-REPL
/// mix); others are full-width with bold-red SGR: ESC[1;31m + (cols-1 chars) + ESC[m.
/// Short lines: a 4-character prompt. The SGR lines exercise the Buffer reflow path most
/// aggressively since they fill exactly `cols` visible columns and trigger isWrapped.
func feedLines(_ t: Terminal, count: Int, cols: Int) {
    let sgr1 = "\u{1b}[1;31m"
    let sgr0 = "\u{1b}[m"
    let fill  = String(repeating: "a", count: max(1, cols - 1))
    for i in 0..<count {
        if i % 5 == 4 {
            t.feed(text: "$ ok\r\n")
        } else {
            t.feed(text: sgr1 + fill + sgr0 + "\r\n")
        }
    }
}

/// Sorted-array median.
func median(_ vals: [Double]) -> Double {
    guard !vals.isEmpty else { return 0 }
    let s = vals.sorted()
    let m = s.count / 2
    return s.count.isMultiple(of: 2) ? (s[m-1] + s[m]) / 2 : s[m]
}

/// Sorted-array p95.
func p95(_ vals: [Double]) -> Double {
    guard !vals.isEmpty else { return 0 }
    let s = vals.sorted()
    return s[min(Int(Double(s.count) * 0.95), s.count - 1)]
}

/// ContinuousClock.Duration → microseconds.
func toMicroseconds(_ d: Duration) -> Double {
    let (s, a) = d.components
    return Double(s) * 1_000_000.0 + Double(a) / 1_000_000_000_000.0
}

// MARK: — Constants

let falsifyDebugTiming = ProcessInfo.processInfo.environment["FALSIFY_DEBUG_TIMING"] == "1"
let termRows = 46       // realistic terminal height
let termCols = 80       // standard width
let iters    = 50       // timing iterations per case

// Memory ceiling: measured phys_footprint per 1k scrollback lines ≤ 8 MB.
// Measured: 80 cols → 2.2 MB/1k; 200 cols → 5.4 MB/1k (release SwiftTerm, 2026-10-09).
// Ceiling at 8 MB catches a ~1.5× growth before it becomes a pane-budget problem.
let memCeilingPer1kBytes: Int64 = 8 * 1024 * 1024

// Timing ceilings: 3× measured p95 on the reference machine.
// See "RELEASE CEILINGS — rationale and method" above for the factor justification.
let loadThreshold: Double = 0.70   // per CPU (N6: check-metal-throughput.sh precedent)

struct TimingCase {
    let scrollback: Int
    let p50Ceiling: Double  // µs (3 × measured p95)
}

// 3 × p95 ceilings from release measurements (2026-10-09, M4 Pro, load 0.38/CPU):
//   1k:  3 × 561  =  1,683 µs     3.5k: 3 × 3,593 = 10,779 µs
//   5k:  3 × 5,888 = 17,664 µs   10k: 3 × 11,990 = 35,970 µs
//   20k: 3 × 22,799 = 68,397 µs
let timingCases: [TimingCase] = [
    .init(scrollback:  1_000, p50Ceiling:   1_683),
    .init(scrollback:  3_500, p50Ceiling:  10_779),
    .init(scrollback:  5_000, p50Ceiling:  17_664),
    .init(scrollback: 10_000, p50Ceiling:  35_970),
    .init(scrollback: 20_000, p50Ceiling:  68_397),
]

let charDataStride = MemoryLayout<CharData>.stride

// MARK: — Memory cases

var memFailures    = 0
var timingFailures = 0
var envFailures    = 0

if !falsifyDebugTiming {
    print("CharData stride: \(charDataStride) bytes  termCols: \(termCols)  termRows: \(termRows)")
    print("Memory ceiling: \(memCeilingPer1kBytes/1024/1024) MB per 1k scrollback lines")
    print("")
    print("=== Memory footprint (task_info phys_footprint delta, fresh terminal per run) ===")
    print("cols  scrollback  stride_lb      phys_footprint   per_1k_lines     result")
    print("----- ----------  -------------- ---------------- ---------------- ------")

    for (cols, sc) in [(80,1000),(80,5000),(80,10000),(200,1000),(200,5000),(200,10000)] {
        let baseline = currentPhysFootprint()
        let h = HeadlessTerminal(
            options: TerminalOptions(cols: cols, rows: termRows, scrollback: sc)
        ) { _ in }
        let t = h.terminal!
        feedLines(t, count: sc + termRows + 20, cols: cols)
        let footprint = currentPhysFootprint()
        let delta = footprint - baseline

        let strideLb = charDataStride * cols * (sc + termRows)
        let perKBytes = delta * 1000 / Int64(sc)
        let ok = perKBytes <= memCeilingPer1kBytes

        if !ok { memFailures += 1 }

        print(String(format: "%-5d %-11d %-15@ %-17@ %-17@ %@",
                     cols, sc,
                     "\(strideLb/1024)KB" as NSString,
                     "\(delta/1024)KB" as NSString,
                     String(format: "%.1f MB/1k", Double(perKBytes)/1024.0/1024.0) as NSString,
                     (ok ? "ok" : "FAIL") as NSString))
    }
    print("")
}

// MARK: — Timing cases

print("=== Resize cost: narrow(\(termCols)→\(termCols/2)) + widen(\(termCols/2)→\(termCols)), \(iters) iterations ===")
if falsifyDebugTiming {
    print("Mode: FALSIFY_DEBUG_TIMING — ceilings are release values; debug should fail them.")
}

let load       = loadAvg1m()
let cpuCount   = ProcessInfo.processInfo.processorCount
let perCpuLoad = cpuCount > 0 ? load / Double(cpuCount) : load
let loadHigh   = perCpuLoad > loadThreshold

print(String(format: "Load: 1m=%.2f / %d CPUs = %.3f/CPU (threshold %.2f)",
             load, cpuCount, perCpuLoad, loadThreshold))

if loadHigh {
    print(String(format: "LOAD GUARD: per-CPU load %.3f > %.2f — timing skipped (exit 2 if no mem failures).",
                 perCpuLoad, loadThreshold))
    print("  Re-run when load is lower. Memory assertions are unaffected.")
    envFailures += 1
} else {
    print("scrollback   p50 µs     p95 µs     ceiling µs   p50 ok?    result")
    print("------------ ---------- ---------- ------------ ---------- ------")

    for tc in timingCases {
        let h = HeadlessTerminal(
            options: TerminalOptions(cols: termCols, rows: termRows, scrollback: tc.scrollback)
        ) { _ in }
        let t = h.terminal!
        feedLines(t, count: tc.scrollback + termRows, cols: termCols)

        // One warm-up pair to prime instruction caches.
        t.resize(cols: termCols/2, rows: termRows)
        t.resize(cols: termCols, rows: termRows)

        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<iters {
            let t0 = clock.now
            t.resize(cols: termCols/2, rows: termRows)
            t.resize(cols: termCols, rows: termRows)
            times.append(toMicroseconds(clock.now - t0))
        }

        let p50v = median(times)
        let p95v = p95(times)
        // In falsify-debug mode, p50 ceiling is the same release ceiling — debug should exceed it.
        let ok   = p50v <= tc.p50Ceiling

        if !ok { timingFailures += 1 }

        print(String(format: "%-12d  %-10.0f  %-10.0f  %-12.0f  %-10@  %@",
                     tc.scrollback, p50v, p95v, tc.p50Ceiling,
                     (ok ? "ok" : "FAIL(\(Int(p50v))µs)") as NSString,
                     (ok ? "ok" : "FAIL") as NSString))
    }
}

// MARK: — Summary

print("")
print("=== Summary ===")
if !falsifyDebugTiming {
    print("Memory assertion failures: \(memFailures)")
}
if loadHigh {
    print("Timing assertions: SKIPPED (per-CPU load \(String(format: "%.3f", perCpuLoad)) > \(loadThreshold))")
} else {
    print("Timing assertion failures: \(timingFailures)")
}

let totalAssert = memFailures + timingFailures
if totalAssert > 0 {
    if falsifyDebugTiming {
        print("RESULT: \(timingFailures) timing ceiling(s) exceeded by debug SwiftTerm — exit 1 (expected for falsification).")
    } else {
        print("RESULT: \(totalAssert) assertion failure(s) — exit 1.")
    }
    exit(1)
} else if envFailures > 0 {
    if falsifyDebugTiming {
        print("RESULT: timing skipped (high load) in falsify-debug mode — exit 2 (re-run at lower load).")
    } else {
        print("RESULT: memory ok, timing skipped (high load) — exit 2.")
    }
    exit(2)
} else {
    if falsifyDebugTiming {
        print("RESULT: all timing cases PASSED release ceilings in debug mode — ceilings are too loose.")
        print("  The falsification failed: debug SwiftTerm should have exceeded these ceilings.")
        exit(1)  // falsification failure: ceilings let everything through
    } else {
        print("RESULT: all cases passed — exit 0.")
        exit(0)
    }
}
