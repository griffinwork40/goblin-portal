"""Bold, asset-free doorways for the Goblin Portal identity.

Coordinates live on the 824px tile. Negative space is deliberate: the opening
and broken threshold remain readable when the whole icon is only 16px wide.
"""
from __future__ import annotations

from PIL import Image, ImageDraw, ImageFilter

PORTAL_VARIANTS = ("portal", "portal_arcane", "portal_rift")
PORTAL_RAMPS = {
    "portal": [(0.0, (211, 255, 156)), (0.48, (93, 235, 168)),
               (1.0, (44, 167, 173))],
    "portal_arcane": [(0.0, (222, 202, 255)), (0.5, (164, 116, 246)),
                      (1.0, (92, 106, 232))],
    "portal_rift": [(0.0, (170, 255, 177)), (0.45, (72, 221, 194)),
                    (1.0, (170, 108, 242))],
}


def portal_mask(tile: int, variant: str) -> Image.Image:
    """An arch, faceted gate, or leaning ring; no ornamental micro-details."""
    mask = Image.new("L", (tile, tile))
    d = ImageDraw.Draw(mask)
    s = tile / 824

    def box(values):
        return tuple(round(v * s) for v in values)

    def polygon(points, fill):
        d.polygon([(round(x * s), round(y * s)) for x, y in points], fill=fill)

    if variant == "portal":
        # Round crown, straight jambs, offset threshold: an inviting doorway
        # with one mischievously shortened leg rather than a corporate monogram.
        d.ellipse(box((122, 108, 702, 688)), fill=255)
        d.rectangle(box((122, 398, 702, 680)), fill=255)
        d.ellipse(box((234, 220, 590, 576)), fill=0)
        d.rectangle(box((234, 398, 590, 728)), fill=0)
        d.rectangle(box((590, 552, 714, 728)), fill=0)
        d.rectangle(box((368, 652, 702, 756)), fill=255)
    elif variant == "portal_arcane":
        # A crystalline lintel; the peak is intentionally off-axis.
        polygon([(166, 694), (166, 288), (456, 108), (658, 288),
                 (658, 570), (548, 570), (548, 338), (442, 244),
                 (276, 350), (276, 694)], 255)
        d.rectangle(box((358, 634, 658, 734)), fill=255)
    else:
        # Dimensional ring leaning into motion, with a clean exit in its rim.
        d.ellipse(box((180, 112, 644, 710)), fill=255)
        d.ellipse(box((292, 228, 532, 594)), fill=0)
        polygon([(480, 508), (680, 598), (680, 734), (462, 596)], 0)
        mask = mask.transform(
            (tile, tile), Image.Transform.AFFINE,
            (1, -0.16, tile * 0.08, 0, 1, 0),
            resample=Image.Resampling.BICUBIC,
        )
    return mask


def draw_portal(tile: int, variant: str, gradient, ember_over) -> Image.Image:
    """Use the shared gradient helpers, keeping bloom below the solid mark."""
    glyph = portal_mask(tile, variant)
    ramp = PORTAL_RAMPS[variant]
    body = gradient(tile, [(0.0, (24, 31, 39)), (1.0, (12, 16, 24))]).convert("RGBA")
    color = ember_over(tile, glyph, ramp)
    halo = glyph.filter(ImageFilter.GaussianBlur(tile * 0.065)).point(
        lambda v: round(v * 0.30)
    )
    body = Image.composite(color, body, halo)
    return Image.composite(color, body, glyph)
