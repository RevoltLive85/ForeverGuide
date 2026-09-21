#!/usr/bin/env python3
"""
Procedural artwork for the Quest Guide UI -> Textures/*.tga (32-bit uncompressed,
power-of-two, what the WoW client loads). Everything is drawn here so the look
can be tuned in one place; drop-in replacements from an artist / ComfyUI just
need the same file names and sizes.

    python3 tools/make_textures.py
"""
import math
import os
import sys
import random

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "Textures")
os.makedirs(OUT, exist_ok=True)

GOLD = (222, 178, 74)
GOLD_LIGHT = (255, 224, 140)
GOLD_DARK = (140, 104, 34)
BROWN = (16, 11, 7)


def save(img, name):
    path = os.path.join(OUT, name)
    img.convert("RGBA").save(path, format="TGA", rle=False, orientation=1)
    print(f"{name:22s} {img.size[0]}x{img.size[1]}")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


# ---- panel background: dark parchment, tileable -----------------------------------
def panel_bg(size=256):
    random.seed(7)
    img = Image.new("RGBA", (size, size), BROWN + (255,))
    px = img.load()
    # low-frequency mottling from a few blurred random blobs, made seamless by wrapping
    noise = Image.new("L", (size, size), 0)
    nd = ImageDraw.Draw(noise)
    for _ in range(140):
        x, y, r = random.randrange(size), random.randrange(size), random.randrange(10, 46)
        v = random.randrange(40, 110)
        for dx in (-size, 0, size):
            for dy in (-size, 0, size):
                nd.ellipse((x + dx - r, y + dy - r, x + dx + r, y + dy + r), fill=v)
    noise = noise.filter(ImageFilter.GaussianBlur(9))
    grain = Image.effect_noise((size, size), 18).filter(ImageFilter.GaussianBlur(0.6))
    n, g = noise.load(), grain.load()
    for y in range(size):
        for x in range(size):
            m = (n[x, y] - 60) / 255.0
            gr = (g[x, y] - 128) / 255.0
            r = int(22 + 26 * m + 14 * gr)
            gg = int(15 + 18 * m + 10 * gr)
            b = int(9 + 10 * m + 6 * gr)
            px[x, y] = (max(0, min(255, r)), max(0, min(255, gg)), max(0, min(255, b)), 255)
    return img


# ---- edge files: 8 tiles side by side: L R T B TL TR BL BR ------------------------------
# The client stores the top and bottom tiles rotated by 90 degrees (it turns them when
# drawing), so the "top" tile is drawn like the left edge and "bottom" like the right.
def edge_file(size, draw_side, draw_corner):
    img = Image.new("RGBA", (size * 8, size), (0, 0, 0, 0))
    tiles = []
    for kind in ("L", "R", "T", "B", "TL", "TR", "BL", "BR"):
        t = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        if len(kind) == 1:
            draw_side(t, {"T": "L", "B": "R"}.get(kind, kind))
        else:
            draw_corner(t, kind)
        tiles.append(t)
    for i, t in enumerate(tiles):
        img.paste(t, (i * size, 0))
    return img


def gold_border(size=16):
    """Thin ornate gold border: a bright 2px line with a dark inner line and diamond corners."""
    def side(t, kind):
        d = ImageDraw.Draw(t)
        # the frame edge sits at the outer side of the tile
        if kind == "L":
            d.rectangle((0, 0, 1, size), fill=GOLD); d.rectangle((2, 0, 2, size), fill=GOLD_DARK); d.line((3, 0, 3, size), fill=(0, 0, 0, 120))
        elif kind == "R":
            d.rectangle((size - 2, 0, size - 1, size), fill=GOLD); d.rectangle((size - 3, 0, size - 3, size), fill=GOLD_DARK); d.line((size - 4, 0, size - 4, size), fill=(0, 0, 0, 120))
        elif kind == "T":
            d.rectangle((0, 0, size, 1), fill=GOLD); d.rectangle((0, 2, size, 2), fill=GOLD_DARK); d.line((0, 3, size, 3), fill=(0, 0, 0, 120))
        else:
            d.rectangle((0, size - 2, size, size - 1), fill=GOLD); d.rectangle((0, size - 3, size, size - 3), fill=GOLD_DARK); d.line((0, size - 4, size, size - 4), fill=(0, 0, 0, 120))

    def corner(t, kind):
        d = ImageDraw.Draw(t)
        ox = 0 if "L" in kind else size - 2
        oy = 0 if kind[0] == "T" else size - 2
        # the two edge lines meeting
        if "L" in kind:
            d.rectangle((0, 0, 1, size), fill=GOLD)
        else:
            d.rectangle((size - 2, 0, size - 1, size), fill=GOLD)
        if kind[0] == "T":
            d.rectangle((0, 0, size, 1), fill=GOLD)
        else:
            d.rectangle((0, size - 2, size, size - 1), fill=GOLD)
        # a small diamond ornament on the corner
        cx = 4 if "L" in kind else size - 5
        cy = 4 if kind[0] == "T" else size - 5
        r = 4
        d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], fill=GOLD_LIGHT)
        d.polygon([(cx, cy - 2), (cx + 2, cy), (cx, cy + 2), (cx - 2, cy)], fill=GOLD_DARK)

    return edge_file(size, side, corner)


