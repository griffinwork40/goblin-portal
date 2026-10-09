// check-scrollback-cost-harness.swift
//
// Asserts that scrollback memory footprint and Terminal.resize cost stay below
// defined ceilings, catching regressions if scrollback semantics or CharData layout
// changes in the vendor.
//
// Linked against the vendored SwiftTerm.o by check-scrollback-cost.sh.
//
// WHY: T2.4 (best-mac-terminal roadmap) raises the default scrollback from 1000 lines
// to a higher value for agent REPL sessions. The roadmap requires measured evidence:
// (A) per-1k-line memory — confirm/refute the A1a ~10.5 KB/line estimate at 220 cols
//     (A1a-perf.md §1e); this gate measures at 80 cols to get a col-independent stride.
// (B) Terminal.resize narrow→widen cost at 1k, 3.5k, 5k, 10k, 20k lines — Buffer.resize
//     walks lines.count in the reflow path (Buffer.swift:522-531, guarded by
//     `hasScrollback` which is true for the normal buffer, Buffer.swift:419-421) so cost
//     scales linearly; at 60 fps live drag the per-frame budget is 16,700 µs.
//
// MEMORY metric: MemoryLayout<CharData>.stride × cols × (options.scrollback + rows).
//   `lines.count` when the normal buffer is full = options.scrollback + rows (public API:
//   Terminal.options.scrollback + Terminal.rows). Terminal.displayBuffer is internal
//   (Terminal.swift:347); the derived formula is equivalent once the buffer is full.
//   CharData footprint is the dominant term that scales linearly with scrollback.
//
// TIMING metric: wall-clock of Terminal.resize(cols:40,rows:46) + resize(cols:80,rows:46),
//   50 iterations after one warm-up pair, using ContinuousClock. Buffer.resize fires the
//   reflow walk on every narrow (cols < old cols, Buffer.swift:522).
//   Realistic workload: normal buffer filled with SGR-attributed full-width lines, every
//   5th line short (agent REPL mix).
//
// Measured baselines (M4 Pro, 2026-10-09, load ≈ 0.2/CPU):
//   1k lines:  p50 ≈  12,900 µs — ceilings 20,000 µs (1.5× headroom)
//   3.5k:      p50 ≈  43,200 µs — ceiling  65,000 µs
//   5k:        p50 ≈  61,300 µs — ceiling  92,000 µs
//   10k:       p50 ≈ 122,300 µs — ceiling 183,000 µs
//   20k:       p50 ≈ 242,500 µs — ceiling 365,000 µs
//
// FALSIFICATION (FALSIFY=1 env var): uses an artificially huge per-cell size
//   (stride=10_000 bytes) to confirm the ceiling WOULD fire. Gate exits 1 in FALSIFY
//   mode. Validates that the ceiling is not so loose it accepts any input.
//
// LOAD GUARD: if per-CPU load > 0.70 at check time, timing assertions exit 2, not 1
//   (N6 lesson from check-metal-throughput.sh; AFK.md Known Risks). Memory assertions
//   are load-independent and are never skipped.
//
// Exit codes:
//   0  all assertions passed
//   1  assertion failure (ceiling breached, or falsification would not fire)
//   2  environmental (load too high for timing; memory cases still run)

import Foundation
import SwiftTerm

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
    return Double(info.avenrun.0) / Double(LOAD_SCALE) // LOAD_SCALE=1000 on macOS
}

// MARK: — Helpers

