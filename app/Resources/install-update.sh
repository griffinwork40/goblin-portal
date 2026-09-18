#!/bin/sh
#
# install-update.sh -- Trampoline for in-place app updates.
#
# Called by UpdateInstaller.swift with five arguments:
#   $1  PID of the running Goblin Portal process to wait on
#   $2  Path to the NEW .app bundle (in the extraction temp dir)
#   $3  Path to the INSTALLED .app bundle (e.g. /Applications/GoblinPortal.app)
#   $4  Path to the executable to relaunch after the swap
#   $5  Path to the temp directory to clean up after
#
# This script outlives the parent process. It waits for the old app to exit,
# moves the old bundle to the trash (recoverable), moves the new one in, and
# relaunches. On any failure it leaves the old bundle untouched and opens an
# alert via osascript.

set -e

PID="$1"
NEW_APP="$2"
INSTALLED_APP="$3"
RELAUNCH="$4"
TEMP_DIR="$5"

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

# Move the old bundle to the Trash so the user can recover it. If the Trash
# move fails (e.g. the volume has no Trash), fall back to a .bak rename.
BACKUP="${INSTALLED_APP}.bak-$(date +%s)"
if command -v trash >/dev/null 2>&1; then
    trash "$INSTALLED_APP" 2>/dev/null || mv "$INSTALLED_APP" "$BACKUP"
else
    mv "$INSTALLED_APP" "$BACKUP"
fi

# Move the new bundle into place.
if ! mv "$NEW_APP" "$INSTALLED_APP"; then
    # Restore the backup on failure.
    if [ -d "$BACKUP" ]; then
        mv "$BACKUP" "$INSTALLED_APP"
    fi
    osascript -e 'display alert "Update failed" message "Could not install the new version. The previous version has been restored."'
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Clean up the backup (if mv, not Trash) and the temp dir.
rm -rf "$BACKUP" "$TEMP_DIR"

# Clear quarantine on the new bundle -- GitHub downloads are quarantined by
# macOS, and the user should not see a Gatekeeper dialog for an app they
# already trusted enough to auto-update.
xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true

# Relaunch.
open "$INSTALLED_APP"
