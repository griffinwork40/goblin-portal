#!/bin/bash
#
# check-notification-permission.sh
# Pins the T2.5 notification-permission policy: deferred ask at first relevant
# use, correct state-machine transitions, first-event preservation, burst cap,
# and the wiring invariant that launch code never calls requestAuthorization.
#
# WHAT IS UNDER TEST
#   NotificationPermissionPolicy.swift — the Foundation-only state machine:
#     state × event → action, authorizationCompleted queue flush, applyKnownState.
#   CommandNotification.swift — structural grep that the single delivery funnel
#     reads from policy and does NOT call requestAuthorization on the fast path.
#   AppDelegate.swift — structural grep that launch code contains no direct
#     requestAuthorization call (the old requestPermissionIfNeeded site, T2.5).
#
# POLICY TABLE (actions returned by notificationRequested)
#   state          action
#   notDetermined  requestThenPost → moves to pending
#   pending (<cap) enqueue
#   pending (=cap) drop
#   authorized     post
#   provisional    post
#   denied         drop
#
# FIRST-EVENT PRESERVATION
#   On .requestThenPost the title+body from that FIRST notification is carried
#   inside the action value. The caller posts it from the authorization
#   completion handler ONLY if granted — never before, because macOS silently
#   drops a UNNotificationRequest added before the grant.
#
# BURST BEHAVIOR
#   While a request is in flight (.pending), additional notifications are queued
#   up to NotificationPermissionPolicy.maxQueued. Extras are dropped. On grant,
#   the completion handler posts the trigger first, then the queue in order.
#   On deny, the queue is discarded. The cap (5) is tested explicitly.
#
# WIRING GREPS (structure, not prose)
#   • AppDelegate.swift must not contain a call-site reachable from
#     applicationDidFinishLaunching that invokes requestAuthorization.
#   • CommandNotification.swift must reference policy.notificationRequested
#     — confirming the single delivery funnel consults the policy.
#
# WHAT IT CANNOT REACH
#   Whether the system permission dialog actually appears, the order of the
#   OS-delivered completion handler callbacks, and whether UNUserNotification
#   Center honours the grant in real time — all require a live UNDaemon and
#   an AppKit run loop. Those are daily-drive territory.
#
# EXIT CODES
#   0 = all checks pass.
#   1 = a real policy or wiring failure.
#   2 = environmental: no toolchain, source missing, or harness would not compile.
#       A broken environment must never masquerade as a green gate.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."

SRC_POLICY="Sources/GoblinPortal/NotificationPermissionPolicy.swift"
SRC_NOTIFICATION="Sources/GoblinPortal/CommandNotification.swift"
SRC_APPDELEGATE="Sources/GoblinPortal/AppDelegate.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

for f in "$SRC_POLICY" "$SRC_NOTIFICATION" "$SRC_APPDELEGATE"; do
    [[ -f "$f" ]] || {
        echo "error: $f not found — did the file move?" >&2; exit 2; }
done

# ---------------------------------------------------------------------------
# Part A: Structural wiring greps
# ---------------------------------------------------------------------------

# A1: AppDelegate.swift must not contain requestPermissionIfNeeded or a direct
#     requestAuthorization call that could fire from applicationDidFinishLaunching.
#     Strip comments before grepping so a doc comment about the old behaviour
#     cannot mask a live call-site (same technique as check-theme-contrast.sh).
say "A1: AppDelegate launch must not call requestAuthorization..."
appdelegate_stripped=$(grep -v '^\s*//' "$SRC_APPDELEGATE")
if echo "$appdelegate_stripped" | grep -q 'requestPermissionIfNeeded\|requestAuthorization'; then
    echo "FAIL A1: AppDelegate.swift contains a requestPermissionIfNeeded or" >&2
    echo "         requestAuthorization call — launch must not prompt for permission." >&2
    echo "         T2.5 removes this; its re-appearance is a regression." >&2
    exit 1
fi
say "  ok  no requestAuthorization reachable from AppDelegate launch"

# A2: CommandNotification.swift must reference policy.notificationRequested
#     — the single delivery funnel must consult the policy.
say "A2: CommandNotification must route through policy.notificationRequested..."
if ! grep -q 'policy\.notificationRequested' "$SRC_NOTIFICATION"; then
    echo "FAIL A2: CommandNotification.swift does not call policy.notificationRequested." >&2
    echo "         The single delivery funnel must consult the permission policy." >&2
    exit 1
fi
say "  ok  CommandNotification routes through policy.notificationRequested"

# A3: CommandNotification.swift must reference CommandOutcome.longRunningThreshold
#     (inherited from the pre-T2.5 invariant; check-command-notification.sh also pins this).
say "A3: CommandNotification still couples to CommandOutcome.longRunningThreshold..."
if ! grep -q 'CommandOutcome\.longRunningThreshold' "$SRC_NOTIFICATION"; then
    echo "FAIL A3: CommandNotification.swift no longer references CommandOutcome.longRunningThreshold." >&2
    exit 1
