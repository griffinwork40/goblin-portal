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
#   A1:  AppDelegate must not call requestAuthorization at launch (getNotificationSettings ok).
#   A1b: AppDelegate calls readNotificationAuthState (#229 launch wiring).
#   A1c: AppDelegate+Notifications uses getNotificationSettings (reads without prompting).
#   A2:  CommandNotification public entry points funnel through post(title:), never actuallyPost.
#   A3:  CommandNotification couples to CommandOutcome.longRunningThreshold.
#
# WHAT IT CANNOT REACH
#   System permission dialog timing, OS completion-handler ordering, UNDaemon
#   behaviour under a live AppKit run loop — daily-drive territory.
#
# EXIT CODES
#   0 = all checks pass.  1 = policy/wiring failure.
#   2 = environmental (no toolchain, missing source, harness would not compile).
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."

SRC_POLICY="Sources/GoblinPortal/NotificationPermissionPolicy.swift"
SRC_NOTIFICATION="Sources/GoblinPortal/CommandNotification.swift"
SRC_APPDELEGATE="Sources/GoblinPortal/AppDelegate.swift"
SRC_APPDELEGATE_NOTIF="Sources/GoblinPortal/AppDelegate+Notifications.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

for f in "$SRC_POLICY" "$SRC_NOTIFICATION" "$SRC_APPDELEGATE" "$SRC_APPDELEGATE_NOTIF"; do
    [[ -f "$f" ]] || {
        echo "error: $f not found — did the file move?" >&2; exit 2; }
done

# ---------------------------------------------------------------------------
# Part A: Structural wiring greps
# ---------------------------------------------------------------------------

# A1: AppDelegate must not call requestPermissionIfNeeded or requestAuthorization at launch.
#     getNotificationSettings IS allowed (#229). Comments stripped; function form lets mutant 3
#     run the same assertion against a mutated copy.
launch_calls_permission() {
    grep -v '^\s*//' "$1" | grep -q 'requestPermissionIfNeeded\|requestAuthorization'
}
say "A1: AppDelegate launch must not call requestAuthorization (getNotificationSettings allowed)..."
if launch_calls_permission "$SRC_APPDELEGATE"; then
    echo "FAIL A1: AppDelegate.swift contains requestPermissionIfNeeded or requestAuthorization." >&2
    echo "         Launch must not prompt — T2.5. getNotificationSettings is allowed." >&2
    exit 1
fi
say "  ok  no requestAuthorization reachable from AppDelegate launch"

# A1b: AppDelegate calls readNotificationAuthState (#229). A1c: AppDelegate+Notifications
#       calls getNotificationSettings (reads existing auth without prompting).
say "A1b: AppDelegate.swift calls readNotificationAuthState (#229 launch wiring)..."
if ! grep -v '^\s*//' "$SRC_APPDELEGATE" | grep -q 'readNotificationAuthState'; then
    echo "FAIL A1b: AppDelegate.swift does not call readNotificationAuthState (#229)." >&2
    exit 1
fi
say "  ok  readNotificationAuthState wired at launch"
say "A1c: AppDelegate+Notifications implements via getNotificationSettings (no prompt)..."
if ! grep -v '^\s*//' "$SRC_APPDELEGATE_NOTIF" | grep -q 'getNotificationSettings'; then
    echo "FAIL A1c: AppDelegate+Notifications.swift does not call getNotificationSettings." >&2
    exit 1
fi
say "  ok  getNotificationSettings used (reads without prompting)"

# A2: CommandNotification structural funnel check (comment-stripped): both public entry
#     points call post(title:) and neither calls actuallyPost directly.
#     Falsified by rewiring postEscapeNotification to call actuallyPost directly.
say "A2: CommandNotification public entry points must funnel through post(title:)..."
_a2_fail() { echo "FAIL A2: $*" >&2; exit 1; }
# Strip line comments, then extract the body of each public function up to its
# closing brace (lines between the func line and the next standalone '}').
_body() { awk "/static func $1/,/^    }$/{print}" "$SRC_NOTIFICATION" | grep -v '^\s*//' ; }
_body postIfNeeded       | grep -q 'post(title:'        || _a2_fail "postIfNeeded does not call post(title:)"
_body postEscapeNotification | grep -q 'post(title:'   || _a2_fail "postEscapeNotification does not call post(title:)"
_body postIfNeeded       | grep -q 'actuallyPost'       && _a2_fail "postIfNeeded calls actuallyPost directly"
_body postEscapeNotification | grep -q 'actuallyPost'  && _a2_fail "postEscapeNotification calls actuallyPost directly"
say "  ok  both public entry points funnel through post(title:) only"

