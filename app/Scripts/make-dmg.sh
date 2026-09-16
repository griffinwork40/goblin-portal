#!/bin/bash
#
# Create a distribution .dmg from an already-built GoblinPortal.app.
#
# Produces a compressed, read-only disk image with:
#   - GoblinPortal.app on the left
#   - An Applications symlink on the right
#   - A background image with a drag-here arrow and "Drag to Applications" text
#   - Window sized and positioned so the two icons sit centered
#
# The background image is generated at build time by generate-dmg-background.py
# so the repo carries no binary asset for it. The image is warm umber-brown
# (#52443A) with an anti-aliased arrow and San Francisco / Helvetica Neue text.
#
# Usage:
#   ./Scripts/make-dmg.sh [path/to/GoblinPortal.app] [output.dmg]
#
# Defaults:
#   app:    build/GoblinPortal.app
#   output: build/GoblinPortal-vX.Y.Z.dmg  (version read from the app's Info.plist)
#
# Requires: hdiutil, python3 (ships with macOS 14+), Pillow for best-quality
#           output (falls back to pure-stdlib PNG if Pillow is absent)
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/GoblinPortal.app}"
if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found — run make-app-bundle.sh first" >&2
  exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
OUTPUT="${2:-build/GoblinPortal-v${VERSION}.dmg}"
VOLUME_NAME="Goblin Portal"

# Window geometry. The Finder window that opens when the user mounts the DMG is
# positioned and sized by the .DS_Store baked into the image. These numbers place
# two 128px icons centered in a 640×400 window with a comfortable gap and the
# arrow between them.
WIN_W=640
WIN_H=400
ICON_SIZE=128
APP_X=160     # GoblinPortal.app icon center
APP_Y=190
APPS_X=480    # Applications alias icon center
APPS_Y=190

echo "==> creating DMG background"

# Background is generated at 1× point size so Finder scales it correctly on
# Retina displays. A 2× image is treated as already at device resolution and gets
# CROPPED to the window bounds (Finder does not honour @2x naming for DMG
# backgrounds — the image is read verbatim). Using 1× avoids the crop, at the
# cost of being upscaled on Retina; Pillow's anti-aliasing minimises the blur.
BG_DIR="$(mktemp -d)"
BG="$BG_DIR/background.png"
python3 "$(dirname "$0")/generate-dmg-background.py" "$BG" "$WIN_W" "$WIN_H"

echo "==> assembling DMG contents"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/GoblinPortal.app"
ln -s /Applications "$STAGING/Applications"

# Hidden directory for the background image. The dot-prefix hides it in Finder's
# default view, but chflags hidden (applied after mount, below) is the reliable
# mechanism on HFS+/APFS.
mkdir -p "$STAGING/.background"
cp "$BG" "$STAGING/.background/background.png"

# Remove any existing output so hdiutil doesn't fail on overwrite.
rm -f "$OUTPUT"

echo "==> creating writable DMG"

# Create a read-write DMG large enough for the app + headroom.
APP_SIZE_MB="$(du -sm "$APP" | cut -f1)"
DMG_SIZE_MB=$(( APP_SIZE_MB + 20 ))
hdiutil create \
  -size "${DMG_SIZE_MB}m" \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -srcfolder "$STAGING" \
  -format UDRW \
  -ov \
  "$OUTPUT.rw.dmg"

echo "==> configuring Finder appearance"

MOUNT_DIR="$(hdiutil attach "$OUTPUT.rw.dmg" -readwrite -noverify -noautoopen | \
  grep '/Volumes/' | sed 's|.*\(/Volumes/.*\)|\1|' | head -1)"

# Hide internal folders that should never appear in the Finder window.
# chflags hidden is the authoritative mechanism (SetFile -a V is deprecated).
# .background must be hidden AFTER mounting since hdiutil resets flags on copy.
chflags hidden "$MOUNT_DIR/.background" 2>/dev/null || true
chflags hidden "$MOUNT_DIR/.DS_Store"   2>/dev/null || true

# .fseventsd is created by the filesystem and should not be visible; delete it.
rm -rf "$MOUNT_DIR/.fseventsd" 2>/dev/null || true

# Hide any other dot-prefixed entries that Finder may surface.
for dotentry in "$MOUNT_DIR"/.Trashes "$MOUNT_DIR"/.TemporaryItems; do
  [[ -e "$dotentry" ]] && chflags hidden "$dotentry" 2>/dev/null || true
done

# Give the Finder a moment to index the volume.
sleep 2

# AppleScript needs Finder + a window server. On CI runners this is usually
# available (GitHub macos-* runners run a GUI session). If it fails the DMG
# still works — just with default icon positions instead of the designed layout.
if osascript <<APPLESCRIPT 2>/dev/null
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, $((100 + WIN_W)), $((100 + WIN_H))}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON_SIZE
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "GoblinPortal.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "    Finder layout configured"
else
  echo "==> warning: AppleScript failed (no window server?) — DMG will use default layout" >&2
fi

# Set the volume icon if the app has one.
if [[ -f "$APP/Contents/Resources/GoblinPortal.icns" ]]; then
  cp "$APP/Contents/Resources/GoblinPortal.icns" "$MOUNT_DIR/.VolumeIcon.icns"
  SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
  SetFile -a C    "$MOUNT_DIR"                   2>/dev/null || true
fi

# Make everything in the volume read-only (standard for DMGs).
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true

sync
hdiutil detach "$MOUNT_DIR" -quiet

echo "==> compressing to final DMG"

hdiutil convert "$OUTPUT.rw.dmg" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT"

rm -f "$OUTPUT.rw.dmg"

# Clean up temp dirs.
rm -rf "$BG_DIR" "$STAGING"

DMG_SIZE="$(du -h "$OUTPUT" | cut -f1)"
echo "==> $OUTPUT ($DMG_SIZE)"
echo "    hdiutil verify \"$OUTPUT\"   # check integrity"
echo "    open \"$OUTPUT\"             # test the user experience"