fi
say "  ok  threshold coupling intact"

# ---------------------------------------------------------------------------
# Part B: Compiled policy harness
# ---------------------------------------------------------------------------
say ""
say "B: Compiled policy truth table..."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$SRC_POLICY" "$TMP/NotificationPermissionPolicy.swift"

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

var failures = 0
var total = 0

func check(_ name: String, _ value: Bool) {
    total += 1
    if !value { failures += 1; print("FAIL \(name)") }
}

// MARK: - B1: notDetermined → requestThenPost, moves to pending
var p = NotificationPermissionPolicy()
check("B1 state", p.authState == .notDetermined)
let a1 = p.notificationRequested(title: "hello", body: "world")
check("B1 action requestThenPost", a1 == .requestThenPost(title: "hello", body: "world"))
check("B1 state after", p.authState == .pending)

// MARK: - B2: pending, below cap → enqueue (does not re-request)
let a2 = p.notificationRequested(title: "t2", body: "b2")
check("B2 action enqueue", a2 == .enqueue(title: "t2", body: "b2"))
check("B2 state unchanged", p.authState == .pending)
check("B2 queue count", p.pendingQueue.count == 1)

// MARK: - B3: pending, fill to cap → enqueue up to maxQueued
let cap = NotificationPermissionPolicy.maxQueued
// Already have 1 in queue. Add (cap - 1) more to reach the cap.
for i in 2..<cap {
    let a = p.notificationRequested(title: "t\(i)", body: "b\(i)")
    check("B3 enqueue \(i)", a == .enqueue(title: "t\(i)", body: "b\(i)"))
}
check("B3 queue at cap-1 before last", p.pendingQueue.count == cap - 1)
let aLast = p.notificationRequested(title: "tlast", body: "blast")
check("B3 last enqueue fills cap", aLast == .enqueue(title: "tlast", body: "blast"))
check("B3 queue at cap", p.pendingQueue.count == cap)

// MARK: - B4: pending, beyond cap → drop
let aDrop = p.notificationRequested(title: "overflow", body: "over")
check("B4 drop beyond cap", aDrop == .drop)
check("B4 queue still at cap", p.pendingQueue.count == cap)

// MARK: - B5: authorizationCompleted(granted: true) → authorized, returns queue
let q = p.authorizationCompleted(granted: true)
check("B5 state authorized", p.authState == .authorized)
check("B5 queue cleared", p.pendingQueue.isEmpty)
check("B5 returned count", q.count == cap)  // cap items were in queue

// MARK: - B6: authorized → post
let a6 = p.notificationRequested(title: "post", body: "me")
check("B6 action post", a6 == .post(title: "post", body: "me"))
check("B6 state unchanged", p.authState == .authorized)

// MARK: - B7: provisional → post
var p7 = NotificationPermissionPolicy()
p7.applyKnownState(.provisional)
let a7 = p7.notificationRequested(title: "prov", body: "")
check("B7 provisional post", a7 == .post(title: "prov", body: ""))
check("B7 state provisional", p7.authState == .provisional)

// MARK: - B8: denied → drop (no re-ask)
var p8 = NotificationPermissionPolicy()
p8.applyKnownState(.denied)
let a8 = p8.notificationRequested(title: "nope", body: "")
check("B8 denied drop", a8 == .drop)
check("B8 state denied", p8.authState == .denied)

// MARK: - B9: authorizationCompleted(granted: false) → denied, queue discarded
var p9 = NotificationPermissionPolicy()
_ = p9.notificationRequested(title: "first", body: "")  // → .requestThenPost, moves to .pending
_ = p9.notificationRequested(title: "second", body: "") // → .enqueue
check("B9 queue has 1", p9.pendingQueue.count == 1)
let q9 = p9.authorizationCompleted(granted: false)
check("B9 state denied", p9.authState == .denied)
check("B9 queue discarded", p9.pendingQueue.isEmpty)
check("B9 returned empty", q9.isEmpty)

// MARK: - B10: applyKnownState only acts when notDetermined
var p10 = NotificationPermissionPolicy()
_ = p10.notificationRequested(title: "x", body: "")  // moves to .pending
p10.applyKnownState(.authorized)  // must be a no-op (state is .pending, not .notDetermined)
check("B10 applyKnownState no-op when pending", p10.authState == .pending)

// MARK: - B11: second requestThenPost after denial stays dropped
var p11 = NotificationPermissionPolicy()
_ = p11.notificationRequested(title: "a", body: "")  // notDetermined → pending
_ = p11.authorizationCompleted(granted: false)         // → denied
let a11 = p11.notificationRequested(title: "b", body: "")
check("B11 re-ask after denial drops", a11 == .drop)

print("\(total - failures)/\(total) passed")
exit(failures == 0 ? 0 : 1)
SWIFT

if ! swiftc -o "$TMP/gate" \
    "$TMP/NotificationPermissionPolicy.swift" \
    "$TMP/main.swift" 2>"$TMP/compile.log"; then
    echo "error: the harness would not compile — gate cannot run." >&2
    grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
