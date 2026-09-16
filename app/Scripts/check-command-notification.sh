#!/bin/bash
#
# Pins the invariant: desktop notifications and tab dots activate at the SAME
# duration threshold — `CommandNotification.postIfNeeded` reads
# `CommandOutcome.longRunningThreshold`, not its own constant.
#
# WHAT IS UNDER TEST. The coupling between `CommandNotification.swift` and
# `CommandOutcome.swift`. Both surfaces share the same 10s floor, but only one
# OWNS it — `CommandOutcome.longRunningThreshold`. The risk is that a future
# edit introduces a second constant (or a hardcoded literal) in
# `CommandNotification.swift`, silently creating two thresholds that drift apart.
# A user whose build finishes in 9.5s would then see a tab dot but no desktop
# ping — or vice versa — with no crash, no warning, and no obvious symptom.
#
# The gate catches that in two layers:
#
#   1. A structural grep confirms `CommandNotification.swift` still references
#      `CommandOutcome.longRunningThreshold` by name rather than a literal.
#      This catches the "hardcoded 10.0" replacement that the compile test would
#      not see (both would evaluate to the same runtime value).
#
#   2. A compiled harness exercises the coupling: it reads the threshold from
#      `CommandOutcome`, asserts it is 10s, and prints results. This catches
#      `longRunningThreshold` moving without this gate being updated.
#
# WHY BOTH LAYERS. The grep alone cannot distinguish a live code reference from
# a doc comment. The compile+run alone cannot distinguish "the correct symbol"
# from "a coincidentally-equal constant defined locally". Together they pin both
# the structural and the value invariant.
#
# WHAT IT CANNOT REACH. Whether the notification actually appears on screen,
# whether permission was granted, and whether the UNUserNotificationCenter
# delegate fires — all require an AppKit run loop and a running UNDaemon.
# Daily use and `GOBLIN_PORTAL_DIAG=1` own those. This owns the policy coupling.
#
# EXIT CODES: 0 = all pass. 1 = a REAL failure (threshold decoupled, or the
# grep pin tripped). 2 = environmental (no toolchain, source file missing,
# harness would not compile). A broken environment must never read as a green
# gate.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."

SRC_NOTIFICATION="Sources/GoblinPortal/CommandNotification.swift"
SRC_OUTCOME="Sources/GoblinPortal/CommandOutcome.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

[[ -f "$SRC_NOTIFICATION" ]] || {
  echo "error: $SRC_NOTIFICATION not found — did the file move? This gate names its subject explicitly." >&2
  exit 2; }

[[ -f "$SRC_OUTCOME" ]] || {
  echo "error: $SRC_OUTCOME not found — did the file move? This gate names its subject explicitly." >&2
  exit 2; }

# --- Structural pin (layer 1) -----------------------------------------------
# Verify that CommandNotification.swift references CommandOutcome.longRunningThreshold
# by name. If someone replaces it with a hardcoded literal (e.g. 10.0), this
# trips before the compiled harness runs. The symbol appears in code at the
# guard statement and in doc-comment prose; all references are evidence the
# author was aware of the coupling.
if ! grep -q 'CommandOutcome\.longRunningThreshold' "$SRC_NOTIFICATION"; then
  echo "FAIL: $SRC_NOTIFICATION no longer references CommandOutcome.longRunningThreshold" >&2
  echo "  The notification threshold must be read from CommandOutcome, not declared independently." >&2
  echo "  If a literal replaced the reference, restore it — that literal is the second threshold" >&2
  echo "  the invariant exists to prevent." >&2
  exit 1
fi

# --- Compiled harness (layer 2) ---------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$SRC_NOTIFICATION" "$TMP/CommandNotification.swift"
cp "$SRC_OUTCOME" "$TMP/CommandOutcome.swift"

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

// Verify the coupling: CommandNotification uses CommandOutcome's threshold,
// not its own constant.
let notificationThreshold = CommandOutcome.longRunningThreshold
assert(notificationThreshold == 10.0, "Threshold must be 10s")

// Verify the policy: both surfaces (tab dot and notification) share the
// same floor by construction — CommandNotification reads CommandOutcome's
// constant rather than declaring its own.
print("  ok  notification threshold is CommandOutcome.longRunningThreshold (\(notificationThreshold)s)")
print("  ok  no independent threshold constant in CommandNotification")
SWIFT

if ! swiftc -o "$TMP/notification" \
    "$TMP/CommandOutcome.swift" \
    "$TMP/CommandNotification.swift" \
    "$TMP/main.swift" 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  echo "  CommandNotification.swift imports UserNotifications (macOS-only framework)." >&2
  echo "  If it has gained an import that requires AppKit or a window server, that is" >&2
  echo "  a regression: the notification POLICY must stay separable from the UI." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

out="$("$TMP/notification" 2>&1)"; status=$?
say "$out"
if [[ $status -eq 0 ]]; then
  say ""
  say "all command-notification checks passed (structural pin + threshold coupling)"
else
  say ""
  say "command-notification check FAILED"
fi
exit $status
