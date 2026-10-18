#!/usr/bin/env python3
"""Draws the Populous app icon and writes Populous.icns next to this script's parent.

The art is original (no Bullfrog data): a Populous-style isometric island of stepped
land in a dark sea, a small stone keep on top, and the game's ankh floating above.
It is drawn at 256 px and scaled up without smoothing so it keeps a pixel look.
Needs Pillow (pip3 install pillow) and macOS iconutil.
"""
import math, os, shutil, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Populous.icns")
S = 256  # pixel-art canvas, scaled x4 to 1024

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Night sky: deep blue at the top shading to a bruised purple at the horizon.
for y in range(S):
    t = y / S
    d.line([(0, y), (S, y)], fill=lerp((10, 14, 46), (58, 26, 74), t) + (255,))
# Stars.
import random
random.seed(1989)
for _ in range(70):
    x, y = random.randrange(S), random.randrange(int(S * 0.55))
    c = random.choice([(200, 210, 255), (255, 255, 255), (170, 180, 230)])
    d.point((x, y), fill=c + (255,))
    if random.random() < 0.25:
        d.point((x + 1, y), fill=c + (255,)); d.point((x, y + 1), fill=c + (255,))

# Sea: a flat horizon just below the middle with rippled blue bands.
HORIZON = 150
for y in range(HORIZON, S):
    t = (y - HORIZON) / (S - HORIZON)
    c = lerp((22, 60, 140), (8, 24, 70), t)
    d.line([(0, y), (S, y)], fill=c + (255,))
for y in range(HORIZON + 2, S, 6):
    for x in range(0, S, 1):
        if (math.sin(x / 7.0 + y) > 0.6):
            d.point((x, y), fill=(70, 120, 200, 255))

# Island: stacked isometric terraces. Each terrace is a diamond top face with two
# darker cliff faces below, as the game draws its block landscape.
CX = 128
TOP_GREEN = (82, 160, 56)
SIDE_L = (42, 86, 34)
SIDE_R = (60, 118, 44)
ROCK_L = (70, 64, 70)
ROCK_R = (98, 92, 100)
def terrace(cy, half_w, half_h, drop, top, left, right):
    # top diamond
    pts = [(CX, cy - half_h), (CX + half_w, cy), (CX, cy + half_h), (CX - half_w, cy)]
    # cliffs
    d.polygon([(CX - half_w, cy), (CX, cy + half_h), (CX, cy + half_h + drop), (CX - half_w, cy + drop)], fill=left + (255,))
    d.polygon([(CX + half_w, cy), (CX, cy + half_h), (CX, cy + half_h + drop), (CX + half_w, cy + drop)], fill=right + (255,))
    d.polygon(pts, fill=top + (255,))
    # a thin lighter rim along the top edges for the chunky block look
    d.line([pts[3], pts[0], pts[1]], fill=lerp(top, (255, 255, 255), 0.25) + (255,))

# base rock plinth rising out of the sea
terrace(190, 92, 46, 40, (64, 112, 48), ROCK_L, ROCK_R)
terrace(174, 70, 35, 18, TOP_GREEN, SIDE_L, SIDE_R)
terrace(160, 50, 25, 16, (96, 176, 64), SIDE_L, SIDE_R)
terrace(148, 30, 15, 14, (112, 190, 72), SIDE_L, SIDE_R)
# a couple of green tufts on the lower terraces
for (x, y) in [(84, 180), (160, 184), (104, 196), (150, 200), (120, 176)]:
    d.ellipse([x - 3, y - 2, x + 3, y + 2], fill=(130, 200, 90, 255))

# Keep: a small stone tower with crenellations, like the one on the title screen.
KX, KY, KW, KH = 128, 110, 22, 40
d.rectangle([KX - KW, KY, KX, KY + KH], fill=(96, 96, 104, 255))       # lit face
d.rectangle([KX, KY, KX + KW, KY + KH], fill=(64, 62, 72, 255))        # shaded face
# battlements
for i, x in enumerate(range(KX - KW, KX + KW, 6)):
    if i % 2 == 0:
        shade = (112, 112, 120, 255) if x < KX else (76, 74, 84, 255)
        d.rectangle([x, KY - 6, x + 4, KY], fill=shade)