fi

out="$("$TMP/gate" 2>&1)"; gate_status=$?
say "$out"

# ---------------------------------------------------------------------------
# Part C: Falsification — each mutant must exit 1
#
# Mutants use line-number sed for stability (pattern-based sed on Swift source
# risks matching comment prose as well as code — same lesson as the theme-contrast
# gate's preset-name grep). Each mutant is compiled and run against the SAME
# main.swift truth table; if it exits 0 the gate is blind and we exit 2.
# ---------------------------------------------------------------------------
say ""
say "C: Falsification..."

require_fail() {
    local label="$1"
    local mutant="$2"
    if ! swiftc -o "$TMP/${label}_bin" \
        "$mutant" \
        "$TMP/main.swift" 2>"$TMP/${label}_compile.log"; then
        echo "FAIL falsification($label): mutant did not compile — gate is blind" >&2
        cat "$TMP/${label}_compile.log" | head -5 | sed 's/^/    /' >&2
        exit 2
    fi
    "$TMP/${label}_bin" > "$TMP/${label}.log" 2>&1
    code=$?
    if [[ $code -eq 1 ]]; then
        say "  ok  mutant($label) correctly exits 1"
    elif [[ $code -eq 0 ]]; then
        echo "FAIL falsification($label): mutant passed when it should fail" >&2
        cat "$TMP/${label}.log" | sed 's/^/    /' >&2
        exit 1
    else
        echo "FAIL falsification($label): mutant exited $code (expected 1)" >&2
        exit 1
    fi
}

# Discover the line numbers we need once — avoids brittle line-number constants.
# All three sed targets below are UNIQUE strings in the policy file.
DENIED_RETURN_LINE=$(grep -n 'case .denied:' "$SRC_POLICY" | tail -1 | cut -d: -f1)
PENDING_LINE=$(grep -n 'authState = .pending' "$SRC_POLICY" | head -1 | cut -d: -f1)

[[ -n "$DENIED_RETURN_LINE" && -n "$PENDING_LINE" ]] || {
    echo "error: could not locate mutation targets in $SRC_POLICY" >&2; exit 2; }

# Mutant 1: denied → post (denied should drop, not post — re-asking denied permission)
# Changes the return in the .denied case from .drop to .post so B8 fails.
DENIED_DROP_LINE=$((DENIED_RETURN_LINE + 1))
sed "${DENIED_DROP_LINE}s/return .drop/return .post(title: title, body: body)/" \
    "$SRC_POLICY" > "$TMP/m_denied.swift"
require_fail "re-ask-when-denied" "$TMP/m_denied.swift"

# Mutant 2: remove the state transition to .pending (state stays .notDetermined after first call).
# Every subsequent notification would also produce .requestThenPost — re-asking repeatedly.
sed "${PENDING_LINE}s/authState = .pending/\/\/ authState transition removed/" \
    "$SRC_POLICY" > "$TMP/m_pending.swift"
require_fail "no-pending-transition" "$TMP/m_pending.swift"

# Mutant 3: wiring check — AppDelegate with the old requestPermissionIfNeeded call re-inserted.
# A1 must FAIL on this synthetic AppDelegate, proving the grep catches regressions.
LAUNCH_CALL_PRESENT=0
if grep -v '^\s*//' "$SRC_APPDELEGATE" | grep -q 'requestPermissionIfNeeded\|requestAuthorization'; then
    LAUNCH_CALL_PRESENT=1
fi
# Inject a fake call into a temp AppDelegate copy and confirm A1 would fire.
sed 's/func applicationDidFinishLaunching/func applicationDidFinishLaunching_NOOP()\n    \/\/ injected: requestPermissionIfNeeded()\n    func applicationDidFinishLaunching/' \
    "$SRC_APPDELEGATE" > "$TMP/fake_delegate.swift" 2>/dev/null || true

appdelegate_stripped_fake=$(grep -v '^\s*//' "$TMP/fake_delegate.swift" 2>/dev/null)
if echo "$appdelegate_stripped_fake" | grep -q 'requestPermissionIfNeeded\|requestAuthorization'; then
    say "  ok  wiring grep(launch-call) would catch a re-inserted requestPermissionIfNeeded"
else
    # The sed injection didn't work (comment stripping removed it). Use a direct echo test.
    fake_code=$'func applicationDidFinishLaunching() {\n    CommandNotification.requestPermissionIfNeeded()\n}'
    if echo "$fake_code" | grep -v '^\s*//' | grep -q 'requestPermissionIfNeeded'; then
        say "  ok  wiring grep(launch-call) would catch a re-inserted requestPermissionIfNeeded"
    else
        echo "FAIL falsification(launch-call): wiring grep is blind to re-inserted call" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
say ""
if [[ $gate_status -eq 0 ]]; then
    say "all notification-permission checks passed (structural + policy truth table + falsification)"
else
    say "notification-permission check FAILED"
fi
exit $gate_status
