#!/usr/bin/env python3
"""Generate the Goblin Portal app icon.

Design: acid-green >_ on dark blue-purple with layered bloom (see
icon_goblin_palette.py).  Legacy umber variants preserved.  Sized for 16x16
worst case; squircle 824/1024, mark stroke >=112px at 1024.

Usage:
  python3 make-icon.py                        # build/icon/icon_1024.png
  python3 make-icon.py --variant caret        # pick a treatment
  python3 make-icon.py --all                  # render every variant
  python3 make-icon.py --icns                 # + GoblinPortal.icns via iconutil
"""
from __future__ import annotations

import argparse
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

from icon_path_mark import (
    PATH_BLOOM_COOL, PATH_BLOOM_WARM, PATH_DEFAULT_PRESET, PATH_PRESETS,
    PATH_RAMP, draw_path_mark,
)
import icon_goblin_palette as goblin

# ---------------------------------------------------------------- parameters
S = 1024
SS = 4                    # supersample factor
TILE = 824                # squircle edge on the 1024 grid (Apple macOS metric)
SQUIRCLE_N = 5.4          # superellipse exponent; ~5.4 matches Apple's corner

VARIANT_DEFAULT = "goblin"

# The icon is a small window of the app: these are the app's OWN colours.

# -- Goblin Portal identity (default) — see icon_goblin_palette.py ------------
# -- Umber identity (legacy, still reachable via --variant prompt) -------------
# Background is the afk-dark theme background and the mark's mid stop is the
# real cursor colour — both from Sources/GoblinPortal/Config.swift.
BG_TOP = (0x15, 0x1B, 0x24)
BG_BOTTOM = (0x0D, 0x11, 0x17)      # Config.swift afkDark.background

# the ember ramp — this is where "umber" actually lives
EMBER = [(0.0, (0xFF, 0xCB, 0xA4)), (0.46, (0xE6, 0x7E, 0x4C)), (1.0, (0xAE, 0x44, 0x1C))]
#                                    ^ Config.swift afkDark.cursor (#E67E4C)

# terrain ramp — teal water → amber highlands, derived from the Umber identity
# map imagery.  The diagonal in ember_over() flows the teal onto the > (left)
# and the amber onto the _ (right), matching the natural read direction.
TERRAIN = [(0.0, (0x24, 0x95, 0xBC)), (1.0, (0xF9, 0xC8, 0x5A))]
# inverse colourway paints the tile with the ember and knocks the mark out dark
INK = (0x16, 0x10, 0x0C)

STROKE = 116              # mark stroke @1024 -> ~1.8px @16
BLOOM = 0.62              # ember bloom strength behind the mark
OPTICAL_LIFT = 0.010

# ------------------------------------------------------------------ geometry
def squircle_mask(size: int, n: float) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    px = m.load()
    r = size / 2.0
    for y in range(size):
        ny = abs((y + 0.5 - r) / r) ** n
        if ny > 1.0:
            continue
        half = (1.0 - ny) ** (1.0 / n) * r
        for x in range(max(0, int(r - half)), min(size, int(math.ceil(r + half)))):
            px[x, y] = 255
    return m


def gradient(size: int, stops: list) -> Image.Image:
    """Vertical multi-stop gradient."""
    g = Image.new("RGB", (1, size))
    d = ImageDraw.Draw(g)
    for y in range(size):
        t = y / max(1, size - 1)
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                k = (t - p0) / max(1e-6, p1 - p0)
                d.point((0, y), fill=tuple(round(c0[j] + (c1[j] - c0[j]) * k) for j in range(3)))
                break
        else:
            d.point((0, y), fill=stops[-1][1])
    return g.resize((size, size), Image.BILINEAR)


def diagonal_gradient(w: int, h: int, stops: list) -> Image.Image:
    """45-degree multi-stop ramp sized to a specific box."""
    g = Image.new("RGB", (w, h))
    px = g.load()
    for y in range(h):
        for x in range(w):
            t = (x / max(1, w - 1) * 0.42) + (y / max(1, h - 1) * 0.58)
            for i in range(len(stops) - 1):
                p0, c0 = stops[i]
                p1, c1 = stops[i + 1]
                if p0 <= t <= p1:
                    k = (t - p0) / max(1e-6, p1 - p0)
                    px[x, y] = tuple(round(c0[j] + (c1[j] - c0[j]) * k) for j in range(3))
                    break
            else:
                px[x, y] = stops[-1][1]
    return g


def ember_over(tile: int, glyph: Image.Image, stops: list) -> Image.Image:
    """Ember ramp fitted to the glyph's ink bounds, not the tile."""
    bb = glyph.getbbox()
    layer = Image.new("RGB", (tile, tile), stops[-1][1])
    if bb:
        layer.paste(diagonal_gradient(bb[2] - bb[0], bb[3] - bb[1], stops), (bb[0], bb[1]))
    return layer.convert("RGBA")


def _unit(vx: float, vy: float) -> tuple:
    m = math.hypot(vx, vy) or 1.0
    return vx / m, vy / m


