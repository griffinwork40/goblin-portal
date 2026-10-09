//
//  check-tmux-directory-harness.swift
//  The assertion half of Scripts/check-tmux-directory.sh.
//
//  Not part of the app. The gate copies this to `main.swift` (top-level code is only
//  legal in a file of that name) and compiles it with `check-tmux-directory-fixtures.swift`
//  and the two shipped units, `TmuxDirectory.swift` + `TmuxDirectory+Subprocess.swift`.
//
//  Only the frozen contract (`current`, `defaultSocketDirectories`) is called, so the
//  same harness compiles against the wave-0 stub — that is how the red run was observed.
//  Every resolution goes through `resolve(...)`, which refuses any socket directory
//  outside GATE_WORK and records what it was given, so the closing isolation case can
//  prove the user's live default socket directory was never handed to the unit.
//
import Darwin
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    let extra = detail()
    print((ok ? "  ✓ " : "  ✗ ") + name + (extra.isEmpty ? "" : "   [\(extra)]"))
    if !ok { failures += 1 }
}

guard !Fixture.work.isEmpty, !Fixture.tmuxBinary.isEmpty else { Fixture.fail("GATE_WORK/GATE_TMUX unset") }
let realDefaultDir = Fixture.env["GATE_REAL_SOCKET_DIR"] ?? ""
var passedDirectories: [String] = []

func resolve(_ tty: String, _ dirs: [URL], tmux: String? = Fixture.tmuxBinary,
             timeout: TimeInterval = 1.0) -> (URL?, TimeInterval) {
    for dir in dirs {
        precondition(dir.path.hasPrefix(Fixture.work + "/"), "gate tried to probe \(dir.path)")
        passedDirectories.append(dir.path)
    }
    let start = Date()
    let answer = TmuxDirectory.current(clientTTY: tty, socketDirectories: dirs,
                                       tmuxExecutable: tmux, timeout: timeout)
    return (answer, Date().timeIntervalSince(start))
}

/// Poll until `current` reports `expected` — pane_current_path is read from the pane
/// process's cwd, so a `cd` typed via send-keys lands a few ms after send-keys returns.
func eventually(_ tty: String, _ dirs: [URL], equals expected: String) -> String {
    var last = "nil"
    for _ in 0..<100 {
        last = resolve(tty, dirs).0?.path ?? "nil"
        if last == expected { return last }
        usleep(20_000)
    }
    return last
}

let sockets = Fixture.socketDir
guard (try? FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])) != nil
else { Fixture.fail("could not create the socket directory") }
let dirA = Fixture.directory("pane-a"), dirB = Fixture.directory("pane-b")
let dirC = Fixture.directory("pane-c"), dirD = Fixture.directory("pane-d")
let dirDecoy = Fixture.directory("decoy")
let dirWeird = Fixture.directory("with space/café ☕ 日本")
let mainSock = sockets.appendingPathComponent("main")
let decoySock = sockets.appendingPathComponent("0decoy")   // sorts FIRST: a first-answer-wins bug picks it
let customSock = sockets.appendingPathComponent("my custom-sock.é")
let staleSock = sockets.appendingPathComponent("zstale")

Fixture.startServer(mainSock, in: dirA)
Fixture.startServer(decoySock, in: dirDecoy)
Fixture.startServer(customSock, in: dirWeird)
Fixture.makeStaleSocket(staleSock, scratch: dirA)
let main = Fixture.Client(attachingTo: mainSock)
let decoy = Fixture.Client(attachingTo: decoySock)
let custom = Fixture.Client(attachingTo: customSock)
let all = [sockets]
print("fixtures: main=\(main.tty) decoy=\(decoy.tty) custom=\(custom.tty), 4 sockets (1 stale)")

print("ACTIVE PANE — a real client on a real pty")
check("the attached client's pane directory", resolve(main.tty, all).0?.path == normalised(dirA),
      resolve(main.tty, all).0?.path ?? "nil")
let raw: String? = Fixture.tmux(mainSock, ["display-message", "-p", "-c", main.tty, "#{pane_current_path}"]).1
check("tmux's raw answer is NOT already normalised (so normalisation is exercised)",
      raw != nil && raw != normalised(dirA), raw ?? "nil")

Fixture.tmux(mainSock, ["new-window", "-c", dirB.path])
check("new-window: the new active window's directory", eventually(main.tty, all, equals: normalised(dirB))
      == normalised(dirB))
