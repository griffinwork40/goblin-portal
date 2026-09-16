#!/usr/bin/env python3
"""
Generate the DMG installer background image.

Produces a PNG at the given WxH with:
  - Warm umber background (#52443A)
  - Anti-aliased arrow between app icon and Applications alias positions
  - "Drag to Applications" rendered in San Francisco / Helvetica Neue

Usage:
  python3 generate-dmg-background.py <output.png> <width> <height>

Called by make-dmg.sh at build time — no committed binary assets.
Requires: Python 3, Pillow (PIL). Falls back to a pure-stdlib PNG encoder
if Pillow is unavailable (loses anti-aliasing and real typography).
"""

import os
import struct
import sys
import zlib

path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

# Palette
BG      = (0x52, 0x44, 0x3A)   # warm umber — ~30% luminance, legible labels
ACCENT  = (0xC8, 0xB8, 0xA4)   # warm cream, high contrast on the background
GREEN   = (0x6F, 0xFF, 0x56)   # acid-green portal bloom — used for the arrow tip

# Icon layout (must match make-dmg.sh APP_X / APPS_X / ICON_Y values).
APP_X   = 160
APPS_X  = 480
ICON_Y  = 190   # vertical center of both icons

# Arrow geometry
SHAFT_X0    = APP_X  + 72   # just right of the app icon (128px wide → edge at 224, gap to 232)
SHAFT_X1    = APPS_X - 80   # just left of the arrowhead → Applications icon edge at 416, gap to 400
SHAFT_HALF  = 2              # half-height of the thin shaft in pixels
HEAD_X0     = SHAFT_X1
HEAD_X1     = APPS_X - 62   # arrowhead tip; leaves gap before the Applications icon
HEAD_HALF   = 13             # half-height of arrowhead at its widest point

# Text layout
TEXT        = "Drag to Applications"
TEXT_Y_FRAC = 0.79           # vertical position as fraction of image height


def _try_pillow() -> bool:
    """Attempt to generate using Pillow for anti-aliased output. Returns True on success."""
    try:
        from PIL import Image, ImageDraw, ImageFont  # type: ignore
    except ImportError:
        return False

    img  = Image.new("RGBA", (w, h), (*BG, 255))
    draw = ImageDraw.Draw(img, "RGBA")

    # --- Arrow shaft (thin rectangle) ---
    draw.rectangle(
        [SHAFT_X0, ICON_Y - SHAFT_HALF, SHAFT_X1, ICON_Y + SHAFT_HALF],
        fill=(*ACCENT, 210),
    )

    # --- Arrowhead (filled triangle, Pillow anti-aliases polygon edges) ---
    head_pts = [
        (HEAD_X0, ICON_Y - HEAD_HALF),
        (HEAD_X1, ICON_Y),
        (HEAD_X0, ICON_Y + HEAD_HALF),
    ]
    draw.polygon(head_pts, fill=(*ACCENT, 210))

    # Acid-green accent: a small diamond at the arrowhead tip echoing the portal bloom.
    tip_r = 4
    tip   = HEAD_X1
    diamond = [
        (tip,         ICON_Y - tip_r),
        (tip + tip_r, ICON_Y),
        (tip,         ICON_Y + tip_r),
        (tip - tip_r, ICON_Y),
    ]
    draw.polygon(diamond, fill=(*GREEN, 190))

    # --- Typography: San Francisco > Helvetica Neue > Helvetica > default ---
    font = None
    for fp in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        if os.path.exists(fp):
            try:
                font = ImageFont.truetype(fp, 18)
                break
            except Exception:
                pass

    if font is None:
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), TEXT, font=font)
    tw   = bbox[2] - bbox[0]
    th   = bbox[3] - bbox[1]
    tx   = (w - tw) // 2
    ty   = int(h * TEXT_Y_FRAC) - th // 2
    draw.text((tx, ty), TEXT, fill=(*ACCENT, 230), font=font)

    img.save(path)
    print(f"  background (pillow): {w}x{h} -> {path}")
    return True


def _fallback_stdlib() -> None:
    """Pure-stdlib PNG encoder — no anti-aliasing, enlarged bitmap font for text."""
    # 5×9 bitmap glyphs (fallback when Pillow is unavailable)
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
    SCALE = 3   # 3× scale so glyphs are at least legible (vs. original 2×)

    text_pixels: set = set()
    glyph_w, glyph_h, gap = 5, 9, 1
    text_w_px = len(TEXT) * (glyph_w + gap) * SCALE
    text_x0   = (w - text_w_px) // 2
    text_y0   = int(h * TEXT_Y_FRAC)
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

    rows = []
    for y in range(h):
        row = bytearray(b'\x00')  # PNG filter byte: None
        for x in range(w):
            r = BG
            # Shaft
            if SHAFT_X0 <= x <= SHAFT_X1 and abs(y - ICON_Y) <= SHAFT_HALF:
                r = ACCENT
            # Arrowhead
            elif HEAD_X0 < x <= HEAD_X1:
                spread = int(HEAD_HALF * (HEAD_X1 - x) / (HEAD_X1 - HEAD_X0))
                if abs(y - ICON_Y) <= spread:
                    r = ACCENT
            # Arrowhead tip: acid-green diamond
            elif HEAD_X1 < x <= HEAD_X1 + 4:
                spread = 4 - (x - HEAD_X1)
                if abs(y - ICON_Y) <= spread:
                    r = GREEN
            # Text
            if (x, y) in text_pixels:
                r = ACCENT
            row.extend((*r, 0xFF))
        rows.append(bytes(row))

    raw = b''.join(rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

    sig  = b'\x89PNG\r\n\x1a\n'
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)  # 8-bit RGBA
    idat = zlib.compress(raw, 9)

    with open(path, 'wb') as f:
        f.write(sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b''))

    print(f"  background (stdlib fallback): {w}x{h} -> {path}")


if not _try_pillow():
    _fallback_stdlib()
