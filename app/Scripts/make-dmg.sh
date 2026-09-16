#!/bin/bash
#
# Create a distribution .dmg from an already-built GoblinPortal.app.
#
# Produces a compressed, read-only disk image with:
#   - GoblinPortal.app on the left
#   - An Applications symlink on the right
#   - A background image with a drag-here arrow
#   - Window sized and positioned so the two icons sit centered
#
# The background image is generated at build time by a Python/sips pipeline so
# the repo carries no binary asset for it. The image is warm umber-black (#19120D)
# to match the app's default theme, with a subtle arrow drawn between the two icon
# positions.
#
# Usage:
#   ./Scripts/make-dmg.sh [path/to/GoblinPortal.app] [output.dmg]
#
# Defaults:
#   app:    build/GoblinPortal.app
#   output: build/GoblinPortal-vX.Y.Z.dmg  (version read from the app's Info.plist)
#
# Requires: hdiutil, sips, python3 (ships with macOS 14+)
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

# Generate the background image. It needs to be exactly the window size (Retina:
# 2×) so the Finder scales it correctly. The image is the app's umber-black with
# a subtle arrow guiding the drag.
BG_DIR="$(mktemp -d)"
BG="$BG_DIR/background.png"
# The background image must match the POINT size of the Finder window, not the
# Retina pixel size. Finder scales 1× images to fill the window on Retina
# displays; a 2× image is treated as already at device resolution and gets
# CROPPED to the window bounds — pushing the arrow and text off-screen.
BG_W=$WIN_W
BG_H=$WIN_H

python3 - "$BG" "$BG_W" "$BG_H" <<'PYEOF'
import struct, sys, zlib, math

path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

# Warm brown background — light enough for Finder's black icon labels (light
# mode), dark enough for white labels (dark mode). ~30% luminance.
bg = (0x52, 0x44, 0x3A)
# Arrow and text: warm cream, high contrast against the background.
accent = (0xC8, 0xB8, 0xA4)

# A 5×9 bitmap font for "Drag to Applications". Each glyph is 5 cols × 9 rows,
# stored as 9 ints where bit 4..0 = pixels left to right. The extra 2 rows let
# descenders (g, p) drop below the baseline. Non-descender glyphs pad with 0.
GLYPHS = {
    'D': [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110, 0, 0],
    'r': [0b00000, 0b00000, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000, 0, 0],
    'a': [0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111, 0, 0],
    'g': [0b00000, 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110],
    ' ': [0, 0, 0, 0, 0, 0, 0, 0, 0],
    't': [0b00000, 0b01000, 0b11110, 0b01000, 0b01000, 0b01001, 0b00110, 0, 0],
    'o': [0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110, 0, 0],
    'A': [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001, 0, 0],
    'p': [0b00000, 0b00000, 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0],
    'l': [0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110, 0, 0],
    'i': [0b00100, 0b00000, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110, 0, 0],
    'c': [0b00000, 0b00000, 0b01110, 0b10000, 0b10000, 0b10001, 0b01110, 0, 0],
    'n': [0b00000, 0b00000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001, 0, 0],
    's': [0b00000, 0b00000, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110, 0, 0],
}
TEXT = "Drag to Applications"
SCALE = 2  # text scale at 1× image resolution

# Pre-render text pixels as a set for O(1) lookup.
text_pixels = set()
glyph_w, glyph_h, gap = 5, 9, 1
text_w_px = len(TEXT) * (glyph_w + gap) * SCALE
text_h_px = glyph_h * SCALE
text_x0 = (w - text_w_px) // 2
text_y0 = int(h * 0.78)  # below the icons, above the bottom edge

for ci, ch in enumerate(TEXT):
    glyph = GLYPHS.get(ch, GLYPHS[' '])
    for gy in range(glyph_h):
        for gx in range(glyph_w):
            if glyph[gy] & (1 << (4 - gx)):
                for sy in range(SCALE):
                    for sx in range(SCALE):
                        px = text_x0 + (ci * (glyph_w + gap) + gx) * SCALE + sx
                        py = text_y0 + gy * SCALE + sy
                        text_pixels.add((px, py))

# Arrow geometry (1× point coords matching Finder icon positions).
# Icons are at x=160 and x=480, y=190. Midpoint is x=320.
# Arrow body+head spans 120px, centered at x=320.
cy = 190                  # same y as the icon centers
body_x0, body_x1 = 260, 355
head_x0, head_x1 = 355, 380
bar_half = 3
head_half = 16

# Build raw RGBA rows.
rows = []
for y in range(h):
    row = bytearray(b'\x00')  # filter byte: None
    for x in range(w):
        r = bg
        # Arrow body
        if body_x0 <= x <= body_x1 and abs(y - cy) <= bar_half:
            r = accent
        # Arrow head
        elif head_x0 < x <= head_x1:
            spread = int(head_half * (head_x1 - x) / (head_x1 - head_x0))
            if abs(y - cy) <= spread:
                r = accent
        # Text
        if (x, y) in text_pixels:
            r = accent
        row.extend((*r, 0xFF))
    rows.append(bytes(row))

raw = b''.join(rows)

# Minimal PNG encoder — IHDR + IDAT + IEND, no dependencies.
def chunk(tag, data):
    c = tag + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

sig = b'\x89PNG\r\n\x1a\n'
ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)  # 8-bit RGBA
idat = zlib.compress(raw, 9)

with open(path, 'wb') as f:
    f.write(sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b''))

print(f"  background: {w}x{h} -> {path}")
PYEOF

echo "==> assembling DMG contents"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/GoblinPortal.app"
ln -s /Applications "$STAGING/Applications"

# Hidden directory for the background image. The dot-prefix hides it in Finder.
mkdir -p "$STAGING/.background"
cp "$BG" "$STAGING/.background/background.png"

# Remove any existing output so hdiutil doesn't fail on overwrite.
rm -f "$OUTPUT"

echo "==> creating writable DMG"

# Create a read-write DMG large enough for the app + headroom.
# Size it dynamically: app size + 20MB for filesystem overhead.
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

# Mount the writable image and configure the Finder window via AppleScript.
# This bakes a .DS_Store into the volume that controls window size, background,
# icon size, and icon positions when a user opens the final DMG.
MOUNT_DIR="$(hdiutil attach "$OUTPUT.rw.dmg" -readwrite -noverify -noautoopen | \
  grep '/Volumes/' | sed 's|.*\(/Volumes/.*\)|\1|' | head -1)"

# Give the Finder a moment to index the volume.
sleep 2

# AppleScript needs Finder, which needs a window server. On CI runners this is
# usually available (GitHub macos-* runners run a GUI session) but if it fails —
# say, a future headless runner — the DMG still works, it just opens with default
# icon positions instead of the designed layout. Worth a warning, not a hard fail.
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
  SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
fi

# Make everything in the volume owned by root and read-only (standard for DMGs).
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true

sync
hdiutil detach "$MOUNT_DIR" -quiet

echo "==> compressing to final DMG"

# Convert to a compressed, read-only image. UDZO is universally compatible;
# ULMO (lzma) is smaller but requires macOS 10.15+.
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
