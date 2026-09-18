#!/bin/sh
#
# check-update-logic.sh -- Gate for the in-place update logic.
#
# WHAT IS UNDER TEST.
#   Part A (Swift harness): `isNewer` and `findZipAsset` from UpdateChecker.swift.
#     Both are pure functions of their inputs: no AppKit, no URLSession, no
#     @MainActor. Extracted verbatim into check-update-logic-harness.swift and
#     compiled standalone with swiftc. Tests cover the lexicographic trap in
#     semver comparison (1.10.0 > 1.9.0), the Item-4 host allowlist, and the
#     GoblinPortal- name-prefix guard.
#   Part B (shell): The install-update.sh trampoline swap logic. Uses temp dirs
#     and a verified-dead PID to exercise the mv, restore, and cleanup paths
#     without touching /Applications or any live process.
#
# WHY IT EXISTS. The update path has no UI test harness and is exercised only
# by actually installing an update. The two pure functions and the shell swap
# script cover the logic that is most likely to regress silently: wrong semver
# comparison near a double-digit minor version, wrong asset selection after
# adding the host allowlist (Item 4), and unchecked mv failures (Item 1).
#
# WHAT THIS CANNOT TEST.
#   - The full NSURLSession download chain (network required)
#   - The NSAlert UI (AppKit + window server required)
#   - codesign --verify on a real bundle (requires a real signed bundle)
#   - NSApp.terminate (requires a running app)
#   These are verified by daily-drive use only.
#
# EXIT CODES (three-valued, same contract as check-git-status.sh):
#   0 = all cases in both parts passed
#   1 = a real assertion failed (logic is wrong)
#   2 = environmental: no swiftc, source missing, harness will not compile,
#       /bin/sh missing for Part B, or a fixture could not be built
#
# ISOLATION. Everything runs under a mktemp -d removed on EXIT. No file outside
# that directory is created or modified.
#
# NOTE: #!/bin/sh (POSIX) as required by the repo constraint for new scripts.

set -e

# Capture root before any cd. Sources/ is referenced relative to app/.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHECKER="Sources/GoblinPortal/UpdateChecker.swift"
HARNESS="Scripts/check-update-logic-harness.swift"
TRAMPOLINE="Resources/install-update.sh"

# ── Environment checks ────────────────────────────────────────────────────────

for f in "$CHECKER" "$HARNESS" "$TRAMPOLINE"; do
    [ -f "$f" ] || {
        printf 'ENV: %s not found (run from app/ or app/Scripts/)\n' "$f" >&2
        exit 2
    }
done

command -v swiftc >/dev/null 2>&1 || {
    printf 'ENV: no swiftc on PATH\n' >&2; exit 2
}

[ -x /bin/sh ] || {
    printf 'ENV: /bin/sh not executable (needed for Part B)\n' >&2; exit 2
}

WORK="$(mktemp -d)"
# Guarantee cleanup on any exit, including early returns from Part A/B failures.
trap 'rm -rf "$WORK"' EXIT

# ── Part A: Swift harness for isNewer and findZipAsset ───────────────────────
printf '==> Part A: compiling harness against UpdateChecker logic\n'

# Copy harness to main.swift (Swift requires top-level code in main.swift only).
cp "$HARNESS" "$WORK/main.swift"

if ! swiftc -O "$WORK/main.swift" -o "$WORK/part_a" 2>"$WORK/compile.log"; then
    printf 'ENV: harness would not compile against extracted functions\n' >&2
    grep 'error:' "$WORK/compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
fi

PART_A_OUT="$("$WORK/part_a" 2>&1)"
PART_A_STATUS=$?
printf '%s\n' "$PART_A_OUT"

if [ "$PART_A_STATUS" -ne 0 ]; then
    printf '\nPart A FAILED (exit %d)\n' "$PART_A_STATUS"
    exit 1
fi

# ── Part B: trampoline smoke test ─────────────────────────────────────────────
#
# Strategy: use a PID that is guaranteed dead (a fresh subshell that exits
# immediately, captured via $!). install-update.sh polls `kill -0 $PID` until
# the process is gone. With a dead PID, the poll exits immediately and the swap
# proceeds. All paths are under $WORK, never /Applications.
#
printf '\n==> Part B: trampoline smoke test\n'