def gold_glow(size=32):
    """Soft outer glow: alpha fading outward from the frame edge."""
    def falloff(dist):
        t = max(0.0, 1.0 - dist / (size - 1))
        return int(110 * t * t)

    def side(t, kind):
        px = t.load()
        for y in range(size):
            for x in range(size):
                # the panel lies on the inner side of the tile: strongest there, fading outward
                if kind == "L": dist = size - 1 - x
                elif kind == "R": dist = x
                elif kind == "T": dist = size - 1 - y
                else: dist = y
                px[x, y] = GOLD + (falloff(dist),)

    def corner(t, kind):
        px = t.load()
        cx = size - 1 if "L" in kind else 0
        cy = size - 1 if kind[0] == "T" else 0
        for y in range(size):
            for x in range(size):
                dist = math.hypot(x - cx, y - cy)
                px[x, y] = GOLD + (falloff(dist),)

    # flip: the glow must fade *outward*, i.e. strongest at the inner side of the tile
    img = edge_file(size, side, corner)
    return img


def thin_gold(size=8):
    """1px gold outline (active row)."""
    def side(t, kind):
        d = ImageDraw.Draw(t)
        if kind == "L": d.line((0, 0, 0, size), fill=GOLD)
        elif kind == "R": d.line((size - 1, 0, size - 1, size), fill=GOLD)
        elif kind == "T": d.line((0, 0, size, 0), fill=GOLD)
        else: d.line((0, size - 1, size, size - 1), fill=GOLD)

    def corner(t, kind):
        d = ImageDraw.Draw(t)
        if "L" in kind: d.line((0, 0, 0, size), fill=GOLD)
        else: d.line((size - 1, 0, size - 1, size), fill=GOLD)
        if kind[0] == "T": d.line((0, 0, size, 0), fill=GOLD)
        else: d.line((0, size - 1, size, size - 1), fill=GOLD)

    return edge_file(size, side, corner)


# ---- gradients and lines --------------------------------------------------------------
def row_active(w=256, h=32):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        vy = 1.0 - abs(y - h / 2) / (h / 2) * 0.35
        for x in range(w):
            t = x / (w - 1)
            a = int((70 * (1 - t) + 18) * vy)
            px[x, y] = (150, 110, 40, a)
    return img


def row_left_bar(w=8, h=32):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        vy = 1.0 - abs(y - h / 2) / (h / 2)
        for x in range(w):
            a = int(255 * vy ** 0.5 * (1 - x / w))
            px[x, y] = GOLD_LIGHT + (a,)
    return img


def header_line(w=256, h=8):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for x in range(w):
        t = x / (w - 1)
        a = int(255 * (1 - (2 * t - 1) ** 2) ** 1.5)
        for y in range(h):
            dy = abs(y - h / 2 + 0.5)
            v = max(0.0, 1.0 - dy / 1.6)
            px[x, y] = lerp(GOLD, GOLD_LIGHT, 1 - abs(2 * t - 1)) + (int(a * v),)
    return img


def separator(w=256, h=4):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for x in range(w):
        t = x / (w - 1)
        a = int(90 * (1 - (2 * t - 1) ** 4))
        for y in range(h):
            v = 1.0 if y in (1, 2) else 0.0
            px[x, y] = GOLD + (int(a * v),)
    return img