Fixture.tmux(mainSock, ["select-window", "-t", "gate:0"])
check("select-window back to window 0", eventually(main.tty, all, equals: normalised(dirA)) == normalised(dirA))
Fixture.tmux(mainSock, ["select-window", "-t", "gate:1"])
Fixture.tmux(mainSock, ["send-keys", "-t", "gate:1.0", "cd '\(dirC.path)'", "Enter"])
check("cd inside the pane (send-keys)", eventually(main.tty, all, equals: normalised(dirC)) == normalised(dirC))

Fixture.tmux(mainSock, ["split-window", "-t", "gate:1", "-c", dirD.path])
check("split-window: the new (active) pane wins", eventually(main.tty, all, equals: normalised(dirD))
      == normalised(dirD))
Fixture.tmux(mainSock, ["select-pane", "-t", "gate:1.0"])
check("select-pane back to the first pane", eventually(main.tty, all, equals: normalised(dirC))
      == normalised(dirC))

print("OWNERSHIP — the decoy server in the same directory is never chosen")
check("decoy's own client resolves to the decoy (positive control)",
      resolve(decoy.tty, all).0?.path == normalised(dirDecoy))
check("main's client never gets the decoy's directory", resolve(main.tty, all).0?.path == normalised(dirC))
var unownedMaster: Int32 = -1, unownedSlave: Int32 = -1
guard openpty(&unownedMaster, &unownedSlave, nil, nil, nil) == 0, let unownedName = ttyname(unownedSlave)
else { Fixture.fail("openpty for the unowned tty") }
let unowned = String(cString: unownedName)
check("a tty no server owns → nil (tmux itself answers with ANOTHER client here)",
      resolve(unowned, all).0 == nil, resolve(unowned, all).0?.path ?? "nil")
check("a relative tty → nil", resolve("ttys000", all).0 == nil)

print("CUSTOM SOCKET NAME, SPACES AND UNICODE")
check("socket 'my custom-sock.é', path 'with space/café ☕ 日本'",
      resolve(custom.tty, all).0?.path == normalised(dirWeird), resolve(custom.tty, all).0?.path ?? "nil")
check("tmuxExecutable nil finds tmux without PATH help", TmuxDirectory.current(
    clientTTY: custom.tty, socketDirectories: { passedDirectories.append(sockets.path); return all }(),
    tmuxExecutable: nil, timeout: 1)?.path == normalised(dirWeird))
Fixture.tmux(customSock, ["detach-client", "-t", custom.tty])
for _ in 0..<100 where !Fixture.tmux(customSock, ["list-clients", "-F", "#{client_tty}"]).1.isEmpty { usleep(10_000) }
check("detached client → nil", resolve(custom.tty, all).0 == nil, resolve(custom.tty, all).0?.path ?? "nil")

print("NO ANSWER — stale, empty, missing")
let staleOnly = Fixture.directory("stale-only")
Fixture.makeStaleSocket(staleOnly.appendingPathComponent("dead"), scratch: dirA)
let (staleAnswer, staleTime) = resolve(main.tty, [staleOnly])
check("stale socket (server dead) → nil, fast", staleAnswer == nil && staleTime < 0.5, "\(staleTime)s")
check("zero sockets → nil", resolve(main.tty, [Fixture.directory("empty")]).0 == nil)
check("socket directory missing → nil",
      resolve(main.tty, [URL(fileURLWithPath: Fixture.work + "/nope")]).0 == nil)
check("missing executable → nil", resolve(main.tty, all, tmux: Fixture.work + "/no-such-tmux").0 == nil)
let notExec = Fixture.directory("plain").appendingPathComponent("tmux")
FileManager.default.createFile(atPath: notExec.path, contents: Data("x".utf8))
check("non-executable file as tmux → nil", resolve(main.tty, all, tmux: notExec.path).0 == nil)

print("MALFORMED / HOSTILE tmux OUTPUT (fake binaries; $7 is the client tty)")
let one = [staleOnly]   // one socket file; the fakes ignore it
check("relative path → nil",
      resolve(main.tty, one, tmux: Fixture.fake("rel", "printf '%s\\nrel/dir\\n' \"$7\"")).0 == nil)
check("empty output → nil", resolve(main.tty, one, tmux: Fixture.fake("empty", "exit 0")).0 == nil)
check("right output but non-zero exit → nil",
      resolve(main.tty, one, tmux: Fixture.fake("exit1", "printf '%s\\n/tmp\\n' \"$7\"; exit 1")).0 == nil)
let claim = Fixture.fake("claim", "printf '%s\\n/private/tmp\\n' \"$7\"")
check("one claimant → its path, normalised (positive control)",
      resolve(main.tty, one, tmux: claim).0?.path == normalised(URL(fileURLWithPath: "/private/tmp")))
