#!/bin/bash
# Compile shipped Foundation policy. Exit 1 assertions, 2 environment/compile failures.
# The same truth table must reject each mutant with exit 1, never stdout forgiveness.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v swiftc >/dev/null || exit 2
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT
SRC=Sources/GoblinPortal
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
var failures = 0
var total = 0
func check(_ name: String, _ value: Bool) {
    total += 1
    if !value { failures += 1; print("FAIL \(name)") }
}
func bytes(_ s: String) -> ArraySlice<UInt8> { Array(s.utf8)[...] }
let cap = NotificationEscape.maxPayloadBytes
check("9 normal", NotificationEscape.parseOsc9(bytes("hello;world")) == .notification(title: "hello;world", body: ""))
for input in ["4;1;50", "4;", "4;invalid", "4;" + String(repeating: "x", count: cap)] {
    check("progress \(input.prefix(15))", NotificationEscape.parseOsc9(bytes(input)) == .progressPayload)
}
for input in ["", "  \n", String(repeating: "x", count: cap + 1), String(repeating: "é", count: cap)] {
    check("9 invalid", NotificationEscape.parseOsc9(bytes(input)) == .ignored)
}
check("9 invalid UTF8", NotificationEscape.parseOsc9([255][...]) == .ignored)
check("9 exact cap", NotificationEscape.parseOsc9(bytes(String(repeating: "x", count: cap))) != .ignored)
check("9 not progress", NotificationEscape.parseOsc9(bytes("4")) == .notification(title: "4", body: ""))
// OSC 9 numeric subcommand rows (F4): ConEmu-style payloads are ignored.
// `4;` is a progress payload (handled above), not a numeric subcommand.
check("9 subcommand 9;9;<cwd>", NotificationEscape.parseOsc9(bytes("9;9;/some/path")) == .ignored)
check("9 subcommand 9;1;",      NotificationEscape.parseOsc9(bytes("9;1;")) == .ignored)
check("9 subcommand 9;2;",      NotificationEscape.parseOsc9(bytes("9;2;")) == .ignored)
check("9 subcommand plain 1;",  NotificationEscape.parseOsc9(bytes("1;")) == .ignored)
// A plain message starting with digits but no immediate semicolon MUST notify.
// "42 tests passed" starts with digits but the next byte is a space, not ";", so
// isNumericSubcommand returns false → it reaches the normal notification path.
check("9 digits-no-semicolon notify", NotificationEscape.parseOsc9(bytes("42 tests passed"))
    == .notification(title: "42 tests passed", body: ""))
// Control-character stripping (#230): C0 (except tab), DEL, and C1 are replaced with U+FFFD.
// ESC (U+001B), BEL (U+0007), and NUL (U+0000) must not survive into the notification title.
// Tab (U+0009) is printable-intent whitespace and must be preserved.
let esc = "\u{1B}[31mred\u{1B}[0m"   // OSC 9 body with embedded ANSI escape
let bel = "ping\u{0007}tone"          // BEL embedded mid-message
let nul = "he\u{0000}llo"             // NUL embedded mid-message
let c1  = "\u{009B}cmd"               // C1 CSI embedded at start
let tab = "col1\tcol2"                // tab must be preserved
check("9 ESC stripped",  NotificationEscape.parseOsc9(bytes(esc)) == .notification(title: "\u{FFFD}[31mred\u{FFFD}[0m", body: ""))
check("9 BEL stripped",  NotificationEscape.parseOsc9(bytes(bel)) == .notification(title: "ping\u{FFFD}tone", body: ""))
check("9 NUL stripped",  NotificationEscape.parseOsc9(bytes(nul)) == .notification(title: "he\u{FFFD}llo", body: ""))
check("9 C1 stripped",   NotificationEscape.parseOsc9(bytes(c1))  == .notification(title: "\u{FFFD}cmd", body: ""))
check("9 tab kept",      NotificationEscape.parseOsc9(bytes(tab)) == .notification(title: "col1\tcol2", body: ""))
// Title length cap: maxTitleChars chars maximum; excess is silently dropped (not replaced).
let longTitle = String(repeating: "a", count: NotificationEscape.maxTitleChars + 10)
check("9 title capped", {
    if case .notification(let t, _) = NotificationEscape.parseOsc9(bytes(longTitle)) {
        return t.count == NotificationEscape.maxTitleChars
    }
    return false
}())
check("777 body separators", NotificationEscape.parseOsc777(bytes("notify;title;a;b;")) == .notification(title: "title", body: "a;b;"))
check("777 empty body", NotificationEscape.parseOsc777(bytes("notify;title;")) == .notification(title: "title", body: ""))
for input in ["", "notify", "notify;title", "notify;;body", "notify; ;body", "alert;title;body", "notify;t;" + String(repeating: "x", count: cap)] {
    check("777 malformed", NotificationEscape.parseOsc777(bytes(input)) == .ignored)
}
check("777 invalid UTF8", NotificationEscape.parseOsc777([255][...]) == .ignored)
check("777 exact cap", NotificationEscape.parseOsc777(bytes("notify;t;" + String(repeating: "x", count: cap - 9))) != .ignored)
// Control-character stripping for OSC 777 title and body (#230).
let e777t = "notify;\u{1B}[1mbold\u{1B}[0m;body"   // ESC in title
let e777b = "notify;title;\u{0007}alert\u{009C}end"  // BEL + C1 in body
let n777  = "notify;he\u{0000}llo;world"             // NUL in title
check("777 ESC in title stripped", NotificationEscape.parseOsc777(bytes(e777t))
    == .notification(title: "\u{FFFD}[1mbold\u{FFFD}[0m", body: "body"))
