// GoblinPortalTerminalView+Notify.swift
// Registers notification escapes without changing the vendored parser or view class.
// Separate because protocol-extension defaults cannot be overridden by a subclass:
// Terminal.swift:6838 supplies TerminalView's no-op notify witness.
import AppKit
import SwiftTerm

@MainActor
extension GoblinPortalTerminalView {
    func registerNotificationHandlers(
        receive: @escaping (NotificationEscape.Parsed, DockAttention.SignalKind) -> Void
    ) {
        // No public fallback hook exists (EscapeSequenceParser.swift:593 is internal).
        // Registered handlers run BEFORE built-ins (:514-517). Re-entering this view's
        // parser from its own callback is unsafe, so use a separate SwiftTerm decoder
        // with the SAME view delegate. Only progress payloads enter it. Its untouched
        // dispatchOsc(:533) -> oscProgressReport(Terminal.swift:1854) -> progressReport
        // (MacTerminalView.swift:2908) preserves the native bar, including clamping.
        // Terminal.tdel is weak (Terminal.swift:420); this capture cannot retain the view.
        let progressDecoder = Terminal(delegate: self)
        getTerminal().registerOscHandler(code: 9) { data in
            MainActor.assumeIsolated {
                let parsed = NotificationEscape.parseOsc9(data)
                if parsed == .progressPayload {
                    progressDecoder.feed(byteArray: [27, 93, 57, 59] + Array(data) + [7])
                } else {
                    receive(parsed, .osc9)
                }
            }
        }
        // Use the SAME raw policy the headless gate compiles, rather than testing a
        // parser never called by production. SwiftTerm's built-in 777 parser otherwise
        // reaches the default no-op notify witness (Terminal.swift:1837-1850,6838).
        getTerminal().registerOscHandler(code: 777) { data in
            MainActor.assumeIsolated { receive(NotificationEscape.parseOsc777(data), .osc777) }
        }
    }
}