def mitred_chevron(d: ImageDraw.ImageDraw, p0, p1, p2, t: float, fill) -> None:
    """A chevron drawn as ONE filled polygon with a true mitre at the apex.

    Round caps read soft and generic (and made the first attempt look like a
    play button); flat ends with a mitred vertex read precise and technical.
    """
    (x0, y0), (x1, y1), (x2, y2) = p0, p1, p2
    dax, day = _unit(x1 - x0, y1 - y0)
    dbx, dby = _unit(x2 - x1, y2 - y1)
    nax, nay = -day, dax          # left normal of segment A
    nbx, nby = -dby, dbx          # left normal of segment B
    mx, my = _unit(nax + nbx, nay + nby)
    denom = max(0.35, mx * nax + my * nay)   # clamp: avoid a spike at sharp angles
    ml = (t / 2) / denom
    h = t / 2
    outer = [(x0 + nax * h, y0 + nay * h), (x1 + mx * ml, y1 + my * ml), (x2 + nbx * h, y2 + nby * h)]
    inner = [(x2 - nbx * h, y2 - nby * h), (x1 - mx * ml, y1 - my * ml), (x0 - nax * h, y0 - nay * h)]
    d.polygon(outer + inner, fill=fill)


# ---------------------------------------------------------------------- mark
def mark_mask(tile: int, variant: str, scale: int) -> Image.Image:
    """White-on-black mask of the glyph, centred on its measured ink bounds."""
    m = Image.new("L", (tile, tile), 0)
    d = ImageDraw.Draw(m)
    st = STROKE * scale
    cy = tile // 2

    if variant in ("caret", "inverse_caret"):
        w, h = int(268 * scale), int(430 * scale)
        x0 = (tile - w) // 2
        mitred_chevron(d, (x0, cy - h // 2), (x0 + w, cy), (x0, cy + h // 2), st, 255)

    elif variant == "block":
        w, h = int(300 * scale), int(430 * scale)
        d.rounded_rectangle([(tile - w) // 2, cy - h // 2, (tile + w) // 2, cy + h // 2],
                            radius=int(46 * scale), fill=255)

    elif variant in ("cursorline", "inverse_cursorline"):
        # caret + a text-cursor block sitting ON the baseline (not centred) —
        # a centred full-height bar reads as "skip to end", a baseline block reads
        # as a terminal cursor.
        cw, ch = int(210 * scale), int(330 * scale)
        blw, blh = int(150 * scale), int(190 * scale)
        gap = int(104 * scale)
        total = cw + gap + blw
        x0 = (tile - total) // 2
        mitred_chevron(d, (x0, cy - ch // 2), (x0 + cw, cy), (x0, cy + ch // 2), st, 255)
        bx, base = x0 + cw + gap, cy + ch // 2
        d.rounded_rectangle([bx, base - blh, bx + blw, base],
                            radius=int(26 * scale), fill=255)

    else:  # "prompt" / "inverse_prompt" -> the unambiguous  >_
        cw, ch = int(206 * scale), int(330 * scale)
        bw = int(224 * scale)
        gap = int(84 * scale)
        total = cw + gap + bw
        x0 = (tile - total) // 2
        mitred_chevron(d, (x0, cy - ch // 2), (x0 + cw, cy), (x0, cy + ch // 2), st, 255)
        bx, base = x0 + cw + gap, cy + ch // 2
        d.rounded_rectangle([bx, base - st, bx + bw, base],
                            radius=int(st * 0.34), fill=255)

    bbox = m.getbbox()
    if bbox:
        ink = m.crop(bbox)
        out = Image.new("L", (tile, tile), 0)
        out.paste(ink, ((tile - ink.width) // 2, (tile - ink.height) // 2 - int(tile * OPTICAL_LIFT)))
        m = out
    return m


# --------------------------------------------------------------------- build
def build(scale: int = SS, variant: str = VARIANT_DEFAULT) -> Image.Image:
    n, tile = S * scale, TILE * scale
    off = (n - tile) // 2
    inverse = variant.startswith("inverse")
    is_path = variant == "path" or variant.startswith("path_")

    shape = squircle_mask(tile, SQUIRCLE_N)

    is_goblin = variant == "goblin"

    if is_goblin:
        glyph = mark_mask(tile, "prompt", scale)
        body = gradient(tile, [(0.0, goblin.BG_TOP), (1.0, goblin.BG_BOTTOM)]).convert("RGBA")

        # layered bloom: wide magenta halo first (behind), tight green glow on top
        outer = glyph.filter(ImageFilter.GaussianBlur(tile * goblin.OUTER_RADIUS)).point(
            lambda v: int(v * goblin.OUTER_STRENGTH)
        )
        body = Image.composite(
            Image.new("RGBA", (tile, tile), goblin.OUTER_BLOOM + (255,)), body, outer
        )
        bloom = glyph.filter(ImageFilter.GaussianBlur(tile * goblin.BLOOM_RADIUS)).point(
            lambda v: int(v * BLOOM)
        )
        body = Image.composite(
            Image.new("RGBA", (tile, tile), goblin.BLOOM_TINT + (255,)), body, bloom
        )
        body = Image.composite(ember_over(tile, glyph, goblin.RAMP), body, glyph)

    elif is_path:
        preset = variant.split("_")[1] if "_" in variant else PATH_DEFAULT_PRESET
        mark_rgba, glyph = draw_path_mark(tile, scale, STROKE, OPTICAL_LIFT, preset)
        body = gradient(tile, [(0.0, BG_TOP), (1.0, BG_BOTTOM)]).convert("RGBA")

        # dual-tinted bloom: cool on the left, warm on the right
        bloom_mask = glyph.filter(ImageFilter.GaussianBlur(tile * 0.050)).point(
            lambda v: int(v * BLOOM)
        )
        # split the bloom at the midpoint for a cool→warm glow
        cool_layer = Image.new("RGBA", (tile, tile), PATH_BLOOM_COOL + (255,))
        warm_layer = Image.new("RGBA", (tile, tile), PATH_BLOOM_WARM + (255,))
        # gradient mask: 0 on the left (cool shows) → 255 on the right (warm shows)
        lr = Image.new("L", (tile, tile), 0)
        for x in range(tile):
            col = int(255 * x / max(1, tile - 1))
            ImageDraw.Draw(lr).line([(x, 0), (x, tile - 1)], fill=col)
        bloom_tint = Image.composite(warm_layer, cool_layer, lr)
        body = Image.composite(bloom_tint, body, bloom_mask)
        body.alpha_composite(mark_rgba)
    elif inverse:
        glyph = mark_mask(tile, variant, scale)
        body = ember_over(tile, squircle_mask(tile, SQUIRCLE_N), EMBER)
        # knock the mark out of the ember slab
        ink = Image.new("RGBA", (tile, tile), INK + (255,))
        body = Image.composite(ink, body, glyph)
    else:
        glyph = mark_mask(tile, variant, scale)
        body = gradient(tile, [(0.0, BG_TOP), (1.0, BG_BOTTOM)]).convert("RGBA")
        is_terrain = "prompt" in variant
        ramp = TERRAIN if is_terrain else EMBER

        # bloom: the mark lights the surface around it
        bloom = glyph.filter(ImageFilter.GaussianBlur(tile * 0.045)).point(
            lambda v: int(v * BLOOM)
        )
        bloom_tint = (0xC8, 0x96, 0x3C) if is_terrain else (0xFF, 0x8A, 0x2B)
        body = Image.composite(
            Image.new("RGBA", (tile, tile), bloom_tint + (255,)), body, bloom
        )
        body = Image.composite(ember_over(tile, glyph, ramp), body, glyph)

    # a single hairline of light along the top edge — depth without gloss
    rim = Image.new("L", (tile, tile), 0)
    ImageDraw.Draw(rim).ellipse(
        [int(-0.30 * tile), int(-0.055 * tile), int(1.30 * tile), int(0.030 * tile)], fill=54
    )
    rim = rim.filter(ImageFilter.GaussianBlur(tile * 0.006))
    # cool rim for goblin (blue-purple bg), warm rim for umber variants
    rim_tint = goblin.RIM_TINT if is_goblin else (255, 226, 190, 255)
    body = Image.composite(Image.new("RGBA", (tile, tile), rim_tint), body, rim)

    body.putalpha(shape)

    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    sh = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    sh.paste((0, 0, 0, 64), (off, off + int(10 * scale)), shape)
    canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(8 * scale)))
    canvas.alpha_composite(body, (off, off))
    return canvas.resize((S, S), Image.LANCZOS)


PATH_VARIANT_NAMES = tuple(f"path_{k}" for k in PATH_PRESETS)
VARIANTS = ("goblin", "path",) + PATH_VARIANT_NAMES + (
    "prompt", "cursorline", "caret", "inverse_prompt", "inverse_cursorline")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default=VARIANT_DEFAULT, choices=VARIANTS)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--explore", action="store_true",
                    help="Render all path presets A-F for comparison")
    ap.add_argument("--icns", action="store_true")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    outdir = Path(a.out) if a.out else root / "build" / "icon"
    outdir.mkdir(parents=True, exist_ok=True)

    if a.explore:
        for k in PATH_PRESETS:
            v = f"path_{k}"
            build(variant=v).save(outdir / f"variant_{v}.png")
            print(f"wrote {outdir / f'variant_{v}.png'}")
        return 0

    if a.all:
        for v in VARIANTS:
            build(variant=v).save(outdir / f"variant_{v}.png")
            print(f"wrote {outdir / f'variant_{v}.png'}")
        return 0

    img = build(variant=a.variant)
    img.save(outdir / "icon_1024.png")
    print(f"wrote {outdir / 'icon_1024.png'}  (variant={a.variant})")

    if a.icns:
        iconset = outdir / "GoblinPortal.iconset"
        iconset.mkdir(exist_ok=True)
        for sz in (16, 32, 128, 256, 512):
            img.resize((sz, sz), Image.LANCZOS).save(iconset / f"icon_{sz}x{sz}.png")
            img.resize((sz * 2, sz * 2), Image.LANCZOS).save(iconset / f"icon_{sz}x{sz}@2x.png")
        icns = outdir / "GoblinPortal.icns"
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
        print(f"wrote {icns}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
