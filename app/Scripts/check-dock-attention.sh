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
check("777 body separators", NotificationEscape.parseOsc777(bytes("notify;title;a;b;")) == .notification(title: "title", body: "a;b;"))
check("777 empty body", NotificationEscape.parseOsc777(bytes("notify;title;")) == .notification(title: "title", body: ""))
for input in ["", "notify", "notify;title", "notify;;body", "notify; ;body", "alert;title;body", "notify;t;" + String(repeating: "x", count: cap)] {
    check("777 malformed", NotificationEscape.parseOsc777(bytes(input)) == .ignored)
}
check("777 invalid UTF8", NotificationEscape.parseOsc777([255][...]) == .ignored)
check("777 exact cap", NotificationEscape.parseOsc777(bytes("notify;t;" + String(repeating: "x", count: cap - 9))) != .ignored)
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
for mutation in progress active; do
    if [ "$mutation" = progress ]; then
        sed 's/return .progressPayload/return .ignored/' "$SRC/DockAttention.swift" > "$TMP/mutant.swift"
    else
        sed 's/bounce: !isAppActive/bounce: isAppActive/' "$SRC/DockAttention.swift" > "$TMP/mutant.swift"
    fi
    compile "$TMP/mutant.swift"
    "$TMP/gate" > "$TMP/$mutation.log" 2>&1
    code=$?
    if [ "$code" -ne 1 ]; then echo "FAIL mutant $mutation exited $code, expected 1"; exit 1; fi
    echo "ok mutant $mutation rejected with exit 1"
done
# No block comments in these production files; remove line comments before matching calls.
wire() {
    [ -f "$SRC/$1" ] || exit 2
    sed 's|//.*||' "$SRC/$1" | grep -Eq "$2" || { echo "FAIL wiring $1: $2"; exit 1; }
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
echo 'check-dock-attention: passed'
