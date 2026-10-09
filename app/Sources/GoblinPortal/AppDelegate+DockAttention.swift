// AppDelegate+DockAttention.swift
// Executes external attention policy and derives the Dock badge from live documents.
// Kept beside the delegate because AppDelegate.swift is at its file-size ceiling.
import AppKit

@MainActor
extension AppDelegate {
    func applicationDidBecomeActive(_ notification: Notification) {
        recountAndUpdateBadge()
    }

    func dockAttentionSignal(kind: DockAttention.SignalKind, title: String, body: String,
                             isDocumentVisible: Bool) {
        let action = DockAttention.decide(isAppActive: NSApp.isActive,
            isDocumentVisible: isDocumentVisible,
            attentionDocumentCount: attentionDocumentCount(), kind: kind)
        NSApp.dockTile.badgeLabel = action.badgeLabel.isEmpty ? nil : action.badgeLabel
        if action.bounce { NSApp.requestUserAttention(.informationalRequest) }
        if action.postNotification {
            CommandNotification.postEscapeNotification(title: title, body: body,
                                                       isActiveDocument: isDocumentVisible)
        }
    }

    func attentionDocumentCount() -> Int {
        SpaceWindowController.open.flatMap { controller in
            controller.space.allDocuments + controller.space.splitPeers.values.flatMap(\.allPeerDocuments)
        }.filter { $0.documentStatus == .attention }.count
    }

    func recountAndUpdateBadge() {
        let badge = DockAttention.badgeLabel(attentionDocumentCount())
        NSApp.dockTile.badgeLabel = badge.isEmpty ? nil : badge
    }
}

@MainActor
extension SpaceViewController {
    // Called from syncDocumentChrome, the common funnel for status changes, selection,
    // and removal (SpaceViewController.swift:268). Split peers are not in documents[].
    // Clear only attention on visible peers, not running/failed outcomes, and never
    // clear marks in background windows. Status callbacks can re-enter this method;
    // setting idle first makes that recursion finite and the final recount authoritative.
    func syncDockAttention() {
        if view.window?.isKeyWindow == true, let active = activeDocument {
            for peer in allSplitDocuments(for: active) where peer.documentStatus == .attention {
                peer.clearAttention()
            }
        }
        (NSApp.delegate as? AppDelegate)?.recountAndUpdateBadge()
    }
}