part_b_failures=0

check_b() {
    # check_b NAME OK [DETAIL]
    name="$1"; ok="$2"; detail="${3:-}"
    if [ "$ok" -eq 0 ]; then
        printf '  ✓ %s\n' "$name"
    else
        printf '  ✗ %s%s\n' "$name" "${detail:+   [$detail]}"
        part_b_failures=$((part_b_failures + 1))
    fi
}

# Stub osascript and open for all B-cases. B.2 and B.3 already used a local
# FAKE_BIN; defining it here covers B.1 too (which previously called real open
# on the test machine, breaking the gate's isolation claim).
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/osascript"
chmod +x "$FAKE_BIN/osascript"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/open"
chmod +x "$FAKE_BIN/open"

# ── B.1: happy path -- dead PID, new content lands at installed path ──────────
printf '\nB.1 — happy path: new bundle moved into place, backup cleaned up\n'

INSTALLED="$WORK/installed/GoblinPortal.app"
NEWAPP="$WORK/new/GoblinPortal.app"
TMPDIR_B1="$WORK/tmp_b1"

# Build a properly-structured minimal bundle. codesign --strict requires:
#   Contents/Info.plist  (declares the bundle)
#   Contents/MacOS/<executable>  (the main binary)
# The identity marker is in the executable itself (echo 'new-version'), not in
# a separate data file -- codesign seals all bundle resources, so an extra file
# like version.txt inside Contents/ must be excluded from signing or it causes
# "code object is not signed at all" on older macOS toolchains.
mkdir -p "$INSTALLED/Contents/MacOS" "$NEWAPP/Contents/MacOS" "$TMPDIR_B1"
# Old installed executable prints "old-version"; new one prints "new-version".
# The trampoline's mv replaces the installed bundle; reading the executable
# tells us which version landed.
printf '#!/bin/sh\necho old-version\n' > "$INSTALLED/Contents/MacOS/GoblinPortal"
chmod +x "$INSTALLED/Contents/MacOS/GoblinPortal"
printf '#!/bin/sh\necho new-version\n' > "$NEWAPP/Contents/MacOS/GoblinPortal"
chmod +x "$NEWAPP/Contents/MacOS/GoblinPortal"
# Minimal Info.plist required for codesign to treat the directory as a bundle.
printf '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.test.goblinportal-update-gate</string>
</dict></plist>
' > "$NEWAPP/Contents/Info.plist"
# Ad-hoc sign AFTER all files are placed. Only the executable + Info.plist in
# the bundle, so codesign --strict has nothing unexpected to reject.
codesign --sign - --force "$NEWAPP" 2>/dev/null || true

# Launch a subshell that exits immediately. Its PID is guaranteed dead by the
# time install-update.sh's first kill -0 runs (the script itself has startup
# overhead in the hundreds of milliseconds).
(exit 0) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true

set +e
PATH="$FAKE_BIN:$PATH" /bin/sh "$TRAMPOLINE" "$DEAD_PID" "$NEWAPP" "$INSTALLED" "$TMPDIR_B1" 2>/dev/null
TRAMPOLINE_EXIT_B1=$?
set -e

check_b "trampoline exits 0 on happy path" \
    "$([ "$TRAMPOLINE_EXIT_B1" -eq 0 ] && echo 0 || echo 1)" \
    "exit=$TRAMPOLINE_EXIT_B1"

# The new content must be at the installed path.
# The new executable prints "new-version" when run.
if [ -x "$INSTALLED/Contents/MacOS/GoblinPortal" ]; then
    got="$("$INSTALLED/Contents/MacOS/GoblinPortal" 2>/dev/null)"
    check_b "new bundle content at installed path" \
        "$([ "$got" = 'new-version' ] && echo 0 || echo 1)" \
        "got: $got"
else
    check_b "new bundle content at installed path" 1 "GoblinPortal executable missing"
fi

# Backup must have been cleaned up (moved to Trash or removed).
BACKUP_PATTERN="$WORK/installed/GoblinPortal.app.bak-"
found_backup=0
for f in "$WORK/installed/GoblinPortal.app.bak-"*; do
    [ -e "$f" ] && found_backup=1 && break
