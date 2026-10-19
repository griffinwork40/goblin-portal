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
    // Separate caps for the human-visible fields posted to UNMutableNotificationContent.
    // A 1024-byte raw payload can carry much more text than a notification banner should
    // display; macOS silently truncates long strings in unpredictable places. 64 chars
    // covers any realistic command name or tool output prefix; 256 covers a meaningful
    // body snippet. Applied AFTER stripping so counts reflect displayable characters.
    static let maxTitleChars = 64
    static let maxBodyChars  = 256

    /// Strip C0 control characters (U+0000–U+001F, excluding tab U+0009), DEL (U+007F),
    /// and C1 controls (U+0080–U+009F) from notification text, then apply length cap.
    /// Rationale (issue #230, finding R1.6): any program in a pane can embed arbitrary
    /// escape sequences or NUL bytes in an OSC 9/777 payload. Those bytes pass through
    /// UTF-8 decoding intact and, without this filter, reach UNMutableNotificationContent
    /// title/body verbatim — where they can confuse notification rendering or carry
    /// embedded escape sequences that some renderers interpret. Tab is preserved because
    /// it is printable-intent whitespace; all other C0/DEL/C1 scalars are replaced with
    /// U+FFFD (REPLACEMENT CHARACTER) so stripping is visible on inspection.
    static func stripControlCharacters(_ s: String, maxChars: Int) -> String {
        var out = String()
        out.reserveCapacity(min(s.unicodeScalars.count, maxChars))
        var count = 0
        for scalar in s.unicodeScalars {
            guard count < maxChars else { break }
            let v = scalar.value
            // Keep tab (U+0009); replace all other C0 (U+0000–U+001F), DEL (U+007F),
            // and C1 (U+0080–U+009F).
            if (v < 0x0020 && v != 0x0009) || v == 0x007F || (v >= 0x0080 && v <= 0x009F) {
                out.unicodeScalars.append("\u{FFFD}")
            } else {
                out.unicodeScalars.append(scalar)
            }
            count += 1
        }
        return out
    }

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
        let title = stripControlCharacters(message, maxChars: maxTitleChars)
        return .notification(title: title, body: "")
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
        let title = stripControlCharacters(parts[1], maxChars: maxTitleChars)
        let body  = stripControlCharacters(parts[2...].joined(separator: ";"), maxChars: maxBodyChars)
        return .notification(title: title, body: body)
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
