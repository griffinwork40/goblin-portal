// GoblinPortalTerminalView+Progress.swift
// Stores the per-pane progress-update callback so +Notify.swift can forward
// decoded OSC 9;4 payloads to TerminalPane+Progress.swift.
//
// Why NOT an override of progressReport(source:report:)
// -------------------------------------------------------
// MacTerminalView.progressReport is `public`, not `open`
// (MacTerminalView.swift:progressReport), so it cannot be overridden from
// outside SwiftTerm's module — the compiler rejects it.  Overriding in an
// extension (even inside GoblinPortal) is additionally disallowed by Swift for
// non-open methods.
//
// The correct hook point is the OSC 9 handler already registered in
// GoblinPortalTerminalView+Notify.swift.  That handler already intercepts
// `4;*` payloads and routes them through the progressDecoder so SwiftTerm's
// native in-view bar works.  We extend that same handler to ALSO call a
// pane-provided callback with the raw `(stateCode, progress)` tuple.
//
// This file just holds the weak callback slot; the registration happens in
// registerNotifications() → registerNotificationHandlers(), where the pane
// sets progressCallback = { [weak self] code, pct in self?.applyProgressReport(...) }.
//
import AppKit

@MainActor
extension GoblinPortalTerminalView {

    // MARK: - Progress callback slot

    /// Called by +Notify.swift whenever a valid OSC 9;4 progress payload is decoded.
    /// Set by TerminalPane+Notifications.registerNotifications().
    /// Weak-simulated via an explicit Box so the closure can be nil'd out.
    var progressCallback: ((Int, Int) -> Void)? {
        get { (objc_getAssociatedObject(self, &Self.progressCallbackKey) as? ProgressCallbackBox)?.value }
        set {
            objc_setAssociatedObject(
                self, &Self.progressCallbackKey,
                newValue.map(ProgressCallbackBox.init),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    private static var progressCallbackKey: UInt8 = 0
}

// MARK: - Box

/// Wraps the progress callback closure for storage as AnyObject.
private final class ProgressCallbackBox {
    let value: (Int, Int) -> Void
    init(_ v: @escaping (Int, Int) -> Void) { value = v }
}
