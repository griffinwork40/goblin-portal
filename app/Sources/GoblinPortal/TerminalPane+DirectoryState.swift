// SKELETON for the red run — replaced by the implementation.
import AppKit

struct TmuxClientKey: Equatable {
    let pid: pid_t
    let tty: String
}

struct TmuxCacheEntry: Equatable {
    let key: TmuxClientKey
    let directory: URL?
    let sampledAt: TimeInterval
    let generation: Int
}

@MainActor
final class PaneDirectoryState {
    var tmuxCache: TmuxCacheEntry?
    var tmuxGeneration = 0
    var tmuxQueriesStarted = 0
}

@MainActor
extension TerminalPane {
    var directoryState: PaneDirectoryState {
        if let s = objc_getAssociatedObject(self, &directoryStateKey) as? PaneDirectoryState { return s }
        let s = PaneDirectoryState()
        objc_setAssociatedObject(self, &directoryStateKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }
    func deliverTmuxDirectory(_ directory: URL?, for key: TmuxClientKey, generation: Int) {}
}
nonisolated(unsafe) private var directoryStateKey: UInt8 = 0