# A3: CommandNotification must reference CommandOutcome.longRunningThreshold (pre-T2.5 invariant).
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

// MARK: - B5b: trigger-only grant — one notification, no burst, grant → authorized, queue empty
var p5b = NotificationPermissionPolicy()
_ = p5b.notificationRequested(title: "only", body: "one")  // → .requestThenPost, state .pending
check("B5b state pending", p5b.authState == .pending)
check("B5b queue empty before grant", p5b.pendingQueue.isEmpty)  // no burst; nothing enqueued
let q5b = p5b.authorizationCompleted(granted: true)
check("B5b state authorized", p5b.authState == .authorized)
check("B5b returned queue empty", q5b.isEmpty)  // trigger carried in action value, not queue
check("B5b pendingQueue cleared", p5b.pendingQueue.isEmpty)

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

// MARK: - B12: applyKnownState(.authorized) before first request → post immediately (#229 seed).
var p12 = NotificationPermissionPolicy()
p12.applyKnownState(.authorized)
check("B12 state authorized after seed", p12.authState == .authorized)
let a12 = p12.notificationRequested(title: "seed", body: "authorized")
check("B12 seeds authorized → post (no requestAuthorization)", a12 == .post(title: "seed", body: "authorized"))

// MARK: - B13: applyKnownState(.denied) before first request → drop, no re-ask (#229 seed).
var p13 = NotificationPermissionPolicy()
p13.applyKnownState(.denied)
check("B13 state denied after seed", p13.authState == .denied)
let a13 = p13.notificationRequested(title: "seed", body: "denied")
check("B13 seeds denied → drop (no requestAuthorization)", a13 == .drop)

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
# Line-number sed for stability; same main.swift truth table; exit 0 = blind gate (exit 2).
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

# Mutant 1: denied → post (should drop); B8 must fail.
DENIED_DROP_LINE=$((DENIED_RETURN_LINE + 1))
sed "${DENIED_DROP_LINE}s/return .drop/return .post(title: title, body: body)/" \
    "$SRC_POLICY" > "$TMP/m_denied.swift"
if cmp -s "$SRC_POLICY" "$TMP/m_denied.swift"; then
    echo "error: mutant 1 sed did not apply — target line may have shifted" >&2; exit 2
fi
require_fail "re-ask-when-denied" "$TMP/m_denied.swift"

# Mutant 2: remove .pending transition; B1 state-after and B2 enqueue must fail.
sed "${PENDING_LINE}s/authState = .pending/\/\/ authState transition removed/" \
    "$SRC_POLICY" > "$TMP/m_pending.swift"
require_fail "no-pending-transition" "$TMP/m_pending.swift"

# Mutant 3: re-insert a live requestPermissionIfNeeded call into AppDelegate and require A1
# to fire. Comment injection cannot work — A1 strips comments first (PR #227 R1.1).
LAUNCH_LINE=$(grep -n 'func applicationDidFinishLaunching(' "$SRC_APPDELEGATE" | head -1 | cut -d: -f1)
[[ -n "$LAUNCH_LINE" ]] || {
    echo "error: applicationDidFinishLaunching not found in $SRC_APPDELEGATE — mutant 3 cannot apply" >&2; exit 2; }
sed "${LAUNCH_LINE}a\\
        CommandNotification.requestPermissionIfNeeded()
" "$SRC_APPDELEGATE" > "$TMP/m_launch_call.swift"
if cmp -s "$SRC_APPDELEGATE" "$TMP/m_launch_call.swift"; then
    echo "FAIL falsification(launch-call): injection did not apply — mutant never ran" >&2
    exit 2
fi
if launch_calls_permission "$TMP/m_launch_call.swift"; then
    say "  ok  mutant(launch-call) A1 fires on a live call re-inserted into applicationDidFinishLaunching"
else
    echo "FAIL falsification(launch-call): A1 is blind to a live re-inserted call" >&2
    exit 1
fi

say ""  # summary
if [[ $gate_status -eq 0 ]]; then
    say "all notification-permission checks passed (structural + policy truth table + falsification)"
else
    say "notification-permission check FAILED"
fi
exit $gate_status
