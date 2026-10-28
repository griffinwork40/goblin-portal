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
        //
        // Cost note (N2 from #202 review): Terminal carries a full buffer and parser
        // state (~two heap allocations per Terminal init). This is one instance per pane
        // created once at registration time — not per event — so it is a fixed per-pane
        // overhead, not an O(events) cost. A lightweight shim that forwards only the
        // progress report would be cheaper but requires duplicating or exposing
        // SwiftTerm's internal OSC dispatch path, which is private
        // (EscapeSequenceParser.swift:593). Deferred: the current cost is acceptable
        // at one instance per pane, and any shim would need to be re-validated against
        // SwiftTerm vendor updates. Re-evaluate if Terminal's init cost becomes
        // measurable (e.g. if pane count scales significantly).
        let progressDecoder = Terminal(delegate: self)
        // Since the re-vendor to TerminalIOPipelineWorker, registerOscHandler
        // callbacks run on the `swiftterm-io-reader` background thread. Dispatch
        // to main rather than asserting we are already there. Copy `data` before
        // the async boundary — it may be borrowed from the parser's read buffer.
        getTerminal().registerOscHandler(code: 9) { [weak self] data in
            // ArraySlice is a value type with COW — capturing it across the async
            // boundary copies the reference and keeps the backing buffer alive.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let parsed = NotificationEscape.parseOsc9(data)
                if parsed == .progressPayload {
                    progressDecoder.feed(byteArray: [27, 93, 57, 59] + Array(data) + [7])
                    // Forward the raw payload to the pane's progress policy in parallel.
                    // ProgressPayload.parse decodes `<state>[;<pct>]` from the bytes
                    // after the leading `4;` prefix (already confirmed by parseOsc9).
                    // The slice starts at index 2 to skip the "4;" prefix characters.
                    if let cb = self.progressCallback {
                        let inner = data.dropFirst(2)  // skip "4;"
                        if let decoded = ProgressPayload.parse(inner) {
                            cb(decoded.stateCode, decoded.progress)
                        }
                    }
                } else {
                    receive(parsed, .osc9)
                }
            }
        }
        // Use the SAME raw policy the headless gate compiles, rather than testing a
        // parser never called by production. SwiftTerm's built-in 777 parser otherwise
        // reaches the default no-op notify witness (Terminal.swift:1837-1850,6838).
        getTerminal().registerOscHandler(code: 777) { data in
            DispatchQueue.main.async { receive(NotificationEscape.parseOsc777(data), .osc777) }
        }
    }
}
