#!/bin/sh
#
# install-update.sh -- Trampoline for in-place app updates.
#
# Called by UpdateInstaller.swift with four arguments:
#   $1  PID of the running Goblin Portal process to wait on
#   $2  Path to the NEW .app bundle (in the extraction temp dir)
#   $3  Path to the INSTALLED .app bundle (e.g. /Applications/GoblinPortal.app)
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

# Wait for the running app to exit. Poll every 200ms for up to 30 seconds.
# If it does not exit in time, abort -- never swap under a running process.
waited=0
while kill -0 "$PID" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -ge 150 ]; then
        osascript -e 'display alert "Update failed" message "Goblin Portal did not quit in time. Please quit the app and try again."'
        rm -rf "$TEMP_DIR"
        exit 1
    fi
done

# Always move the old bundle aside first so we have a guaranteed rollback path.
# If this mv fails (e.g. permission error) set -e aborts before we touch anything.
BACKUP="${INSTALLED_APP}.bak-$(date +%s)"
mv "$INSTALLED_APP" "$BACKUP"

# Move the new bundle into place.
if ! mv "$NEW_APP" "$INSTALLED_APP"; then
    # Restore the backup on failure. Disable set -e so a restore failure does
    # not silently exit without showing the alert.
    set +e
    mv "$BACKUP" "$INSTALLED_APP"
    osascript -e 'display alert "Update failed" message "Could not install the new version. The previous version has been restored."'
    rm -rf "$TEMP_DIR"
    exit 1
fi

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
# already trusted enough to auto-update.
xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true

# Relaunch.
open "$INSTALLED_APP"
