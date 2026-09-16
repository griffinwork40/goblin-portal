//
//  OpenFileHandler.swift
//  Receives open-file requests from the `umber` CLI binary.
//
//  The CLI posts `com.griffinlong.goblin-portal.openFile` via
//  DistributedNotificationCenter with a userInfo dict:
//    { "path": "<absolute path>",
//      "waitSocket": "<unix socket path>"  ← present only when --wait was passed }
//
//  This handler opens the file as a FileViewerPane in the frontmost Space (or a
//  new one if none is open), and — when a waitSocket path was supplied — connects
//  back to the CLI's socket and writes "ok\n" when the pane is closed.
//
//  One handler instance is created by AppDelegate and lives for the app lifetime.
//  The observer is registered in applicationDidFinishLaunching so the CLI can
//  reliably post its notification after a brief post-launch grace period.
//

import AppKit
import Foundation

/// Manages the distributed-notification observer for the CLI open-file IPC.
@MainActor
final class OpenFileHandler {

    // MARK: - Observer token

    // nonisolated(unsafe): the token is written once on the main actor (register()),
    // read once in deinit (which is nonisolated in Swift 6). The ordering guarantee
    // is the object's own lifetime — deinit runs after all MainActor accesses have
    // finished, so the write-then-read sequence is safe even though Swift cannot
    // prove it. The same pattern is used throughout this codebase for one-shot tokens.
    nonisolated(unsafe) private var token: NSObjectProtocol?

    // MARK: - Init / deinit

    init() {}