done
check_b "backup cleaned up after success" "$found_backup"

# Temp dir must be cleaned up.
check_b "temp dir cleaned up after success" "$([ -d "$TMPDIR_B1" ] && echo 1 || echo 0)"

# ── B.2: failed-mv path -- trampoline restores backup ────────────────────────
# Simulate the mv-new-into-place failure by making the installed directory
# read-only AFTER the backup has been moved aside. We cannot hook mid-script,
# so instead we test the restore logic by feeding an unreadable NEW_APP path.
# The trampoline will: mv installed→backup (succeeds), mv unreadable→installed
# (fails because the path does not exist), then restore backup→installed.
printf '\nB.2 — failed mv: backup restored to installed path\n'

INSTALLED_B2="$WORK/installed_b2/GoblinPortal.app"
TMPDIR_B2="$WORK/tmp_b2"
NONEXISTENT_APP="$WORK/nonexistent/GoblinPortal.app"

mkdir -p "$INSTALLED_B2/Contents/MacOS" "$TMPDIR_B2"
printf '#!/bin/sh\necho original\n' > "$INSTALLED_B2/Contents/MacOS/GoblinPortal"
chmod +x "$INSTALLED_B2/Contents/MacOS/GoblinPortal"

# Disable set -e so a failed trampoline does not abort the test script.
set +e
(exit 0) &
DEAD_PID2=$!
wait "$DEAD_PID2" 2>/dev/null || true
PATH="$FAKE_BIN:$PATH" /bin/sh "$TRAMPOLINE" "$DEAD_PID2" "$NONEXISTENT_APP" "$INSTALLED_B2" "$TMPDIR_B2" 2>/dev/null
TRAMPOLINE_EXIT=$?
set -e

# The trampoline should exit non-zero (restore path hit).
check_b "trampoline exits non-zero on failed mv" \
    "$([ "$TRAMPOLINE_EXIT" -ne 0 ] && echo 0 || echo 1)" \
    "exit=$TRAMPOLINE_EXIT"

# The original content must have been restored.
if [ -x "$INSTALLED_B2/Contents/MacOS/GoblinPortal" ]; then
    restored="$("$INSTALLED_B2/Contents/MacOS/GoblinPortal" 2>/dev/null)"
    check_b "original version restored after failed mv" \
        "$([ "$restored" = 'original' ] && echo 0 || echo 1)" \
        "got: $restored"
else
    check_b "original version restored after failed mv" 1 "GoblinPortal executable missing after restore"
fi

# Temp dir must still be cleaned up (trap on EXIT fires regardless of failure).
check_b "temp dir cleaned up after failed mv" \
    "$([ -d "$TMPDIR_B2" ] && echo 1 || echo 0)"

# ── B.3: codesign-failure path -- trampoline removes bad bundle, restores ──
# Stub codesign via a PATH shadow so the trampoline's codesign --verify fails.
# This exercises the restore branch that the review found was broken before the
# rm -rf fix: POSIX mv nests the backup INSIDE an existing directory target
# instead of replacing it. The fix is rm -rf $INSTALLED_APP before the restore
# mv, and this case proves the restore now works end to end.
printf '\nB.3 — codesign failure: bad bundle removed, backup restored\n'

INSTALLED_B3="$WORK/installed_b3/GoblinPortal.app"
NEWAPP_B3="$WORK/new_b3/GoblinPortal.app"
TMPDIR_B3="$WORK/tmp_b3"

mkdir -p "$INSTALLED_B3/Contents/MacOS" "$NEWAPP_B3/Contents/MacOS" "$TMPDIR_B3"
printf '#!/bin/sh\necho original-b3\n' > "$INSTALLED_B3/Contents/MacOS/GoblinPortal"
chmod +x "$INSTALLED_B3/Contents/MacOS/GoblinPortal"
printf '#!/bin/sh\necho new-bad-b3\n' > "$NEWAPP_B3/Contents/MacOS/GoblinPortal"
chmod +x "$NEWAPP_B3/Contents/MacOS/GoblinPortal"
printf '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.test.goblinportal-update-gate</string>
</dict></plist>
' > "$NEWAPP_B3/Contents/Info.plist"
# Do NOT sign the new bundle -- codesign --verify will fail on it.