check("777 BEL+C1 in body stripped", NotificationEscape.parseOsc777(bytes(e777b))
    == .notification(title: "title", body: "\u{FFFD}alert\u{FFFD}end"))
check("777 NUL in title stripped", NotificationEscape.parseOsc777(bytes(n777))
    == .notification(title: "he\u{FFFD}llo", body: "world"))
// Body length cap: maxBodyChars chars maximum.
let longBody = "notify;t;" + String(repeating: "b", count: NotificationEscape.maxBodyChars + 10)
check("777 body capped", {
    if case .notification(_, let b) = NotificationEscape.parseOsc777(bytes(longBody)) {
        return b.count == NotificationEscape.maxBodyChars
    }
    return false
}())
for active in [false, true] {
    for visible in [false, true] {
        for kind in [DockAttention.SignalKind.bell, .osc9, .osc777] {
            for count in [0, 1, 3] {
                let result = DockAttention.decide(isAppActive: active, isDocumentVisible: visible,
                    attentionDocumentCount: count, kind: kind)
                check("decision \(active) \(visible) \(kind) \(count)", result == AttentionAction(
                    bounce: !active && !visible, badgeLabel: count == 0 ? "" : "\(count)",
                    postNotification: !visible && kind != .bell))
            }
        }
    }
}
check("negative count", DockAttention.badgeLabel(-1) == "")
print("\(total - failures)/\(total) passed")
exit(failures == 0 ? 0 : 1)
SWIFT
compile() { swiftc "$1" "$TMP/main.swift" -o "$TMP/gate" || exit 2; }
compile "$SRC/DockAttention.swift"
"$TMP/gate" || exit $?
for mutation in progress active subcommand strip; do
    if [ "$mutation" = progress ]; then
        sed 's/return .progressPayload/return .ignored/' "$SRC/DockAttention.swift" > "$TMP/mutant.swift"
    elif [ "$mutation" = active ]; then
        sed 's/bounce: !isAppActive/bounce: isAppActive/' "$SRC/DockAttention.swift" > "$TMP/mutant.swift"
    elif [ "$mutation" = subcommand ]; then
        # Remove the numeric-subcommand exclusion so ConEmu payloads notify — the
        # "9;9;<cwd>" row must then fail. This verifies the gate is not blind to the filter.
        sed 's/if isNumericSubcommand(data) { return .ignored }//' "$SRC/DockAttention.swift" > "$TMP/mutant.swift"
    else
        # strip: remove the stripControlCharacters call in parseOsc9 so control chars
        # reach the title unfiltered. The ESC/BEL/NUL/C1 cases must then fail (#230).
        # Mutant applies only when the sed pattern matches; exit 2 (cmp-unchanged) if not.
        sed 's/let title = stripControlCharacters(message, maxChars: maxTitleChars)/let title = message/' \
            "$SRC/DockAttention.swift" > "$TMP/mutant.swift"
        cmp -s "$SRC/DockAttention.swift" "$TMP/mutant.swift" && { echo "FAIL mutant strip did not apply"; exit 2; }
    fi
    compile "$TMP/mutant.swift"
    "$TMP/gate" > "$TMP/$mutation.log" 2>&1
    code=$?
    if [ "$code" -ne 1 ]; then echo "FAIL mutant $mutation exited $code, expected 1"; exit 1; fi
    echo "ok mutant $mutation rejected with exit 1"
done
# No block comments in these production files; remove line comments before matching calls.
# A missing shipped file is a REAL failure (exit 1), not an environment problem (exit 2):
# it means the file was deleted or renamed, which is a logic error, not a broken toolchain.
wire() {
    local file="$SRC/$1"
    [ -f "$file" ] || { echo "FAIL wiring: $file not found (renamed/deleted?)"; exit 1; }
    sed 's|//.*||' "$file" | grep -Eq "$2" || { echo "FAIL wiring $1: $2"; exit 1; }
}
wire AppDelegate+DockAttention.swift 'let action = DockAttention.decide\('
wire GoblinPortalTerminalView+Notify.swift 'let parsed = NotificationEscape.parseOsc9\(data\)'
wire GoblinPortalTerminalView+Notify.swift 'receive\(NotificationEscape.parseOsc777\(data\)'
wire GoblinPortalTerminalView+Notify.swift 'progressDecoder.feed\(byteArray:'
wire TerminalPane.swift 'registerNotifications\(\)'
wire TerminalPane.swift 'signalAttention\(kind: .bell\)'
wire TerminalPane+Notifications.swift 'self.signalAttention\(kind: kind'
wire AppDelegate+DockAttention.swift 'CommandNotification.postEscapeNotification\('
wire SpaceViewController.swift 'syncDockAttention\(\)'
# Wiring guard (#230): stripping must be reachable from the production parse path.
wire DockAttention.swift 'stripControlCharacters\('
echo 'check-dock-attention: passed'