# arrow slits
for x in (KX - 15, KX - 7, KX + 6, KX + 14):
    d.rectangle([x, KY + 10, x + 1, KY + 20], fill=(20, 18, 28, 255))
    d.rectangle([x - 2, KY + 13, x + 3, KY + 14], fill=(20, 18, 28, 255))
# door
d.rectangle([KX - 4, KY + KH - 10, KX + 3, KY + KH], fill=(24, 20, 30, 255))

# Ankh: gold, floating over the keep, with a warm glow behind it.
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([CX - 34, 18, CX + 34, 96], fill=(255, 190, 60, 150))
glow = glow.filter(ImageFilter.GaussianBlur(10))
img.alpha_composite(glow)
d = ImageDraw.Draw(img)
GOLD = (248, 196, 48, 255)
GOLD_D = (176, 122, 18, 255)
GOLD_L = (255, 236, 150, 255)
AX, AY = CX, 30
# loop
d.ellipse([AX - 13, AY, AX + 13, AY + 30], fill=GOLD)
d.ellipse([AX - 7, AY + 6, AX + 7, AY + 24], fill=(0, 0, 0, 0))
# cut the loop hole back to the sky with the glow
hole = Image.new("RGBA", (S, S), (0, 0, 0, 0))
hd = ImageDraw.Draw(hole)
hd.ellipse([AX - 7, AY + 6, AX + 7, AY + 24], fill=(255, 255, 255, 255))
sky = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(sky)
for y in range(AY, AY + 32):
    sd.line([(AX - 8, y), (AX + 8, y)], fill=lerp((10, 14, 46), (58, 26, 74), y / S) + (255,))
sky.alpha_composite(glow)
img.paste(sky, (0, 0), hole)
d = ImageDraw.Draw(img)
# crossbar and stem
d.rectangle([AX - 22, AY + 30, AX + 22, AY + 38], fill=GOLD)
d.rectangle([AX - 5, AY + 30, AX + 5, AY + 76], fill=GOLD)
# shading: dark right/bottom edges, light top-left highlights
d.line([(AX + 5, AY + 38), (AX + 5, AY + 76)], fill=GOLD_D, width=2)
d.line([(AX - 5, AY + 76), (AX + 5, AY + 76)], fill=GOLD_D, width=2)
d.line([(AX - 22, AY + 38), (AX + 22, AY + 38)], fill=GOLD_D, width=2)
d.line([(AX - 22, AY + 30), (AX + 22, AY + 30)], fill=GOLD_L, width=1)
d.line([(AX - 4, AY + 38), (AX - 4, AY + 76)], fill=GOLD_L, width=1)
d.arc([AX - 13, AY, AX + 13, AY + 30], 200, 320, fill=GOLD_L, width=2)
d.arc([AX - 13, AY, AX + 13, AY + 30], 30, 150, fill=GOLD_D, width=2)

# Scale up without smoothing, then clip to the macOS rounded square and add the
# standard soft shadow inset so it sits with the other dock icons.
big = img.resize((1024, 1024), Image.NEAREST)
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
inset = 100  # Apple's icon grid leaves ~10% margin around the rounded square
size = 1024 - 2 * inset
mask = Image.new("L", (size, size), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.225), fill=255)
art = big.resize((size, size), Image.LANCZOS)
shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
sh = Image.new("RGBA", (size, size), (0, 0, 0, 110))
shadow.paste(sh, (inset, inset + 10), mask)
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
canvas.alpha_composite(shadow)
canvas.paste(art, (inset, inset), mask)

# iconset -> icns
tmp = tempfile.mkdtemp()
iconset = os.path.join(tmp, "Populous.iconset")
os.mkdir(iconset)
for px in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        n = px * scale
        name = f"icon_{px}x{px}" + ("@2x" if scale == 2 else "") + ".png"
        canvas.resize((n, n), Image.LANCZOS).save(os.path.join(iconset, name))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT], check=True)
canvas.save(os.path.join(tmp, "preview.png"))
shutil.copy(os.path.join(tmp, "preview.png"), os.path.join(ROOT, "tools", "icon-preview.png"))
print("Wrote", OUT)
