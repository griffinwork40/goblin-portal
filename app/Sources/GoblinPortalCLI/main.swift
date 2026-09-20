//
//  GoblinPortalCLI/main.swift
//  Entry point for the `goblin-portal` command-line binary.
//
//  Enables `EDITOR='goblin-portal --wait'` workflows with git commit, crontab -e,
//  agent-afk Ctrl+O, and any other POSIX tool that opens $EDITOR on a file.
//
//  Usage:
//    goblin-portal <file>           Open <file> in Goblin Portal. Does not wait.
//    goblin-portal --wait <file>    Open <file> in Goblin Portal, block until the tab is closed
//                           or the file is saved-and-closed, then exit 0.
//    goblin-portal --version        Print the CLI version string.
//    goblin-portal --help           Print usage.
//
//  IPC mechanism:
//    DistributedNotificationCenter: the CLI posts
//    `com.griffinlong.goblin-portal.openFile` with a userInfo dictionary containing
//    the absolute file path and, when --wait is requested, a unique Unix
//    domain socket path the app will write "ok\n" to when the document closes.
//    If Goblin Portal.app is not running, the CLI launches it first via NSWorkspace
//    and waits up to 5 seconds for it to register its notification observer.
//

import Foundation
import AppKit  // NSWorkspace, NSRunningApplication

// MARK: - Argument parsing

var waitMode = false
var filePath: String? = nil

let args = CommandLine.arguments.dropFirst()  // drop argv[0]
var argIter = args.makeIterator()
while let arg = argIter.next() {
    switch arg {
    case "--wait", "-w":
        waitMode = true
    case "--version":
        print("goblin-portal-cli 0.3.0")
        exit(0)
    case "--help", "-h":
        printUsage()
        exit(0)
    case _ where arg.hasPrefix("-"):
        fputs("goblin-portal: unknown flag '\(arg)'\n", stderr)
        printUsage()
        exit(1)
    default:
        if filePath != nil {
            fputs("goblin-portal: too many file arguments\n", stderr)
            printUsage()
            exit(1)
        }
        filePath = arg
    }
}

guard let rawPath = filePath else {
    printUsage()
    exit(1)
}

// MARK: - Resolve and validate the file path

let resolved: String
if rawPath.hasPrefix("/") {
    resolved = rawPath
} else {
    // Relative path — resolve against cwd.
    let cwd = FileManager.default.currentDirectoryPath
    resolved = (cwd as NSString).appendingPathComponent(rawPath)
}

guard FileManager.default.fileExists(atPath: resolved) else {
    fputs("goblin-portal: file not found: \(resolved)\n", stderr)
    exit(1)
}

// MARK: - Ensure Goblin Portal.app is running

let bundleID = "com.griffinlong.goblin-portal"

func isAppRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

if !isAppRunning() {
    // Launch Goblin Portal. NSWorkspace finds it by bundle ID — no hard-coded path needed.
    // If the app is not installed, the open call fails and we exit early.
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        fputs("goblin-portal: Goblin Portal.app not found — is it installed in /Applications?\n", stderr)
        exit(1)
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    let sema = DispatchSemaphore(value: 0)
    // nonisolated(unsafe) is the Swift 6 idiom for a var written once from one
    // thread (the NSWorkspace completion handler) and read once from another
    // (the sema.wait() continuation). The semaphore provides the ordering
    // guarantee, so the access is safe even though Swift cannot prove it.
    nonisolated(unsafe) var launchError: Error? = nil
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, err in
        launchError = err
        sema.signal()
    }
    sema.wait()
    if let err = launchError {
        fputs("goblin-portal: could not launch Goblin Portal.app: \(err.localizedDescription)\n", stderr)
        exit(1)
    }
    // Wait for the app to finish launching and register its notification observer.
    // The observer is registered in applicationDidFinishLaunching, which fires on
    // the main thread after the run loop starts — typically under 1s.
    var waited = 0
    while !isAppRunning() && waited < 50 {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 1
    }
    if !isAppRunning() {
        fputs("goblin-portal: timed out waiting for Goblin Portal.app to start\n", stderr)
        exit(1)
    }
    // A short additional grace period so the distributed-notification observer is
    // registered. The app may be "running" (NSRunningApplication) before its
    // applicationDidFinishLaunching has returned.
    Thread.sleep(forTimeInterval: 0.5)
}

