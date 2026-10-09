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
        // Ignore ConEmu/iTerm2 numeric subcommands: `9;N;…` where N is a decimal
        // integer followed immediately by a semicolon. These include:
        //   9;1;    ConEmu "Is ConEmu" query
        //   9;2;    ConEmu "print to prompt"
        //   9;9;<cwd>  ConEmu "set cwd" (emitted by many prompts on every prompt draw)
        // A message that STARTS with digits but has no semicolon after them (e.g.
        // "42 tests passed") is a normal notification and must reach the user.
        // The `4;` prefix check above already handles progress before we get here,
        // so this guard filters everything else that looks like `<digit+>;`.
        if isNumericSubcommand(data) { return .ignored }
        guard data.count <= maxPayloadBytes,
              let message = String(bytes: data, encoding: .utf8),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignored }
        return .notification(title: message, body: "")
    }

    /// True when `data` matches the pattern `^[0-9]+;` — a decimal integer prefix
    /// immediately followed by a semicolon. `4;` is already handled before this call.
    private static func isNumericSubcommand(_ data: ArraySlice<UInt8>) -> Bool {
        var i = data.startIndex
        var hasDigit = false
        while i < data.endIndex {
            let b = data[i]
            if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") {
                hasDigit = true
                i = data.index(after: i)
            } else if b == UInt8(ascii: ";") && hasDigit {
                return true   // matched `<digit+>;`
            } else {
                return false  // non-digit, non-semicolon → not a numeric subcommand
            }
        }
        return false  // digits only, no semicolon → not a subcommand
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
