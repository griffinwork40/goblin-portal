"""Goblin Portal icon palette — the acid-green-on-purple identity.

The >_ prompt glyph is rendered with a 4-stop jade gradient, a tight green
inner bloom, and a wider magenta outer halo.  The "portal" lives in the light,
not in a shape — every competitor uses a simple glyph with distinctive colour;
this one occupies the poisonous chartreuse-to-jade lane nobody else touches.

Separated from make-icon.py to keep both files under the 350-LOC ceiling.
"""

# Near-black with a blue-purple tint — the magenta halo sits naturally on it,
# and the tile stays visible against a black Dock.
BG_TOP = (0x0D, 0x0F, 0x1C)
BG_BOTTOM = (0x06, 0x08, 0x14)

# 4-stop jade ramp across the >_ glyph (diagonal, via ember_over)
RAMP = [
    (0.00, (0xA3, 0xFF, 0x57)),       # acid chartreuse highlight
    (0.40, (0x2E, 0xD0, 0x66)),       # bright jade
    (0.75, (0x16, 0x8A, 0x40)),       # deep emerald
    (1.00, (0x05, 0x59, 0x2D)),       # dark forest
]

BLOOM_TINT = (0x39, 0xFF, 0x14)       # acid green inner glow
BLOOM_RADIUS = 0.055                  # inner bloom blur (fraction of tile)

OUTER_BLOOM = (0xC8, 0x2E, 0xF0)     # magenta/purple outer halo
OUTER_STRENGTH = 0.30                 # outer bloom opacity
OUTER_RADIUS = 0.11                   # outer bloom blur (wider = more diffuse)

# cool-tinted rim light for the blue-purple background
RIM_TINT = (190, 200, 240, 255)
