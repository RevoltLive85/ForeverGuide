#!/usr/bin/env python3
"""Turn the ComfyUI renders in tools/art-src/ (gold ornaments on a solid black
background, Flux schnell) into the addon's TGA textures.

    diamond.png          -> Textures/waypoint.tga   128x128  the in-world marker
    compass.png          -> Textures/compass.tga     64x64   header icon + minimap button
    skull_medallion.png  -> Textures/skull_btn.tga   64x64   the skull target button
    corner.png           -> Textures/corner.tga     128x128  panel corner ornament (top-left; flipped for the others)
    compass/ic_*/diamond -> Textures/icons.tga      512x64   the row icon atlas: 8 tiles of 64
                            (compass, accept !, turnin ?, kill, collect, travel, done, current)

Black background -> alpha: a pixel's alpha is its brightest channel (the render is
pure black where there is nothing), the colour is un-premultiplied so the edges
keep their gold instead of going dark. Power-of-two sizes, 32-bit uncompressed
TGA, top-left origin - what the client wants.
"""
import os
import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "art-src")
OUT = os.path.join(os.path.dirname(HERE), "Textures")


def cutout(name, floor=24, boost=1.25):
    """RGBA with alpha lifted from the black background."""
    rgb = np.asarray(Image.open(os.path.join(SRC, name)).convert("RGB")).astype(np.float32)
    mx = rgb.max(axis=2)
    a = np.clip((mx - floor) / (255.0 - floor) * boost, 0, 1)
    # un-premultiply: colour / alpha, so a half-covered gold edge is still gold
    safe = np.where(a > 0.02, a, 1.0)[..., None]
    col = np.clip(rgb / (safe * 255.0) * 255.0, 0, 255)
    col = np.where(a[..., None] > 0.02, col, 0)
    out = np.dstack([col, a * 255.0]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def bbox(img, thresh=8):
    a = np.asarray(img)[..., 3]
    ys, xs = np.where(a > thresh)
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1


def fit_square(img, size, pad=0.06):
    """crop to the alpha bounding box, centre in a square with padding, resize."""
    x0, y0, x1, y1 = bbox(img)
    w, h = x1 - x0, y1 - y0
    side = int(max(w, h) * (1 + 2 * pad))
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(img.crop((x0, y0, x1, y1)), ((side - w) // 2, (side - h) // 2))
    return sq.resize((size, size), Image.LANCZOS)


def save(img, name):
    path = os.path.join(OUT, name)
    img.convert("RGBA").save(path, format="TGA", rle=False, orientation=1)
    print("wrote", path, img.size)


def waypoint():
    d = fit_square(cutout("diamond.png"), 128, pad=0.16)
    # a soft amber halo behind the diamond so it reads against bright ground too
    glow = Image.new("RGBA", d.size, (0, 0, 0, 0))
    mask = d.split()[3].filter(ImageFilter.GaussianBlur(9))
    glow.paste((255, 170, 60, 150), (0, 0, d.size[0], d.size[1]), mask)
    return Image.alpha_composite(glow, d)


def corner(size=128):
    """top-left ornament: the scroll plus the start of both arms, arms fading out."""
    img = cutout("corner.png")
    x0, y0, x1, y1 = bbox(img)
    arm = int((x1 - x0) * 0.42)            # how much of each arm to keep
    crop = img.crop((x0, y0, x0 + arm, y0 + arm))
    a = np.asarray(crop).astype(np.float32)
    n = crop.size[0]
    ramp = np.ones(n, dtype=np.float32)
    fade = int(n * 0.35)
    ramp[n - fade:] = np.linspace(1, 0, fade)
    a[..., 3] *= ramp[None, :]             # fade the arm going right
    a[..., 3] *= ramp[:, None]             # and the arm going down
    out = Image.fromarray(a.astype(np.uint8), "RGBA")
    sq = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    sq.paste(out, (0, 0))
    return sq.resize((size, size), Image.LANCZOS)


def icons_atlas(tile=64):
    """the 8-tile row-icon atlas, same order as Theme.ICON; a soft dark shadow under each glyph."""
    order = ["compass.png", "ic_accept.png", "ic_turnin.png", "ic_kill.png", "ic_collect.png", "ic_travel.png", "ic_done.png", "diamond.png"]
    atlas = Image.new("RGBA", (tile * len(order), tile), (0, 0, 0, 0))
    for i, name in enumerate(order):
        t = fit_square(cutout(name), tile, pad=0.08)
        shadow = Image.new("RGBA", (tile, tile), (0, 0, 0, 0))
        shadow.paste((0, 0, 0, 170), (0, 0, tile, tile), t.split()[3])
        shadow = shadow.filter(ImageFilter.GaussianBlur(2.0))
        atlas.paste(Image.alpha_composite(shadow, t), (i * tile, 0))
    return atlas


if __name__ == "__main__":
    save(waypoint(), "waypoint.tga")
    save(fit_square(cutout("compass.png"), 64, pad=0.02), "compass.tga")
    save(fit_square(cutout("skull_medallion.png"), 64, pad=0.02), "skull_btn.tga")
    save(corner(), "corner.tga")
    save(icons_atlas(), "icons.tga")