// MARK: - Build userInfo and socket (--wait path)

var socketPath: String? = nil
var userInfo: [String: String] = ["path": resolved]

if waitMode {
    // Unique socket per invocation: handles concurrent EDITOR calls cleanly.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("goblin-portal-wait-\(ProcessInfo.processInfo.processIdentifier).sock")
    socketPath = tmp.path
    userInfo["waitSocket"] = tmp.path
}

// MARK: - Post the open-file notification

DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name("com.griffinlong.goblin-portal.openFile"),
    object: bundleID,
    userInfo: userInfo,
    deliverImmediately: true)

// MARK: - Wait for close signal (--wait path)

guard waitMode, let sockPath = socketPath else {
    // Non-wait mode: we're done. The app will open the file in its own run loop.
    exit(0)
}

// The app will connect to this socket and write "ok\n" when the document closes.
// We listen as a Unix domain socket server (one connection expected).
let exitCode = waitForCloseSignal(socketPath: sockPath)
exit(exitCode)

// MARK: - Helpers

func printUsage() {
    let name = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "goblin-portal"
    print("""
    Usage:
      \(name) <file>          Open <file> in Goblin Portal (no wait).
      \(name) --wait <file>   Open and block until the tab is closed. Exit 0 on
                               save/close, 1 on error.
      \(name) --version       Print version.
      \(name) --help          Print this message.
    """)
}

/// Listen on a Unix domain socket at `socketPath` and block until the app
/// connects and writes the "ok\n" signal. Returns 0 on success, 1 on timeout
/// or error.
///
/// Why a socket rather than a pipe or a file? A socket is bidirectional and
/// connection-oriented, so the CLI knows the instant the app connects — no
/// polling. A named pipe (FIFO) would also work but blocks open(2) until both
/// ends are open, which creates a race if the app hasn't reached the connect
/// call yet. A file-sentinel approach requires polling and has a race between
/// the remove and the next run. The socket is the most reliable shape.
func waitForCloseSignal(socketPath: String) -> Int32 {
    // Clean up any stale socket from a previous crashed run.
    try? FileManager.default.removeItem(atPath: socketPath)

    // Create and bind the server socket.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        fputs("goblin-portal: socket() failed: \(String(cString: strerror(errno)))\n", stderr)
        return 1
    }
    defer {
        close(fd)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // sockaddr_un setup.
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        fputs("goblin-portal: socket path too long\n", stderr)
        return 1
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
        for (i, byte) in pathBytes.enumerated() {
            ptr[i] = UInt8(bitPattern: byte)
        }
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, addrLen)
        }
    }
    guard bindResult == 0 else {
        fputs("goblin-portal: bind() failed: \(String(cString: strerror(errno)))\n", stderr)
        return 1
    }
    guard listen(fd, 1) == 0 else {
        fputs("goblin-portal: listen() failed: \(String(cString: strerror(errno)))\n", stderr)
        return 1
    }

    // Set a 5-minute accept timeout so a user who just closes Goblin Portal entirely
    // without closing the tab doesn't leave a dangling CLI process forever.
    // 300s is generous — git commit typically finishes in under a minute.
    var timeout = timeval(tv_sec: 300, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var clientAddr = sockaddr_un()
    var clientLen = addrLen
    let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            accept(fd, $0, &clientLen)
        }
    }
    guard clientFd >= 0 else {
        if errno == EAGAIN || errno == EWOULDBLOCK {
            fputs("goblin-portal: timed out waiting for Goblin Portal to signal close\n", stderr)
        } else {
            fputs("goblin-portal: accept() failed: \(String(cString: strerror(errno)))\n", stderr)
        }
        return 1
    }
    defer { close(clientFd) }

    // Read the signal byte. We just need any write from the app; the content
    // is informational ("ok\n") but we don't inspect it.
    var buf = [UInt8](repeating: 0, count: 4)
    let n = read(clientFd, &buf, buf.count)
    return n > 0 ? 0 : 1
}
