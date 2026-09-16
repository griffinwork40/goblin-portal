#!/bin/bash
#
# End-to-end check: does a real ⌘⌫ keystroke actually arrive at the pty as ^U?
#
# `check-keybindings.sh` proves the MAP is right. This proves the WIRING is
# right — that `performKeyEquivalent` claims the chord, that the pane is the
# first responder, and that the bytes reach the program on the far side of the
# pty. It is the only check here that drives a real NSEvent through a real app.
#
# How: launch a throwaway instance of the bundle whose $SHELL is a stand-in that
# puts the pty in RAW mode and logs every byte it receives. Raw mode is the whole
# trick — in canonical mode the tty line discipline swallows ^U as VKILL before
# any reader can see it, so a correct terminal would look broken. Then post
# synthetic key events to THAT PID ONLY and diff the log against the expected
# bytes.
#
# Requirements and gotchas, both learned the hard way:
#
#   * Accessibility permission for the invoking terminal (System Settings →
#     Privacy & Security → Accessibility). Without it `CGEvent.postToPid` is a
#     silent no-op; the poster refuses up front rather than reporting a fake
#     failure.
#   * The app must be FRONTMOST while events are posted. AppKit only runs the
#     key-equivalent phase for the key window of the *active* application, so an
#     inactive instance falls through to SwiftTerm's old `keyDown` path and every
#     ⌘ chord reads as unfixed even when the build is correct. `open -n`
#     activates the new instance — don't click away while this runs.
#   * The script signals only the pid it launched itself, and only after
#     confirming that pid's environment names the throwaway shell. Matching
#     Goblin Portal by name and killing the newest/last match will eventually kill
#     the instance you are working in.
#
# Usage: ./Scripts/check-keys-e2e.sh   (opens and closes one window; steals focus)
#
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/GoblinPortal.app"
[[ -d "$APP" ]] || {
  echo "error: $APP not found — run ./Scripts/make-app-bundle.sh first" >&2
  exit 1
}

TMP="$(mktemp -d)"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] &&
    ps eww "$APP_PID" 2>/dev/null | tr ' ' '\n' | grep -q "SHELL=$TMP/pty-logger"; then
    kill "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# The log path is baked in rather than passed through the environment: SwiftTerm
# starts the shell with a *curated* env (`Terminal.getEnvironmentVariables` —
# TERM, PATH, HOME, …), not the app's own, so an exported variable never reaches
# the child. Reading one here made the logger exit instantly, which closed the
# tab, which quit the app, which produced a mystifying "instance is not the one I
# launched".
cat > "$TMP/pty-logger" <<PY
#!/usr/bin/env python3
import os, sys, tty
log = open('$TMP/keys.log', 'ab', 0)
fd = sys.stdin.fileno()
tty.setraw(fd)
sys.stdout.write('pty-logger ready\r\n'); sys.stdout.flush()
while True:
    try:
        chunk = os.read(fd, 64)
    except OSError:
        break
    if not chunk:
        break
    log.write(b'RECV ' + ' '.join('%02X' % b for b in chunk).encode() + b'\n')
PY
chmod +x "$TMP/pty-logger"

cat > "$TMP/post.swift" <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("""
    error: this terminal has no Accessibility permission, so synthetic key events
           go nowhere at all. Grant it in System Settings → Privacy & Security →
           Accessibility, or run the map-only check: ./Scripts/check-keybindings.sh

    """.utf8))
    exit(2)
}

// postToPid, never post() — a broadcast post would type into whatever app the
// operator happens to have in front.
let pid = pid_t(CommandLine.arguments[1])!

// The target must be the frontmost app, or the result is meaningless rather than
// merely negative: AppKit runs the key-equivalent phase only for the key window
// of the *active* application, so ⌘ chords posted at a background instance fall
// through to `keyDown` and every translation reads as missing. Whether a freshly
// `open -n`'d instance wins activation is not deterministic, and it cannot be
// forced — `NSRunningApplication.activate()` returns true and does nothing under
// cooperative activation when the caller is a background CLI tool. So check, and
// say "inconclusive" rather than "fail".
func frontmostPid() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
var waited = 0.0
while frontmostPid() != pid, waited < 10 {
    usleep(250_000)
    waited += 0.25
}
guard frontmostPid() == pid else {
    FileHandle.standardError.write(Data("""
    inconclusive: pid \(pid) never became frontmost (frontmost is \
    \(frontmostPid().map(String.init) ?? "unknown")), so ⌘ chords would never reach
                  the key-equivalent phase. Click the new Goblin Portal window, or
                  re-run — nothing was posted.

    """.utf8))
    exit(3)
}
let chords: [(String, CGKeyCode, CGEventFlags)] = [
    ("cmd+backspace", 51, .maskCommand),
    ("cmd+forwardDelete", 117, .maskCommand),
    ("cmd+left", 123, .maskCommand),
    ("cmd+right", 124, .maskCommand),
    ("backspace", 51, []),
    ("opt+backspace", 51, .maskAlternate),
]
let source = CGEventSource(stateID: .hidSystemState)
for (label, key, flags) in chords {
    for isDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
        else { continue }
        event.flags = flags
        event.postToPid(pid)
    }
    FileHandle.standardError.write(Data("  posted \(label)\n".utf8))
    usleep(400_000)
}
SWIFT

swiftc -O "$TMP/post.swift" -o "$TMP/post"

: > "$TMP/keys.log"

# Identify the new instance by diffing the pid set, not by taking the newest
# match: "newest" is a guess, and the cost of guessing wrong is killing the
# terminal the operator is working in.
BEFORE="$(pgrep -f "$PWD/$APP" | sort || true)"
open -n --env "SHELL=$TMP/pty-logger" "$APP"
sleep 4
AFTER="$(pgrep -f "$PWD/$APP" | sort || true)"

APP_PID="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | tr -d ' ' | head -1)"
[[ -n "$APP_PID" ]] || {
  echo "error: no new Goblin Portal instance appeared — did the throwaway shell exit" >&2
  echo "       immediately? (that closes the tab, which quits the app)" >&2
  exit 1
}
ps eww "$APP_PID" | tr ' ' '\n' | grep -q "SHELL=$TMP/pty-logger" || {
  echo "error: pid $APP_PID is not the instance this script launched — refusing to touch it" >&2
  APP_PID=""
  exit 1
}
echo "==> throwaway instance pid $APP_PID"

"$TMP/post" "$APP_PID"
sleep 1

GOT="$(sed -n 's/^RECV //p' "$TMP/keys.log" | tr '\n' ' ' | tr -s ' ' | sed 's/ *$//')"
WANT="15 0B 01 05 7F 1B 7F"

echo
echo "want: $WANT   (^U ^K ^A ^E, then plain DEL, then ESC-DEL)"
echo "got:  $GOT"
if [[ "$GOT" == "$WANT" ]]; then
  echo "PASS — ⌘⌫ ⌘⌦ ⌘← ⌘→ translated; ⌫ and ⌥⌫ untouched"
  exit 0
fi
if [[ -z "$GOT" ]]; then
  echo "FAIL — no bytes reached the pty at all: the instance was probably not"
  echo "       frontmost, or Accessibility permission is missing." >&2
fi
echo "FAIL" >&2
exit 1
