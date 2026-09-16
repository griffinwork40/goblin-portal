//
//  KeyBindings.swift
//  Mac line-editing keys → the control bytes a line editor understands.
//

import AppKit

/// The ⌘-modified editing keys every mac app honours, translated into terminal
/// control bytes.
///
/// macOS resolves these keystrokes into *text-view* editing commands before the
/// view ever sees them — `⌘⌫` becomes `deleteToBeginningOfLine:`, `⌘←` becomes
/// `moveToLeftEndOfLine:`, per
/// `/System/Library/Frameworks/AppKit.framework/Resources/StandardKeyBinding.dict`.
/// An `NSTextView` can just execute those. A terminal cannot: the line being
/// edited lives in the program on the far side of the pty, so the only way to
/// honour the keystroke is to send the byte that program's own line editor
/// already binds to the same operation.
///
/// SwiftTerm implements a handful of those selectors and drops the rest, which is
/// exactly why `⌘⌫` did nothing at all: it arrived as `deleteToBeginningOfLine:`,
/// matched no case in `MacTerminalView.doCommand(by:)`, and fell through to a
/// `print("Unhandle selector …")` — no bytes written. `⌘←`/`⌘→` fared worse than
/// nothing: they were mapped to ESC-b / ESC-f, i.e. move by *word*, which is
/// already what `⌥←`/`⌥→` send, instead of to the ends of the line.
///
/// The bytes below are the emacs-mode readline bindings — what bash, zsh, fish,
/// and afk's own REPL all implement, and what iTerm2 sends for these keys by
/// default. Verified on the receiving side for the program this terminal exists
/// to host: `agent-afk`'s REPL handles `^U`/`^K`
/// (`src/cli/terminal-compositor.input-dispatch.ts:745,758`) and `^A`/`^E`
/// (`:697,703`), whose comments name "Cmd+← (default remap → \x01)" outright —
/// the convention was already assumed there, only unimplemented here.
///
/// Kept free of SwiftTerm and of any view state on purpose: a pure function of
/// (key code, modifiers) is what `Scripts/check-keybindings.sh` can compile and
/// assert against in a project that has no test target.
enum MacLineEditing {
    /// Virtual key codes rather than characters, so the mapping is independent of
    /// keyboard layout and of what a modifier does to `characters`.
    /// (`kVK_Delete`, `kVK_ForwardDelete`, `kVK_LeftArrow`, `kVK_RightArrow`.)
    private static let backspace: UInt16 = 51
    private static let forwardDelete: UInt16 = 117
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124

    /// The bytes to send for `event`, or nil to let SwiftTerm handle the key as
    /// it always has.
    static func controlBytes(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        // Compare only the modifiers that carry intent. Arrow keys and forward
        // delete also set `.function` and `.numericPad` — masking rather than
        // testing equality on the whole set is what keeps ⌘← from being missed
        // because the hardware said "this is also a function key".
        let intent = modifiers.intersection([.command, .control, .option, .shift])
        guard intent == [.command] else { return nil }

        switch keyCode {
        case backspace: return [0x15]      // ^U — delete to start of line
        case forwardDelete: return [0x0b]  // ^K — delete to end of line
        case leftArrow: return [0x01]      // ^A — start of line
        case rightArrow: return [0x05]     // ^E — end of line
        default: return nil
        }
    }
}
