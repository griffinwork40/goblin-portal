// DockAttention.swift
// Pure notification parsing and external attention policy, compiled by the headless gate.
// Separate from AppKit so malformed terminal output and visibility rules are testable.
import Foundation

enum NotificationEscape {
    enum Parsed: Equatable {
        case notification(title: String, body: String)
        case progressPayload
        case ignored
    }
    static let maxPayloadBytes = 1024

    static func parseOsc9(_ data: ArraySlice<UInt8>) -> Parsed {
        // T4.3 owns progress. Check BEFORE the notification cap: long progress payloads
        // must still reach SwiftTerm, whose decoder owns their validity and clamping.
        if data.starts(with: [UInt8(ascii: "4"), UInt8(ascii: ";")]) {
            return .progressPayload
        }
        guard data.count <= maxPayloadBytes,
              let message = String(bytes: data, encoding: .utf8),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignored }
        return .notification(title: message, body: "")
    }

    static func parseOsc777(_ data: ArraySlice<UInt8>) -> Parsed {
        guard data.count <= maxPayloadBytes,
              let text = String(bytes: data, encoding: .utf8) else { return .ignored }
        // Match Terminal.swift:1842-1850: first two separators are structural.
        let parts = text.components(separatedBy: ";")
        guard parts.count >= 3, parts[0] == "notify",
              !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignored }
        return .notification(title: parts[1], body: parts[2...].joined(separator: ";"))
    }
}

struct AttentionAction: Equatable {
    let bounce: Bool
    let badgeLabel: String
    let postNotification: Bool
}

enum DockAttention {
    enum SignalKind { case bell, osc9, osc777 }

    static func badgeLabel(_ count: Int) -> String { count > 0 ? "\(count)" : "" }

    static func decide(isAppActive: Bool, isDocumentVisible: Bool,
                       attentionDocumentCount: Int, kind: SignalKind) -> AttentionAction {
        // Visibility is the same window membership + key-window predicate used by
        // CommandNotification callers. A background TAB still notifies in an active app.
        AttentionAction(bounce: !isAppActive && !isDocumentVisible,
                        badgeLabel: badgeLabel(attentionDocumentCount),
                        postNotification: !isDocumentVisible && kind != .bell)
    }
}