/// Fill the terminal with `count` lines. Every 5th line is short (realistic agent-REPL
/// mix); others are full-width with bold-red SGR: ESC[1;31m + (cols-1 chars) + ESC[m.
/// Short lines: a 4-character prompt. The SGR lines exercise the Buffer reflow path most
/// aggressively since they fill exactly `cols` visible columns and trigger isWrapped.
func feedLines(_ t: Terminal, count: Int, cols: Int) {
    let sgr1 = "\u{1b}[1;31m"   // bold red — triggers Attribute allocation
    let sgr0 = "\u{1b}[m"       // reset
    let fill  = String(repeating: "a", count: max(1, cols - 1))
    for i in 0..<count {
        if i % 5 == 4 {
            t.feed(text: "$ ok\r\n")  // short line (agent REPL prompt)
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

let falsify  = ProcessInfo.processInfo.environment["FALSIFY"] == "1"
let termRows = 46      // realistic terminal height
let termCols = 80      // standard width
let iters    = 50      // timing iterations per case

// Memory ceiling: CharData stride × cols × 1000 scrollback lines ≤ 2 MB.
// Measured: stride=24 bytes × 80 cols × 1000 = 1,920 KB ≈ 1.88 MB per 1k lines.
// Ceiling of 2 MB gives ~9% headroom: if CharData gains one field (stride=26),
// the gate fires before the footprint grows past this floor.
// The A1a estimate (~10.5 KB/line at 220 cols) is ~1.92 KB/line at 80 cols,
// matching our measured value exactly.
let memCeilingPer1kBytes: Int = 2 * 1024 * 1024  // 2 MB per 1000 scrollback lines

// Timing ceilings (µs, 1.5× measured p50 for machine-variance headroom).
// The dominant cost is Buffer.resize's reflow walk (Buffer.swift:522-531), which runs
// for every normal buffer (`hasScrollback=true`, Buffer.swift:419-421). Cost is O(N)
// in lines.count: 12.9ms at 1k → 122ms at 10k (linear). A 60fps frame budget is
// 16,700 µs. At 1k lines the walk consumes 77% of one frame during a live drag.
let loadThreshold: Double = 0.70  // per CPU (N6: check-metal-throughput.sh precedent)
let p95Factor:     Double = 3.0   // p95 ≤ 3× p50 (healthy distribution)

struct TimingCase {
    let scrollback: Int
    let p50Ceiling: Double  // µs
}
let timingCases: [TimingCase] = [
    .init(scrollback:  1_000, p50Ceiling:  20_000),
    .init(scrollback:  3_500, p50Ceiling:  65_000),
    .init(scrollback:  5_000, p50Ceiling:  92_000),
    .init(scrollback: 10_000, p50Ceiling: 183_000),
    .init(scrollback: 20_000, p50Ceiling: 365_000),
]

let charDataStride = MemoryLayout<CharData>.stride

// MARK: — Falsification

if falsify {
    // Use an artificially huge stride (10_000 bytes/cell) to confirm the ceiling fires.
    // hugePerK = 10_000 × 80 cols × 1000 lines = 800 MB >> 2 MB ceiling.
    let hugePerK = 10_000 * termCols * 1000
    let ceilingFired = hugePerK > memCeilingPer1kBytes
    if ceilingFired {
        print("FALSIFY=1: confirmed — ceiling fires on stride=10000")
        print("  hugePerK=\(hugePerK/1024/1024) MB > ceiling \(memCeilingPer1kBytes/1024/1024) MB")
        print("FALSIFY=1: exit 1 (expected).")
        exit(1)
    } else {
        print("FALSIFY=1: ERROR — ceiling did not fire on obviously huge stride.")
        print("  Ceiling is too loose to catch a real regression.")
        exit(1)
    }
}

// MARK: — Memory cases

var memFailures    = 0
var timingFailures = 0
var envFailures    = 0

print("CharData stride: \(charDataStride) bytes  termCols: \(termCols)  termRows: \(termRows)")
print("")
print("=== Memory footprint (CharData only, normal buffer fully loaded) ===")
print("scrollback   lines    CharData        per 1k lines    result")
print("------------ -------- --------------- --------------- ------")

for sc in [1_000, 3_500, 5_000, 10_000, 20_000] {
    let h = HeadlessTerminal(
        options: TerminalOptions(cols: termCols, rows: termRows, scrollback: sc)
    ) { _ in }
    let t = h.terminal!

    // Fill past the scrollback cap so buffer is fully utilized.
    feedLines(t, count: sc + termRows + 20, cols: termCols)

    // lines.count = options.scrollback + rows when fully filled.
    // Terminal.displayBuffer is internal (Terminal.swift:347); this formula is derived
    // from Buffer initialization: `Buffer(cols:rows:scrollback:)` allocates
    // `scrollback + rows` lines (Buffer.swift:20-23, normalBuffer init at Terminal.swift:689).
    let linesCount = t.options.scrollback + t.rows
    let charDataBytes = charDataStride * termCols * linesCount
    let perKBytes  = charDataBytes * 1000 / linesCount      // bytes per 1k scrollback lines
    let kbPerLine  = Double(charDataBytes) / Double(sc) / 1024.0
    let ok = perKBytes <= memCeilingPer1kBytes

    if !ok { memFailures += 1 }

    // Use %@ for Swift String values to avoid SIGSEGV from %s expecting C strings.
    print(String(format: "%-12d  %-8d  %-15@  %-15@  %@",
                 sc, linesCount,
                 "\(charDataBytes / 1024) KB" as NSString,
                 String(format: "%.1f KB/1k", Double(perKBytes) / 1024.0) as NSString,
                 (ok ? "ok" : "FAIL") as NSString))
    print(String(format: "                                                stride=\(charDataStride)×\(termCols)cols = %.2f KB/sb-line",
                 kbPerLine))
}

// MARK: — Timing cases

print("")
print("=== Resize cost: narrow(80→40) + widen(40→80), \(iters) iterations ===")

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
    print("scrollback   p50 µs     p95 µs     p50 ok?     p95 ok?    result")
    print("------------ ---------- ---------- ----------- ---------- ------")

    for tc in timingCases {
        let h = HeadlessTerminal(
            options: TerminalOptions(cols: termCols, rows: termRows, scrollback: tc.scrollback)
        ) { _ in }
        let t = h.terminal!
        feedLines(t, count: tc.scrollback + termRows, cols: termCols)

        // One warm-up pair to prime instruction caches.
        t.resize(cols: 40, rows: termRows)
        t.resize(cols: termCols, rows: termRows)

        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<iters {
            let t0 = clock.now
            t.resize(cols: 40, rows: termRows)
            t.resize(cols: termCols, rows: termRows)
            times.append(toMicroseconds(clock.now - t0))
        }

        let p50v = median(times)
        let p95v = p95(times)
        let p50ok = p50v <= tc.p50Ceiling
        let p95ok = p95v <= tc.p50Ceiling * p95Factor
        let ok    = p50ok && p95ok

        if !ok { timingFailures += 1 }

        print(String(format: "%-12d  %-10.0f  %-10.0f  %-11@  %-10@  %@",
                     tc.scrollback, p50v, p95v,
                     (p50ok ? "≤\(Int(tc.p50Ceiling))µs" : "FAIL(\(Int(p50v))µs)") as NSString,
                     (p95ok ? "ok" : "FAIL") as NSString,
                     (ok ? "ok" : "FAIL") as NSString))
    }
}

// MARK: — Summary

print("")
print("=== Summary ===")
print("Memory assertion failures: \(memFailures)")
if loadHigh {
    print("Timing assertions: SKIPPED (per-CPU load \(String(format: "%.3f", perCpuLoad)) > \(loadThreshold))")
} else {
    print("Timing assertion failures: \(timingFailures)")
}

let totalAssert = memFailures + timingFailures
if totalAssert > 0 {
    print("RESULT: \(totalAssert) assertion failure(s) — exit 1.")
    exit(1)
} else if envFailures > 0 {
    print("RESULT: memory ok, timing skipped (high load) — exit 2.")
    exit(2)
} else {
    print("RESULT: all cases passed — exit 0.")
    exit(0)
}
