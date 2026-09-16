#!/bin/bash
#
# Assert the mac line-editing key map sends the bytes it claims to.
#
# This app has no test target, and the thing being checked is a pure function of
# (virtual key code, modifier flags) — so instead of standing up XCTest, compile
# the SHIPPED Sources/GoblinPortal/KeyBindings.swift together with a throwaway
# harness and run the truth table. Nothing is stubbed or restated: a change to
# the real mapping shows up here immediately.
#
# The negative cases matter as much as the positive ones. ⌥⌫ must stay
# un-translated (SwiftTerm sends ESC+DEL, which is delete-word-backward), and ⌘←
# has to be caught even though a real arrow event also carries .function and
# .numericPad.
#
# Usage: ./Scripts/check-keybindings.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit

var failures = 0

func check(_ label: String,
           _ keyCode: UInt16,
           _ modifiers: NSEvent.ModifierFlags,
           expect: [UInt8]?) {
    let got = MacLineEditing.controlBytes(keyCode: keyCode, modifiers: modifiers)
    let ok = got == expect
    if !ok { failures += 1 }
    func show(_ b: [UInt8]?) -> String {
        guard let b else { return "passthrough" }
        return b.map { String(format: "0x%02X", $0) }.joined(separator: " ")
    }
    print("\(ok ? "✓" : "✗") \(label.padding(toLength: 26, withPad: " ", startingAt: 0))"
        + "expected \(show(expect).padding(toLength: 12, withPad: " ", startingAt: 0))"
        + "got \(show(got))")
}

let backspace: UInt16 = 51
let forwardDelete: UInt16 = 117
let left: UInt16 = 123
let right: UInt16 = 124
let letterA: UInt16 = 0

// Real events for these keys carry these extra flags from the hardware.
let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]
let fnDeleteFlags: NSEvent.ModifierFlags = [.function]

// The four translations.
check("⌘⌫  → ^U", backspace, [.command], expect: [0x15])
check("⌘⌦  → ^K", forwardDelete, [.command, .function], expect: [0x0b])
check("⌘←  → ^A", left, [.command], expect: [0x01])
check("⌘→  → ^E", right, [.command], expect: [0x05])

// Same keys as the OS actually delivers them, with hardware flags attached.
check("⌘← (+fn +numpad)", left, arrowFlags.union([.command]), expect: [0x01])
check("⌘→ (+fn +numpad)", right, arrowFlags.union([.command]), expect: [0x05])
check("⌘⌦ (+fn)", forwardDelete, fnDeleteFlags.union([.command]), expect: [0x0b])
check("⌘⌫ (+capsLock)", backspace, [.command, .capsLock], expect: [0x15])

// Everything else must reach SwiftTerm unchanged.
check("⌫  plain", backspace, [], expect: nil)
check("⌥⌫ (delete word)", backspace, [.option], expect: nil)
check("⌃⌫", backspace, [.control], expect: nil)
check("⌘⇧⌫", backspace, [.command, .shift], expect: nil)
check("⌘⌥←", left, arrowFlags.union([.command, .option]), expect: nil)
check("⌘⌃←", left, arrowFlags.union([.command, .control]), expect: nil)
check("←  plain", left, arrowFlags, expect: nil)
check("⌦  plain", forwardDelete, fnDeleteFlags, expect: nil)
check("⌘A (Select All)", letterA, [.command], expect: nil)

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
SWIFT

swiftc -o "$TMP/keycheck" Sources/GoblinPortal/KeyBindings.swift "$TMP/main.swift"
"$TMP/keycheck"