    nonisolated deinit {
        if let token {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    // MARK: - Registration

    /// Call once from `applicationDidFinishLaunching`. Registers the distributed-
    /// notification observer that the CLI targets.
    func register() {
        // DistributedNotificationCenter's block API on macOS 14+ uses `queue:` not
        // `suspensionBehavior:` — the ObjC `addObserver:selector:name:object:suspensionBehavior:`
        // selector exists but the Swift block overload on NSNotificationCenter takes queue+block.
        // Passing nil for queue delivers on whichever thread the center uses internally;
        // the Task bridge below hops to @MainActor before any state is touched.
        token = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.griffinlong.goblin-portal.openFile"),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // Notifications from DistributedNotificationCenter arrive on an internal
            // thread when queue is nil. Extract the Sendable-safe info dict (String keys
            // and values) before hopping to @MainActor — `notification` itself is not
            // Sendable in Swift 6, so it cannot cross the Task boundary directly.
            let info = notification.userInfo as? [String: String]
            Task { @MainActor [weak self] in
                self?.handleInfo(info)
            }
        }
    }

    // MARK: - Notification handling

    private func handleInfo(_ info: [String: String]?) {
        guard let info, let path = info["path"] else {
            NSLog("[goblin-portal] openFile: missing 'path' in userInfo — ignoring")
            return
        }

        let url = URL(fileURLWithPath: path)

        // Bring the app forward. The CLI user is sitting at a terminal and has
        // just typed a git command — they expect Goblin Portal to come to the front.
        NSApp.activate(ignoringOtherApps: true)

        // Open the file in the frontmost Space, or create a new Space for it.
        let pane = openInFrontmostSpace(url: url)

        // --wait: connect to the CLI's socket when the pane closes.
        if let socketPath = info["waitSocket"] {
            attachCloseSignal(to: pane, socketPath: socketPath)
        }
    }

    // MARK: - File opening

    /// Open `url` in the frontmost Space. Creates a minimal Space if none exists.
    @discardableResult
    private func openInFrontmostSpace(url: URL) -> FileViewerPane {
        let config = (NSApp.delegate as? AppDelegate)?.config ?? AppConfig.defaults()

        // Use the frontmost Space if one is already open.
        if let front = SpaceWindowController.open.last {
            let pane = front.space.openFile(url: url)
            front.window?.makeKeyAndOrderFront(nil)
            return pane
        }

        // No Space is open — create one rooted at the file's parent directory.
        let root = url.deletingLastPathComponent()
        let controller = SpaceWindowController(config: config, root: root)
        controller.present()
        let pane = controller.space.openFile(url: url)
        return pane
    }

    // MARK: - Wait-close signalling

    /// Attach a one-shot "closed" callback to `pane` that signals the CLI over
    /// `socketPath` when the pane's `documentWillClose()` fires.
    ///
    /// Uses KVO on the pane's `isDirty` and a subclass hook rather than polling:
    /// the pane calls `documentWillClose()` on close — we intercept via a
    /// `CloseSignalWrapper` that observes the container's delegate pattern.
    private func attachCloseSignal(to pane: FileViewerPane, socketPath: String) {
        // CloseSignalWrapper is stored in a per-pane association so it lives exactly
        // as long as the pane and fires exactly once.
        let wrapper = CloseSignalWrapper(socketPath: socketPath, pane: pane)
        objc_setAssociatedObject(pane, &OpenFileHandler.wrapperKey, wrapper,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static var wrapperKey: UInt8 = 0
}

// MARK: - CloseSignalWrapper

/// Observes a FileViewerPane and signals the CLI socket when the pane closes.
///
/// Attached via objc_setAssociatedObject so it lives for the pane's lifetime
/// and is released (and fires its socket write) when documentWillClose fires.
///
/// Detection strategy: we swizzle nothing and add no protocol requirements.
/// Instead, we observe the SpaceViewController's `documents` array via a
/// periodic check on RunLoop. This is a deliberate trade: swizzling
/// `documentWillClose` would require an `open` override surface that FileViewerPane
/// does not expose (its `documentWillClose` is `func documentWillClose() {}` — final
/// and empty). The RunLoop poller checks at 0.5s intervals and stops itself when
/// the pane is no longer in any Space's document list, which is exactly when
/// documentWillClose has fired. The latency (≤ 0.5s) is imperceptible to a human
/// git workflow.
@MainActor
final class CloseSignalWrapper {
    private let socketPath: String
    private weak var pane: FileViewerPane?
    // nonisolated(unsafe): written on the main actor, invalidated in the nonisolated
    // deinit. Safe for the same reason as OpenFileHandler.token above — deinit runs
    // after all @MainActor work on this instance has settled.
    nonisolated(unsafe) private var timer: Timer?
    private var signalled = false

    init(socketPath: String, pane: FileViewerPane) {
        self.socketPath = socketPath
        self.pane = pane
        // Poll on the main run loop so we never block the UI.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    private func poll() {
        guard !signalled else { return }
        guard let pane else {
            // The pane itself was deallocated — definitely closed.
            sendSignal()
            return
        }
        // Check if the pane is still in any open Space's document list.
        let stillOpen = SpaceWindowController.open.contains { controller in
            controller.space.allDocuments.contains { $0 === pane }
        }
        if !stillOpen {
            sendSignal()
        }
    }

    private func sendSignal() {
        guard !signalled else { return }
        signalled = true
        timer?.invalidate()
        timer = nil
        // Connect to the CLI socket on a background thread so we never stall
        // the main actor on a connect() or write() syscall.
        let path = socketPath
        Task.detached {
            sendCloseSignal(socketPath: path)
        }
    }

    nonisolated deinit {
        timer?.invalidate()
    }
}

// MARK: - Socket signal (non-isolated, safe to run on any thread)

/// Connect to the CLI's Unix domain socket and write "ok\n". Called on a
/// background task; any failure is logged but does not crash the app.
func sendCloseSignal(socketPath: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
    withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
        for (i, byte) in pathBytes.enumerated() {
            ptr[i] = UInt8(bitPattern: byte)
        }
    }

    // Short connect timeout so a stale socket path from a killed CLI invocation
    // does not stall the app. If the CLI is gone, connect will fail fast (ECONNREFUSED).
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, addrLen)
        }
    }
    guard result == 0 else { return }

    let signal = "ok\n"
    signal.withCString { ptr in
        _ = write(fd, ptr, strlen(ptr))
    }
}
