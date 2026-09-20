#!/bin/sh
#
# install-update.sh -- Trampoline for in-place app updates.
#
# Called by UpdateInstaller.swift with four arguments:
#   $1  PID of the running Goblin Portal process to wait on
#   $2  Path to the NEW .app bundle (in the extraction temp dir)
#   $3  Path to the INSTALLED .app bundle (e.g. /Applications/Goblin Portal.app)
#   $4  Path to the temp directory to clean up after
#
# This script outlives the parent process. It waits for the old app to exit,
# moves the old bundle aside as a .bak (guaranteed rollback path), moves the
# new one in, and relaunches. On any failure it restores the backup and opens
# an alert via osascript.

set -e

PID="$1"
NEW_APP="$2"
INSTALLED_APP="$3"
TEMP_DIR="$4"

# Item 6 -- reject missing or empty arguments. Without this, an empty
# $INSTALLED_APP yields a relative .bak path that mv applies in cwd.
[ $# -eq 4 ] || { printf 'install-update.sh: expected 4 arguments, got %d\n' "$#" >&2; exit 2; }
for _arg in "$PID" "$NEW_APP" "$INSTALLED_APP" "$TEMP_DIR"; do
    [ -n "$_arg" ] || { printf 'install-update.sh: empty argument\n' >&2; exit 2; }
done

# S-1 -- reject relative paths for the three filesystem arguments. A relative
# path would be interpreted against the trampoline's cwd (launchd's root or
# whatever the parent inherited), not the caller's intent. All three must begin
# with '/' -- the PID argument is a decimal integer and is exempt.
for _path in "$NEW_APP" "$INSTALLED_APP" "$TEMP_DIR"; do
    case "$_path" in
        /*) ;;
        *) printf 'install-update.sh: path must be absolute: %s\n' "$_path" >&2; exit 2 ;;
    esac
done

# Item 7 -- validate PID is a positive decimal integer. Without this, a
# non-numeric or negative PID reaches `kill -0` where it is interpreted as
# a process group (negative) or causes an error suppressed by 2>/dev/null
# (non-numeric), letting the script proceed to swap without waiting.
case "$PID" in
    *[!0-9]*) printf 'install-update.sh: PID must be a positive integer\n' >&2; exit 2 ;;
esac
[ "$PID" -gt 0 ] 2>/dev/null || { printf 'install-update.sh: PID must be positive\n' >&2; exit 2; }

# Item 3 -- guarantee cleanup of TEMP_DIR on any exit path (normal, early-return,
# or signal). The explicit rm -rf calls in error branches below are kept: they are
# idempotent and make the intent clear at each failure point without adding risk.
trap 'rm -rf "$TEMP_DIR"' EXIT

# Wait for the running app to exit. Poll every 200ms for up to 30 seconds.
# If it does not exit in time, abort -- never swap under a running process.
waited=0
while kill -0 "$PID" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -ge 150 ]; then
        osascript -e 'display alert "Update failed" message "Goblin Portal did not quit in time. Please quit the app and try again."' || true
        rm -rf "$TEMP_DIR"
        exit 1
    fi
done

# Always move the old bundle aside first so we have a guaranteed rollback path.
# Append the trampoline's own PID ($$) to the epoch timestamp so two
# concurrent invocations within the same second produce distinct paths.
BACKUP="${INSTALLED_APP}.bak-$(date +%s)-$$"
if ! mv "$INSTALLED_APP" "$BACKUP"; then
    osascript -e 'display alert "Update failed" message "Could not prepare the update -- no changes were made. Check disk permissions and try again."' || true
    exit 1
fi

# Move the new bundle into place.
if ! mv "$NEW_APP" "$INSTALLED_APP"; then
    # Restore the backup on failure. Disable set -e so a restore failure does
    # not silently exit without showing the alert.
    set +e
    # Item 1 -- branch on the restore result and show a distinct alert if the
    # backup move itself failed. Without this check, a failed restore exits
    # silently and leaves the user with neither version in place.
    if mv "$BACKUP" "$INSTALLED_APP"; then
        osascript -e 'display alert "Update failed" message "Could not install the new version. The previous version has been restored."'
    else
        osascript -e 'on run argv' \
            -e 'display alert "Update failed" message ("Could not install the new version and the restore also failed. Your previous version is at: " & item 1 of argv)' \
            -e 'end run' -- "$BACKUP"
    fi
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Item 2 -- verify internal code-signature consistency AFTER the bundle is in
# its final location but BEFORE clearing quarantine. codesign --verify --deep
# --strict checks structural integrity (all nested bundles signed, no resource
# file tampering). It does NOT require a Developer ID certificate -- ad-hoc
# signed local builds pass here because what it verifies is internal consistency,
# not identity. It catches structurally malformed or post-signing-tampered
# archives; it does NOT authenticate the signer against a trusted anchor (an
# ad-hoc signed malicious payload passes). The security guarantee is delegated
# to HTTPS transport (GitHub CDN + ATS) and GitHub account integrity.
set +e
if ! codesign --verify --deep --strict "$INSTALLED_APP" 2>/dev/null; then
    # Bundle is structurally invalid. Remove the bad bundle BEFORE restoring
    # the backup. Without this rm, POSIX mv moves the backup INSIDE the
    # existing $INSTALLED_APP directory (because the target is a directory)
    # instead of replacing it -- the backup nests at
    # $INSTALLED_APP/Goblin Portal.app.bak-XXXX/ while the bad bundle stays.
    rm -rf "$INSTALLED_APP"
    if mv "$BACKUP" "$INSTALLED_APP"; then
        osascript -e 'display alert "Update failed" message "The downloaded update failed code-signature verification. The previous version has been restored."'
    else
        osascript -e 'on run argv' \
            -e 'display alert "Update failed" message ("Code-signature verification failed and the restore also failed. Your previous version is at: " & item 1 of argv)' \
            -e 'end run' -- "$BACKUP"
    fi
    rm -rf "$TEMP_DIR"
    exit 1
fi
set -e

# Optionally move the backup to the Trash (recoverable). If trash is not
# available, remove it. Either way, clean up the temp dir.
if command -v trash >/dev/null 2>&1; then
    trash "$BACKUP" 2>/dev/null || rm -rf "$BACKUP"
else
    rm -rf "$BACKUP"
fi
rm -rf "$TEMP_DIR"

# Clear quarantine on the new bundle -- GitHub downloads are quarantined by
# macOS, and the user should not see a Gatekeeper dialog for an app they
# already trusted enough to auto-update. Runs AFTER codesign --verify so the
# strip only happens on a bundle we have positively verified (Item 2).
xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true

# Relaunch. Wrap in an error handler -- NSApp.terminate already ran, so a
# failed open leaves the user with no running app and no error message.
if ! open "$INSTALLED_APP"; then
    osascript -e 'display alert "Relaunch failed" message "The update was installed but Goblin Portal could not be relaunched. Open it from /Applications."' || true
    exit 1
fi
