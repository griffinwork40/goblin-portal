#!/bin/bash
# Owns the local fullscreen ProMotion regression experiment; separate from the
# headless recorder gate because it needs a real display, AX permission and focus.
# Evidence: .afk/research/fullscreen-typing-lag-2026-11-20.md: delayed blink echo
# max 380–637 ms; timer restart 2.8–11.9 ms. Compositor deferral cause is unknown.
# Usage: check-fullscreen-latency.sh [--no-falsify] (LOCAL ONLY; takes focus, ~2 min).
# Verdict: 0 passing + judged mutant; 1 regression; 2 environment/unjudged mutant.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
FALSIFY=1
case "${1:-}" in
  '') ;;
  --no-falsify) FALSIFY=0 ;;
  *) echo 'environment: usage: check-fullscreen-latency.sh [--no-falsify]'; exit 2 ;;
esac
fail_env() { echo "environment: $*" >&2; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/gp-fslatency.XXXXXX") || exit 2
BID=com.griffinlong.goblin-portal.fslatency
APP_PID=''
cleanup() {
  # Only our direct child PID, never a name match (check-keys-e2e.sh:28-31).
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    sleep 1
    kill -9 "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  defaults delete "$BID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$BID.plist"
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM
command -v python3 >/dev/null || fail_env 'python3 unavailable'
# Discover rather than hard-code AX coordinates: NSScreen is bottom-origin,
# System Events is top-origin relative to the primary screen (AppKit geometry).
cat > "$TMP/display.swift" <<'SWIFT'
import AppKit
import CoreGraphics
let screens = NSScreen.screens
guard let primary = screens.first else { exit(2) }
for screen in screens {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          CGDisplayIsBuiltin(number.uint32Value) != 0,
          screen.minimumRefreshInterval != screen.maximumRefreshInterval else { continue }
    let f = screen.visibleFrame
    let x = Int(f.minX + 50), y = Int(primary.frame.maxY - f.maxY + 50)
    print("\(x) \(y) \(Int(min(1100, f.width - 100))) \(Int(min(700, f.height - 100)))")
    exit(0)
}
exit(2)
SWIFT
GEOMETRY=$(swift "$TMP/display.swift" 2>"$TMP/display.err") ||
  fail_env 'no online built-in variable-refresh display (or display helper unavailable)'
read -r X Y WIDTH HEIGHT <<< "$GEOMETRY"
[[ "$WIDTH" -gt 0 && "$HEIGHT" -gt 0 ]] || fail_env 'invalid built-in screen frame'
AX=$(osascript -e 'tell application "System Events" to get UI elements enabled' 2>/dev/null) ||
  fail_env 'System Events Accessibility scripting unavailable'
[[ "$AX" == true ]] || fail_env 'System Events Accessibility permission missing'
SOURCE="$PWD/build/Goblin Portal.app"
if [[ ! -x "$SOURCE/Contents/MacOS/GoblinPortal" ]]; then
  ./Scripts/make-app-bundle.sh >"$TMP/build.log" 2>&1 || fail_env 'debug bundle unavailable and build failed'
fi
APP="$TMP/FSLatency.app"
cp -cR "$SOURCE" "$APP" || fail_env 'APFS bundle clone failed'
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" "$APP/Contents/Info.plist" ||
  fail_env 'cannot set isolated bundle id'
codesign -s - --force --deep "$APP" >/dev/null 2>&1 || fail_env 'cannot sign isolated bundle'
ax() {
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to $1" 2>/dev/null
}
front() {
  local n=0
  while [[ $n -lt 8 ]]; do
    ax 'set frontmost to true' >/dev/null || return 1
    sleep 0.7
    [[ "$(ax 'get frontmost')" == true ]] && return 0
    n=$((n+1))
  done
  return 1
}
# Each real event is guarded in the SAME AppleScript loop, as in run5.sh. No
# broadcast keystroke is sent after focus moves to the operator's other window.
keys() {
  osascript -e "tell application \"System Events\"
    set sent to 0
    repeat 35 times
      if (unix id of (first process whose frontmost is true)) is $APP_PID then
        keystroke \"x\"
        set sent to sent + 1
      end if
      delay 0.11
    end repeat
    return sent
  end tell" 2>/dev/null
}
clear_prompt() {
  osascript -e "tell application \"System Events\"
    if (unix id of (first process whose frontmost is true)) is not $APP_PID then error \"focus lost\"
    key code 32 using {control down}
  end tell" >/dev/null 2>&1
}
phase() {
  local name=$1 sent
  front || fail_env "$name: copy never frontmost / AX scripting denied"
  clear_prompt || fail_env "$name: focus lost before prompt clear"
  sleep 1.2
  printf '\n##### %s\n' "$name" >> "$LOG"
  sent=$(keys) || fail_env "$name: guarded keystroke loop failed"
  [[ "$sent" =~ ^[0-9]+$ ]] || fail_env "$name: invalid sent count"
  echo "$LABEL $name sent=$sent/35"
  [[ "$sent" -ge 28 ]] || fail_env "$name: fewer than 80% of keys sent (focus lost)"
  sleep 2.2
  printf '\n##### END\n' >> "$LOG"
}
stop_app() {
  kill "$APP_PID" 2>/dev/null || true
  sleep 1
  kill -9 "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=''
}
run_case() {
  LABEL=$1
  LOG="$TMP/$LABEL.log"
  defaults delete "$BID" >/dev/null 2>&1 || true
  mkdir -p "$TMP/workspace"
  defaults write "$BID" GoblinPortal.openSpaceRoots -array "$TMP/workspace" || fail_env 'isolated defaults seed failed'
  # No real defaults domain is consulted or changed. Force the renderer under
  # test; this is the shipped env switch (Config+Load.swift:112), not a fake draw.
  # Both writers must use O_APPEND: a normal stderr fd overwrites shell phase
  # markers at its stale offset (first local gate run, 2026-11-20: no W samples).
  : > "$LOG"
  local -a launch_env=(env -u SWIFTTERM_CARET_DELAYED_BLINK GOBLIN_PORTAL_DIAG=1 GOBLIN_PORTAL_RENDERER=metal)
  [[ "$LABEL" == delayed-blink ]] && launch_env+=(SWIFTTERM_CARET_DELAYED_BLINK=1)
  "${launch_env[@]}" "$APP/Contents/MacOS/GoblinPortal" >>"$LOG" 2>&1 &
  APP_PID=$!
  sleep 5
  kill -0 "$APP_PID" 2>/dev/null || fail_env "$LABEL: app died at launch"
  front || fail_env "$LABEL: copy cannot take focus / AX scripting denied"
  ax "set position of window 1 to {$X, $Y}" >/dev/null || fail_env 'cannot place window on built-in display'
  ax "set size of window 1 to {$WIDTH, $HEIGHT}" >/dev/null || fail_env 'cannot size window'
  sleep 2
  # Moving the window to another display can hand focus back to the previous app
  # (observed 2026-11-20: "focus lost during quiet-prompt setup" on the first run).
  front || fail_env "$LABEL: copy lost focus after being placed on the built-in display"
  # Type at the pane's own login shell and run NOTHING in it. An earlier version typed
  # `exec /bin/zsh -f` into a fresh tab; that shell exited, the pane entered its kept state
  # and swallowed every key (2026-11-20: "paired=0 unechoed=N" on every line). The defect
  # depends on key events and the caret, not on what the shell echoes, so the operator's
  # prompt is good enough; a prompt that prints on its own would add false pairs.
  # The defect needs a BLINKING caret and config.json may select a steady one, so force
  # DECSCUSR 1 by writing it to the tty of this copy's own child shells. It arrives as
  # terminal output and cannot reach any other terminal.
  local child tty forced=0
  for child in $(pgrep -P "$APP_PID"); do
    tty=$(ps -o tty= -p "$child" | tr -d ' ')
    [[ "$tty" == ttys* ]] || continue
    printf '\033[1 q' > "/dev/$tty" 2>/dev/null && forced=1
  done
  [[ "$forced" -eq 1 ]] || fail_env "$LABEL: cannot reach the test pane's tty to force a blinking caret"
  sleep 1
  phase W
  ax 'set value of attribute "AXFullScreen" of window 1 to true' >/dev/null || fail_env 'cannot enter native fullscreen'
  sleep 4.5
  [[ "$(ax 'get value of attribute "AXFullScreen" of window 1')" == true ]] || fail_env 'native fullscreen not entered'
  phase F
  ax 'set value of attribute "AXFullScreen" of window 1 to false' >/dev/null || fail_env 'cannot leave fullscreen'
  sleep 3.5
  stop_app
}
echo 'LOCAL ONLY: taking focus; windowed + native fullscreen, shipped and delayed-blink.'
run_case shipped
if [[ "$FALSIFY" -eq 1 ]]; then run_case delayed-blink; fi
# Parser owns the verdict, not grep success: missing samples/context are exit 2.
python3 "$PWD/Scripts/fullscreen-latency-report.py" "$TMP" "$FALSIFY"
exit $?