def button(w=128, h=32, bright=False):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base = (40, 28, 14, 235) if not bright else (70, 50, 22, 245)
    d.rounded_rectangle((0, 0, w - 1, h - 1), radius=6, fill=base, outline=GOLD_DARK + (255,), width=1)
    d.rounded_rectangle((1, 1, w - 2, h - 2), radius=5, outline=GOLD + (140 if not bright else 255,), width=1)
    # a soft top highlight
    px = img.load()
    for y in range(2, h // 2):
        t = 1 - (y - 2) / (h / 2)
        for x in range(2, w - 2):
            r, g, b, a = px[x, y]
            if a:
                px[x, y] = (min(255, r + int(28 * t)), min(255, g + int(20 * t)), min(255, b + int(8 * t)), a)
    return img


# ---- icons (32x32 each, atlas 256x32: compass ! ? sword bag boot check diamond) --------------
def icon_compass(t):
    d = ImageDraw.Draw(t)
    d.ellipse((2, 2, 29, 29), outline=GOLD + (255,), width=2)
    d.ellipse((6, 6, 25, 25), outline=GOLD_DARK + (255,), width=1)
    d.polygon([(16, 4), (19, 16), (16, 28), (13, 16)], fill=GOLD_LIGHT + (255,))
    d.polygon([(4, 16), (16, 13), (28, 16), (16, 19)], fill=GOLD + (255,))
    d.polygon([(16, 4), (19, 16), (16, 16)], fill=(200, 60, 40, 255))
    d.ellipse((14, 14, 17, 17), fill=GOLD_DARK + (255,))


def icon_glyph(t, text_shape):
    d = ImageDraw.Draw(t)
    if text_shape == "!":
        d.rounded_rectangle((13, 3, 18, 20), radius=2, fill=GOLD_LIGHT + (255,))
        d.ellipse((12, 23, 19, 30), fill=GOLD_LIGHT + (255,))
    elif text_shape == "?":
        d.arc((8, 3, 24, 19), start=200, end=90, fill=GOLD_LIGHT + (255,), width=4)
        d.line((16, 18, 16, 22), fill=GOLD_LIGHT + (255,), width=4)
        d.ellipse((13, 25, 19, 31), fill=GOLD_LIGHT + (255,))


def icon_sword(t):
    d = ImageDraw.Draw(t)
    for (a, b) in (((6, 26), (24, 6)), ((26, 26), (8, 6))):
        d.line((a, b), fill=GOLD + (255,), width=3)
    d.line((10, 26, 6, 22), fill=GOLD_LIGHT + (255,), width=3)
    d.line((22, 26, 26, 22), fill=GOLD_LIGHT + (255,), width=3)
    d.ellipse((13, 13, 19, 19), fill=(200, 60, 40, 255))


def icon_bag(t):
    d = ImageDraw.Draw(t)
    d.rounded_rectangle((7, 11, 25, 28), radius=4, fill=GOLD_DARK + (255,), outline=GOLD + (255,), width=2)
    d.arc((11, 4, 21, 16), start=180, end=0, fill=GOLD + (255,), width=3)
    d.line((7, 17, 25, 17), fill=GOLD_LIGHT + (255,), width=1)


def icon_boot(t):
    d = ImageDraw.Draw(t)
    d.ellipse((9, 4, 17, 16), fill=GOLD + (255,))
    d.ellipse((11, 17, 19, 27), fill=GOLD + (255,))
    d.ellipse((19, 8, 25, 16), fill=GOLD_DARK + (255,))


def icon_check(t):
    d = ImageDraw.Draw(t)
    d.line((6, 17, 13, 25), fill=GOLD_LIGHT + (255,), width=4)
    d.line((12, 25, 27, 7), fill=GOLD_LIGHT + (255,), width=4)


def icon_diamond(t):
    d = ImageDraw.Draw(t)
    d.polygon([(16, 3), (28, 16), (16, 29), (4, 16)], fill=GOLD_DARK + (255,))
    d.polygon([(16, 6), (25, 16), (16, 26), (7, 16)], fill=GOLD + (255,))
    d.polygon([(16, 9), (22, 16), (16, 23), (10, 16)], fill=GOLD_LIGHT + (255,))


def icon_skull(t):
    d = ImageDraw.Draw(t)
    d.ellipse((7, 4, 25, 22), fill=(220, 200, 170, 255))
    d.rectangle((11, 20, 21, 27), fill=(220, 200, 170, 255))
    d.ellipse((10, 10, 15, 15), fill=(40, 20, 20, 255))
    d.ellipse((17, 10, 22, 15), fill=(40, 20, 20, 255))
    d.polygon([(16, 15), (18, 19), (14, 19)], fill=(40, 20, 20, 255))


def icons_atlas():
    draws = [icon_compass, lambda t: icon_glyph(t, "!"), lambda t: icon_glyph(t, "?"), icon_sword, icon_bag, icon_boot, icon_check, icon_diamond]
    img = Image.new("RGBA", (256, 32), (0, 0, 0, 0))
    for i, fn in enumerate(draws):
        t = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
        fn(t)
        # a faint dark drop shadow for readability on any background
        shadow = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
        shadow.paste((0, 0, 0, 160), (0, 0, 32, 32), t.split()[3])
        shadow = shadow.filter(ImageFilter.GaussianBlur(1.2))
        out = Image.alpha_composite(shadow, t)
        img.paste(out, (i * 32, 0))
    return img


def ring(size=32):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((2, 2, size - 3, size - 3), fill=(20, 14, 8, 200), outline=GOLD + (255,), width=2)
    d.ellipse((5, 5, size - 6, size - 6), outline=GOLD_DARK + (160,), width=1)
    return img


# ---- waypoint: gold diamond with glow, dot, chevron --------------------------------------
def waypoint(size=64):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = glow.load()
    c = size / 2 - 0.5
    for y in range(size):
        for x in range(size):
            dist = abs(x - c) + abs(y - c)
            a = max(0.0, 1.0 - dist / (size * 0.52))
            px[x, y] = (255, 170, 60, int(200 * a ** 2.2))
    d = ImageDraw.Draw(img)
    m = size // 2
    r = int(size * 0.28)
    d.polygon([(m, m - r), (m + r, m), (m, m + r), (m - r, m)], fill=GOLD_DARK + (255,))
    r2 = int(size * 0.22)
    d.polygon([(m, m - r2), (m + r2, m), (m, m + r2), (m - r2, m)], fill=GOLD + (255,))
    r3 = int(size * 0.12)
    d.polygon([(m, m - r3), (m + r3, m), (m, m + r3), (m - r3, m)], fill=GOLD_LIGHT + (255,))
    return Image.alpha_composite(glow, img)


def dot(size=16):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    c = size / 2 - 0.5
    for y in range(size):
        for x in range(size):
            dist = math.hypot(x - c, y - c) / (size / 2)
            a = max(0.0, 1.0 - dist)
            col = lerp(GOLD, GOLD_LIGHT, a)
            px[x, y] = col + (int(255 * a ** 1.6),)
    return img


def chevron(size=64):
    """Fallback screen arrow: a gold chevron pointing up (rotated by the addon)."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = size // 2
    pts = [(m, 6), (size - 10, m + 10), (m, m - 2), (10, m + 10)]
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon([(x + 1, y + 2) for x, y in pts], fill=(0, 0, 0, 170))
    shadow = shadow.filter(ImageFilter.GaussianBlur(1.5))
    d.polygon(pts, fill=GOLD + (255,), outline=GOLD_DARK + (255,))
    d.polygon([(m, 14), (size - 18, m + 6), (m, m - 4), (18, m + 6)], fill=GOLD_LIGHT + (255,))
    return Image.alpha_composite(shadow, img)


if __name__ == "__main__":
    save(panel_bg(), "panel_bg.tga")
    save(gold_border(), "border_gold.tga")
    save(gold_glow(), "glow_gold.tga")
    save(thin_gold(), "border_thin.tga")
    save(row_active(), "row_active.tga")
    save(row_left_bar(), "row_bar.tga")
    save(header_line(), "header_line.tga")
    save(separator(), "separator.tga")
    save(button(), "button.tga")
    save(button(bright=True), "button_hl.tga")
    # icons.tga and waypoint.tga now come from the ComfyUI renders (tools/make_art.py); the
    # procedural versions are kept here as the fallback: `make_textures.py --procedural-art`
    if "--procedural-art" in sys.argv: save(icons_atlas(), "icons.tga")
    save(ring(), "ring.tga")
    if "--procedural-art" in sys.argv: save(waypoint(), "waypoint.tga")
    save(dot(), "dot.tga")
    save(chevron(), "chevron.tga")