# Shadow codesign with a stub that always fails. The trampoline runs codesign
# after the mv, so this makes the codesign-failure restore branch fire.
# osascript and open stubs are already in FAKE_BIN (created before B.1).
printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/codesign"
chmod +x "$FAKE_BIN/codesign"

set +e
(exit 0) &
DEAD_PID3=$!
wait "$DEAD_PID3" 2>/dev/null || true
PATH="$FAKE_BIN:$PATH" /bin/sh "$TRAMPOLINE" "$DEAD_PID3" "$NEWAPP_B3" "$INSTALLED_B3" "$TMPDIR_B3" 2>/dev/null
TRAMPOLINE_EXIT_B3=$?
set -e

check_b "trampoline exits non-zero on codesign failure" \
    "$([ "$TRAMPOLINE_EXIT_B3" -ne 0 ] && echo 0 || echo 1)" \
    "exit=$TRAMPOLINE_EXIT_B3"

# The original content must have been restored (not nested inside the bad bundle).
if [ -x "$INSTALLED_B3/Contents/MacOS/GoblinPortal" ]; then
    restored_b3="$("$INSTALLED_B3/Contents/MacOS/GoblinPortal" 2>/dev/null)"
    check_b "original version restored after codesign failure" \
        "$([ "$restored_b3" = 'original-b3' ] && echo 0 || echo 1)" \
        "got: $restored_b3"
else
    check_b "original version restored after codesign failure" 1 \
        "GoblinPortal executable missing after codesign-failure restore"
fi

check_b "temp dir cleaned up after codesign failure" \
    "$([ -d "$TMPDIR_B3" ] && echo 1 || echo 0)"

# ── B.4: PID validation -- non-numeric and negative PIDs rejected (Item 7) ────
printf '\nB.4 — PID validation: non-numeric and non-positive PIDs rejected\n'

TMPDIR_B4="$WORK/tmp_b4"

# B.4a: non-numeric PID must be rejected with exit 2.
mkdir -p "$TMPDIR_B4"
set +e
/bin/sh "$TRAMPOLINE" "abc" "/dev/null" "/dev/null" "$TMPDIR_B4" 2>/dev/null
B4A_EXIT=$?
set -e
check_b "non-numeric PID rejected (exit 2)" \
    "$([ "$B4A_EXIT" -eq 2 ] && echo 0 || echo 1)" \
    "exit=$B4A_EXIT"

# B.4b: negative PID must be rejected with exit 2.
TMPDIR_B4B="$WORK/tmp_b4b"
mkdir -p "$TMPDIR_B4B"
set +e
/bin/sh "$TRAMPOLINE" "-1" "/dev/null" "/dev/null" "$TMPDIR_B4B" 2>/dev/null
B4B_EXIT=$?
set -e
check_b "negative PID rejected (exit 2)" \
    "$([ "$B4B_EXIT" -eq 2 ] && echo 0 || echo 1)" \
    "exit=$B4B_EXIT"

# B.4c: zero PID must be rejected with exit 2.
TMPDIR_B4C="$WORK/tmp_b4c"
mkdir -p "$TMPDIR_B4C"
set +e
/bin/sh "$TRAMPOLINE" "0" "/dev/null" "/dev/null" "$TMPDIR_B4C" 2>/dev/null
B4C_EXIT=$?
set -e
check_b "zero PID rejected (exit 2)" \
    "$([ "$B4C_EXIT" -eq 2 ] && echo 0 || echo 1)" \
    "exit=$B4C_EXIT"

# ── Part B summary ────────────────────────────────────────────────────────────
printf '\n'
if [ "$part_b_failures" -eq 0 ]; then
    printf 'Part B: all trampoline smoke-test cases passed\n'
else
    printf 'Part B: %d trampoline case(s) FAILED\n' "$part_b_failures"
fi

# ── Overall exit ──────────────────────────────────────────────────────────────
if [ "$part_b_failures" -gt 0 ]; then
    exit 1
fi
exit 0
