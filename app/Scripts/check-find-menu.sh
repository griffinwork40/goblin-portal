#!/bin/bash
#
# Assert the Edit-menu actions this app does not implement actually exist.
#
# Undo, Redo and Find-and-Replace are the three menu items in `AppMenu.swift` with
# no Goblin Portal code behind them: each is an AppKit responder action reached with
# `target = nil`, so correctness lives entirely in assumptions about the SDK. That
# is a bad place for an assumption, because the failure mode is silent — a menu
# item wired to a selector nobody answers, or carrying a tag nobody recognises,
# renders normally, clicks normally, and does nothing. `AppMenu.swift` already
# warns about exactly this for the find items ("every item must carry a tag or it
# silently does nothing"); this script is that warning made mechanical.
#
# Three assumptions are checked:
#   * `undo:` / `redo:` are answered by **NSWindow** — not NSTextView, which does
#     not implement them. The window forwards to its `undoManager`, which is the
#     focused text view's, and that is the whole mechanism behind ⌘Z in the editor.
#   * the four find tags are the `NSFindPanelAction` raw values the menu reads off
#     the SDK, so a future SDK renumbering is caught rather than assumed away.
#   * tag 12 really does show the replace row. This one is *behavioural*, not a
#     value check, and it is the reason this script spins a real NSTextView:
#     `NSFindPanelAction` has no "show replace" case and stops at 10, so the item
#     uses `NSTextFinder.Action.showReplaceInterface` and relies on
#     `NSTextView.performFindPanelAction` forwarding the tag to its NSTextFinder.
#     Nothing in the value checks would notice if that forwarding stopped.
#
# The replace case is run in a SEPARATE PROCESS from the find case on purpose. A
# first attempt sent both tags to one text view and read 2 text fields either way —
# the bar kept the state the previous action left it in, so a completely dead tag
# would have passed. One process per tag is what makes the comparison mean anything.
#
# Needs a logged-in GUI session (it builds a real find bar), but the window is
# placed far offscreen, so unlike ./Scripts/check-keys-e2e.sh this steals no focus
# and needs no Accessibility permission. Exits 2 — not 1 — when no find bar can be
# built at all, so "no window server" is distinguishable from "the tag is dead".
#
# Usage: ./Scripts/check-find-menu.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit

// Count only fields the user could actually type into: the replace row is added
// to the bar's tree in find-only mode too, just sized/hidden away. Counting every
// NSTextField regardless of visibility is what made the first version of this
// check report "2 fields" for both tags and prove nothing.
func visibleFieldCount(_ v: NSView) -> Int {
    var n = 0
    if v is NSTextField || v is NSSearchField,
       !v.isHidden, v.frame.height > 1, v.frame.width > 1 {
        n = 1
    }
    for sub in v.subviews { n += visibleFieldCount(sub) }
    return n
}

let mode = CommandLine.arguments[1]

if mode == "contract" {
    var failures = 0
    func check(_ label: String, _ got: Int, _ want: Int) {
        let ok = got == want
        if !ok { failures += 1 }
        print("\(ok ? "✓" : "✗") \(label.padding(toLength: 40, withPad: " ", startingAt: 0))"
            + "expected \(want)  got \(got)")
    }
    func checkResponds(_ label: String, _ sel: String) {
        let ok = NSWindow.instancesRespond(to: Selector((sel)))
        if !ok { failures += 1 }
        print("\(ok ? "✓" : "✗") \(label.padding(toLength: 40, withPad: " ", startingAt: 0))"
            + "expected NSWindow answers  got \(ok ? "answers" : "NOBODY ANSWERS")")
    }
    checkResponds("Undo  → NSWindow undo:", "undo:")
    checkResponds("Redo  → NSWindow redo:", "redo:")
    check("Find… tag", Int(NSFindPanelAction.showFindPanel.rawValue), 1)
    check("Find Next tag", Int(NSFindPanelAction.next.rawValue), 2)
    check("Find Previous tag", Int(NSFindPanelAction.previous.rawValue), 3)
    check("Use Selection for Find tag", Int(NSFindPanelAction.setFindString.rawValue), 7)
    check("Find and Replace… tag", NSTextFinder.Action.showReplaceInterface.rawValue, 12)
    exit(failures == 0 ? 0 : 1)
}

