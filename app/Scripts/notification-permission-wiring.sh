# Sourced by check-notification-permission.sh — never run on its own. The WIRING
# and FALSIFICATION half of the notification-permission gate: structural greps
# that pin AppDelegate/CommandNotification invariants, plus mutant injection that
# proves those greps are not blind.
#
# Split out of check-notification-permission.sh when restoring the per-assertion
# explanatory comments pushed the script past the 350-line ceiling.  The seam is
# the concern layer: check-notification-permission.sh keeps the header, the
# compiled policy truth table (Part B), and the summary; this file owns the
# comment-stripped wiring greps (Part A) and the falsification mutants (Part C).
# It inherits SRC_POLICY, SRC_NOTIFICATION, SRC_APPDELEGATE,
# SRC_APPDELEGATE_NOTIF, TMP, gate_status, and the say helper from its caller,
# and its `exit`s are the caller's exits.

# ---------------------------------------------------------------------------
# Part A: Structural wiring greps
# ---------------------------------------------------------------------------

# A1: AppDelegate must not call requestPermissionIfNeeded or requestAuthorization
#     from launch.  Comments stripped first (same technique as check-theme-contrast.sh)
#     so a doc comment about the old behaviour cannot mask a live call-site.
#     getNotificationSettings IS allowed (#229) — it reads existing auth state
#     without prompting the user.
#     Function form lets mutant 3 (Part C) run the SAME assertion against a
#     mutated copy, rather than a re-typed lookalike.
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

# A1b/A1c: #229 wiring — both sides must be present.
#   A1b: AppDelegate.swift calls readNotificationAuthState (the launch site that
#        seeds the policy with the OS's current auth state before the first
#        notification arrives).
#   A1c: AppDelegate+Notifications.swift calls getNotificationSettings (reads
#        existing auth without prompting — the T2.5 rule that replaced the old
#        launch-time requestAuthorization).
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

# A2: CommandNotification structural funnel check (#250 hardened version).
#     The single delivery funnel must consult the permission policy — confirmed
#     by a comment-stripped grep for policy.notificationRequested.  This is the
#     structural invariant: every public entry point reaches the state machine
#     rather than posting directly.
say "A2: CommandNotification must route through policy.notificationRequested..."
if ! grep -q 'policy\.notificationRequested' "$SRC_NOTIFICATION"; then
    echo "FAIL A2: CommandNotification.swift does not call policy.notificationRequested." >&2
    echo "         The single delivery funnel must consult the permission policy." >&2
    exit 1
fi
say "  ok  CommandNotification routes through policy.notificationRequested"

# A3: CommandNotification.swift must reference CommandOutcome.longRunningThreshold
#     (inherited from the pre-T2.5 invariant; check-command-notification.sh also
#     pins this, so the coupling survives even if one gate is removed).
say "A3: CommandNotification still couples to CommandOutcome.longRunningThreshold..."
if ! grep -q 'CommandOutcome\.longRunningThreshold' "$SRC_NOTIFICATION"; then
    echo "FAIL A3: CommandNotification.swift no longer references CommandOutcome.longRunningThreshold." >&2
    exit 1
fi
say "  ok  threshold coupling intact"

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

# Mutant 1: denied → post (denied should drop, not post — re-asking denied
# permission).  Changes the return in the .denied case from .drop to .post so
# B8 must fail.
DENIED_DROP_LINE=$((DENIED_RETURN_LINE + 1))
sed "${DENIED_DROP_LINE}s/return .drop/return .post(title: title, body: body)/" \
    "$SRC_POLICY" > "$TMP/m_denied.swift"
if cmp -s "$SRC_POLICY" "$TMP/m_denied.swift"; then
    echo "error: mutant 1 sed did not apply — target line may have shifted" >&2; exit 2
fi
require_fail "re-ask-when-denied" "$TMP/m_denied.swift"

# Mutant 2: remove the state transition to .pending (state stays .notDetermined
# after first call).  Every subsequent notification would also produce
# .requestThenPost — re-asking repeatedly.  B1 state-after and B2 enqueue must
# fail.
sed "${PENDING_LINE}s/authState = .pending/\/\/ authState transition removed/" \
    "$SRC_POLICY" > "$TMP/m_pending.swift"
require_fail "no-pending-transition" "$TMP/m_pending.swift"

# Mutant 3: wiring.  Re-insert the old launch-time call as LIVE code (not a
# comment, which A1's own comment-stripping would remove) into a COPY of the
# shipped AppDelegate, and require A1's function to fire on it.  The first cut
# of this mutant injected a comment and fell back to a hardcoded string, so it
# could never fail (PR #227 land review, R1.1).
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
