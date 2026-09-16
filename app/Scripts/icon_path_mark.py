"""Path mark renderer for the Goblin Portal app icon.

Owns the "path" variant: three joined cubic Bézier segments with C1
continuity, rendered as overlapping circles for smooth tapered edges.
The colour ramp runs blue/teal (discovery) → amber (embodiment) with a
compressed grey-brown transition at the inflection.

Extracted from make-icon.py to keep both files under the 350-LOC ceiling.
"""
from __future__ import annotations

import math

from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------- path mark colours
# Blue/cyan (discovery) → amber (embodiment).  The transition is COMPRESSED
# into a narrow band at the inflection point (t≈0.60-0.70) — no muddy grey-
# brown middle ground.  Blue holds through most of the descent; amber emerges
# decisively after the compression.
PATH_RAMP = [
    (0.00, (0x32, 0xA0, 0xC6)),   # steel-teal: the descent begins
    (0.40, (0x2C, 0x78, 0xA2)),   # deeper teal: hold blue through descent
    (0.60, (0x3E, 0x56, 0x72)),   # blue-grey: compression approach — cool, not brown
    (0.70, (0x9A, 0x64, 0x3C)),   # direct amber emergence — compressed transition
    (0.82, (0xE6, 0x7E, 0x4C)),   # Config.swift cursor — full ember
    (1.00, (0xFF, 0xCB, 0xA4)),   # bright peach: embodiment
]
PATH_BLOOM_COOL = (0x30, 0x9E, 0xC4)
PATH_BLOOM_WARM = (0xFF, 0x8A, 0x2B)


# ---------------------------------------------------------------- Bézier math
def _bz(a, b, c, d, t):
    u = 1.0 - t
    return u*u*u*a + 3*u*u*t*b + 3*u*t*t*c + t*t*t*d


def _lerp_color(stops, t):
    t = max(0.0, min(1.0, t))
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        if p0 <= t <= p1:
            k = (t - p0) / max(1e-6, p1 - p0)
            return tuple(round(c0[j] + (c1[j] - c0[j]) * k) for j in range(3))
    return stops[-1][1]


def _smooth(stops, t):
    """Piecewise smoothstep — smooth transitions, no overshoot."""
    t = max(0.0, min(1.0, t))
    for i in range(len(stops) - 1):
        t0, v0 = stops[i]
        t1, v1 = stops[i + 1]
        if t0 <= t <= t1:
            k = (t - t0) / max(1e-9, t1 - t0)
            k = k * k * (3 - 2 * k)
            return v0 + (v1 - v0) * k
    return stops[-1][1]


def _make_segs(entry, s1c1, s1c2, j1, j1_arm, s2c2, j2, j2_arm, s3c2, end):
    """Build 3 cubic Béziers with guaranteed C1 at the two joins.

    j1_arm / j2_arm control the curvature DISCONTINUITY: shorter arm relative
    to the approach arm = tighter curvature on the exit side of the join.
    """
    s1 = [entry, s1c1, s1c2, j1]
    dx, dy = j1[0] - s1c2[0], j1[1] - s1c2[1]
    m = math.hypot(dx, dy) or 1
    s2 = [j1, (j1[0] + j1_arm * dx / m, j1[1] + j1_arm * dy / m), s2c2, j2]
    dx, dy = j2[0] - s2c2[0], j2[1] - s2c2[1]
    m = math.hypot(dx, dy) or 1
    s3 = [j2, (j2[0] + j2_arm * dx / m, j2[1] + j2_arm * dy / m), s3c2, end]
    return [s1, s2, s3]


# -- presets ---------------------------------------------------------------
# Three variants exploring the organic/tension dial.  All share the same
# layout points; only the join arm lengths and width envelope differ.
#
# t is split evenly: seg 1 = [0, 0.33), seg 2 = [0.33, 0.67), seg 3 = [0.67, 1].
# Join 1 (t≈0.33): descent steepens.  Join 2 (t≈0.67): the compression.

_LAYOUT = dict(
    entry=(-0.33, -0.03), s1c1=(-0.25, -0.02), s1c2=(-0.20, 0.01),
    j1=(-0.14, 0.04), s2c2=(-0.04, 0.10),
    j2=(0.02, 0.105), s3c2=(0.18, -0.02), end=(0.32, -0.08),
)


def _preset_A():
    """'Subtle' — 85/15 organic/tension.  Gentler curvature changes."""
    return dict(
        segments=_make_segs(**_LAYOUT, j1_arm=0.065, j2_arm=0.045),
        widths=[(0, .10), (.06, .66), (.25, .72), (.50, .60),
                (.65, .30), (.74, .50), (.86, .76), (.95, .68), (1, .08)])


def _preset_B():
    """'Balance' — 80/20 organic/tension.  The target."""
    return dict(
        segments=_make_segs(**_LAYOUT, j1_arm=0.050, j2_arm=0.030),
        widths=[(0, .10), (.06, .66), (.25, .72), (.50, .58),
                (.65, .26), (.74, .48), (.86, .76), (.95, .68), (1, .08)])


def _preset_C():
    """'Taut' — 75/25 organic/tension.  Tighter curvature breaks."""
    return dict(
        segments=_make_segs(**_LAYOUT, j1_arm=0.038, j2_arm=0.020),
        widths=[(0, .10), (.06, .66), (.25, .72), (.50, .56),
                (.65, .22), (.74, .46), (.86, .76), (.95, .68), (1, .08)])


PATH_PRESETS = dict(A=_preset_A, B=_preset_B, C=_preset_C)
PATH_DEFAULT_PRESET = "B"


def _eval_path(t, segments):
    idx = min(int(t * 3), 2)
    u = t * 3 - idx
    s = segments[idx]
    return (_bz(s[0][0], s[1][0], s[2][0], s[3][0], u),
            _bz(s[0][1], s[1][1], s[2][1], s[3][1], u))


def draw_path_mark(tile, scale, stroke, optical_lift,
                   preset_name=PATH_DEFAULT_PRESET):
    """Circle-based rendering for organic smoothness with tapered endpoints.

    Returns (mark_rgba, mask) — both tile×tile RGBA/L images.
    """
    cfg = PATH_PRESETS[preset_name]()
    segs, wenv = cfg["segments"], cfg["widths"]
    st = stroke * scale
    n = 800
    cx, cy = tile / 2.0, tile / 2.0 - tile * optical_lift

    img = Image.new("RGBA", (tile, tile), (0, 0, 0, 0))
    mask = Image.new("L", (tile, tile), 0)
    d_img, d_mask = ImageDraw.Draw(img), ImageDraw.Draw(mask)
    for i in range(n + 1):
        t = i / n
        px, py = _eval_path(t, segs)
        x, y = cx + px * tile, cy + py * tile
        r = st * _smooth(wenv, t) / 2.0
        if r < 0.5:
            continue
        color = _lerp_color(PATH_RAMP, t)
        box = [x - r, y - r, x + r, y + r]
        d_img.ellipse(box, fill=color + (255,))
        d_mask.ellipse(box, fill=255)
    return img, mask