let twoSockets = [staleOnly, Fixture.directory("stale-two")]
Fixture.makeStaleSocket(twoSockets[1].appendingPathComponent("dead2"), scratch: dirA)
check("two servers both claim the tty → nil", resolve(main.tty, twoSockets, tmux: claim).0 == nil)
let (flood, floodTime) = resolve(main.tty, one, tmux: Fixture.fake(
    "flood", "head -c 2000000 /dev/zero | tr '\\0' 'x'"), timeout: 2)
check("2 MB of stdout → nil, killed at the cap not the deadline", flood == nil && floodTime < 1, "\(floodTime)s")
let (noisy, noisyTime) = resolve(main.tty, one, tmux: Fixture.fake(
    "noisy", "head -c 300000 /dev/zero | tr '\\0' 'e' >&2; printf '%s\\n/private/tmp\\n' \"$7\""), timeout: 2)
check("300 KB of stderr is drained, answer still arrives", noisy != nil && noisyTime < 1, "\(noisyTime)s")

print("DEADLINE — overall, not per socket, and nothing survives it")
let pidFile = Fixture.work + "/sleeper.pid"
let sleeper = Fixture.fake("sleeper", "sleep 3 & echo $! > '\(pidFile)'; wait")
let (slept, sleptTime) = resolve(main.tty, one, tmux: sleeper, timeout: 0.3)
check("sleeping tmux → nil within timeout + 150 ms", slept == nil && sleptTime < 0.45, "\(sleptTime)s")
let grandchild = pid_t((try? String(contentsOfFile: pidFile, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
for _ in 0..<50 where grandchild > 0 && kill(grandchild, 0) == 0 { usleep(10_000) }
check("its grandchild (which held the pipes) was killed too", grandchild > 0 && kill(grandchild, 0) != 0,
      "pid \(grandchild)")
let three = [staleOnly, twoSockets[1], Fixture.directory("stale-three")]
Fixture.makeStaleSocket(three[2].appendingPathComponent("dead3"), scratch: dirA)
let (overall, overallTime) = resolve(main.tty, three, tmux: sleeper, timeout: 0.3)
check("3 sleeping sockets share ONE 0.3 s deadline", overall == nil && overallTime < 0.45, "\(overallTime)s")
let (zero, zeroTime) = resolve(main.tty, all, timeout: 0)
check("timeout 0 → nil immediately", zero == nil && zeroTime < 0.05, "\(zeroTime)s")

print("defaultSocketDirectories")
check("TMUX_TMPDIR set", TmuxDirectory.defaultSocketDirectories(environment: ["TMUX_TMPDIR": "/x/y"], uid: 501)
      .map(\.path) == ["/x/y/tmux-501"])
check("TMUX_TMPDIR empty", TmuxDirectory.defaultSocketDirectories(environment: ["TMUX_TMPDIR": ""], uid: 77)
      .map(\.path) == ["/private/tmp/tmux-77"])
check("TMUX_TMPDIR absent", TmuxDirectory.defaultSocketDirectories(environment: [:], uid: 501)
      .map(\.path) == ["/private/tmp/tmux-501"])

/// 40 resolutions; prints median and max. Printed, not asserted: a loaded machine is not
/// a defect, and the deadline cases above already bound the worst case.
func timing(_ label: String, _ tty: String, _ dirs: [URL]) {
    var times: [Double] = []
    for _ in 0..<40 { let (url, time) = resolve(tty, dirs); if url != nil { times.append(time * 1000) } }
    times.sort()
    check("\(label): all 40 resolved", times.count == 40, "\(times.count)")
    if !times.isEmpty {
        print(String(format: "  timing \(label): median %.1f ms, max %.1f ms",
                     times[times.count / 2], times[times.count - 1]))
    }
}
print("TIMING")
let soloDir = Fixture.directory("solo")
let soloSock = soloDir.appendingPathComponent("s")
Fixture.startServer(soloSock, in: dirA)
let solo = Fixture.Client(attachingTo: soloSock)
timing("1 socket (the common case)", solo.tty, [soloDir])
timing("4 sockets (1 stale, 1 decoy, 1 detached)", main.tty, all)

print("ISOLATION AND HYGIENE")
for client in [main, decoy, custom, solo] { client.terminate() }
var status: Int32 = 0
check("no zombie or live child left behind", waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD)
check("every directory passed to current() is under GATE_WORK",
      passedDirectories.allSatisfy { $0.hasPrefix(Fixture.work + "/") })
check("the real default socket dir was never passed",
      !realDefaultDir.isEmpty && !passedDirectories.contains { normalised(URL(fileURLWithPath: $0))
          == normalised(URL(fileURLWithPath: realDefaultDir)) })

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