// Behavioural half: one tag, one process.
let tag = Int(mode)!
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
tv.string = "alpha beta alpha gamma"
tv.isEditable = true
tv.usesFindBar = true          // exactly what FileViewerPane.swift sets
let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
scroll.documentView = tv
// Far offscreen: a real window is needed for the bar to lay out, a visible one is not.
let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 500, height: 300),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
win.contentView = scroll
win.makeKeyAndOrderFront(nil)
win.makeFirstResponder(tv)
func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
spin(0.3)

let item = NSMenuItem(title: "probe", action: nil, keyEquivalent: "")
item.tag = tag
tv.performFindPanelAction(item)
spin(0.6)

guard let bar = scroll.findBarView, scroll.isFindBarVisible else {
    print("NO_FIND_BAR")
    exit(2)
}
print("FIELDS=\(visibleFieldCount(bar)) HEIGHT=\(Int(bar.frame.height))")
SWIFT

swiftc -o "$TMP/findcheck" "$TMP/main.swift" 2>/dev/null

"$TMP/findcheck" contract
contract_status=$?

echo
# One process per tag — see the header note on why sharing one is worthless.
find_out="$("$TMP/findcheck" 1 || true)"
replace_out="$("$TMP/findcheck" 12 || true)"

# Order matters here. Tag 1 is the most basic thing a find bar can be asked to do,
# so if *it* produces nothing the environment is the suspect and this exits 2. But
# if tag 1 worked and tag 12 produced nothing, the environment is demonstrably fine
# and the tag is dead — that is a real failure and must exit 1, not hide behind the
# environment message. Conflating the two is how a genuinely broken menu item would
# have been read as "no window server" and waved through.
if [ "$find_out" = "NO_FIND_BAR" ]; then
    echo "✗ no find bar for tag 1 — needs a logged-in GUI session"
    echo "  (environment failure, not a dead tag)"
    exit 2
fi
if [ "$replace_out" = "NO_FIND_BAR" ]; then
    echo "✗ tag 1 built a find bar but tag 12 built nothing:"
    echo "  NSTextFinder.Action.showReplaceInterface is not reaching the text view."
    echo "  'Find and Replace…' in AppMenu.swift is a dead menu item."
    exit 1
fi

find_fields="${find_out#FIELDS=}"; find_fields="${find_fields%% *}"
find_height="${find_out##*HEIGHT=}"
replace_fields="${replace_out#FIELDS=}"; replace_fields="${replace_fields%% *}"
replace_height="${replace_out##*HEIGHT=}"

behaviour_status=0
report() {
    if [ "$2" = "ok" ]; then echo "✓ $1"; else echo "✗ $1"; behaviour_status=1; fi
}

# Find-only must offer somewhere to type a pattern.
[ "$find_fields" -ge 1 ] && report "tag 1  shows a find field (fields=$find_fields, h=$find_height)" ok \
    || report "tag 1  shows a find field (fields=$find_fields, h=$find_height)" bad

# The load-bearing one: replace mode must offer strictly MORE than find mode.
# Asserting a delta rather than "fields == 2" so an extra Apple control does not
# fail the check, while a tag that does nothing still cannot pass it.
[ "$replace_fields" -gt "$find_fields" ] \
    && report "tag 12 adds a replace field (fields=$replace_fields > $find_fields)" ok \
    || report "tag 12 adds a replace field (fields=$replace_fields > $find_fields)" bad

[ "$replace_height" -gt "$find_height" ] \
    && report "tag 12 grows the bar (h=$replace_height > $find_height)" ok \
    || report "tag 12 grows the bar (h=$replace_height > $find_height)" bad

echo
if [ "$contract_status" -eq 0 ] && [ "$behaviour_status" -eq 0 ]; then
    echo "all checks passed"
    exit 0
fi
echo "check(s) FAILED"
exit 1
