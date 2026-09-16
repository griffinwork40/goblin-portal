//
//  PasteGuardPolicy.swift
//  The threshold logic for PasteGuard — separated from AppKit so it can be gated headlessly.
//
//  Its own file and Foundation-only, for the same reason `CommandOutcome.swift` is separate from
//  the AppKit that acts on its verdict: the interesting part is a *policy* — a pure function of
//  the text about to be pasted — and a pure function can be compiled into a headless check
//  (`check-paste-guard.sh`) while the NSAlert half cannot.
//
//  WHY THIS IS NOT IN PasteGuard.swift. `PasteGuard.swift` imports AppKit (for `NSView` and
//  `NSAlert`), which makes it opaque to `swiftc` without a full SDK link. The policy itself
//  — "does this string exceed either threshold?" — references nothing AppKit provides; it is
//  arithmetic over a `String`. Separating it lets the gate compile the *shipped* file rather
//  than a restatement of its logic, which is the only thing that keeps the gate honest.
//
//  WHAT THE GATE CAN AND CANNOT REACH. `check-paste-guard.sh` exercises every path through
//  `shouldConfirm(_:)`: empty strings, single-line pastes, newline counts at and above the
//  threshold, character counts at and above the threshold, and the confirmed-below-threshold
//  path that returns `false`. It cannot reach `PasteGuard.confirmIfNeeded(_:in:)` — that
//  requires an `NSView`, a window server, and the AppKit run loop. Those paths live in daily
//  use and the main app binary.
//

import Foundation

/// Foundation-only threshold logic for PasteGuard.
///
/// Every method here must remain importable without AppKit — the headless gate
/// (`app/Scripts/check-paste-guard.sh`) compiles this file alone with `swiftc`.
enum PasteGuardPolicy {
    /// Newline count above which a confirmation is required.
    ///
    /// 1 means "any multiline paste triggers a dialog". Deliberately low: the cost of one dialog
    /// click on a legitimate paste is trivial; the cost of executing an accidental `rm -rf` is
    /// unbounded. Without bracketed paste (DECSET 2004), every `\n` in the clipboard is a
    /// submitted command — and most terminals, including Umber, do not synthesise bracketed-paste
    /// mode unless the running program requests it.
    static let newlineThreshold = 1

    /// Character count above which a confirmation is required, even for a single-line paste.
    ///
    /// Protects against a massive single-line paste that floods the terminal with output or
    /// pipes unexpected input into a running program. 1 500 is roughly three terminal-width
    /// lines of code — large enough to feel deliberate, small enough to catch the "pasted the
    /// wrong clipboard" failure.
    static let characterThreshold = 1_500

    /// Returns `true` when the paste should be confirmed before proceeding.
    ///
    /// The caller is responsible for showing any dialog; this method only makes the
    /// threshold decision.
    ///
    /// - Parameter text: The string the user is about to paste.
    /// - Returns: `true` if the text exceeds either threshold, `false` if it is safe to
    ///   paste without asking.
    static func shouldConfirm(_ text: String) -> Bool {
        let newlineCount = text.filter { $0.isNewline }.count
        let charCount = text.count
        return newlineCount >= newlineThreshold || charCount >= characterThreshold
    }
}
