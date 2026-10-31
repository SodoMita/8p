#!/usr/bin/env python3
"""Generate all procedural assets for EIGHT PAGES (textures + audio).

No third-party assets: everything is synthesised from noise so the project is
self-contained and licence-clean.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO = os.path.join(ROOT, "assets", "audio")
TEX = os.path.join(ROOT, "assets", "textures")
SR = 22050


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def smooth_noise(h, w, octaves, persistence=0.5, seed=0):
    rng = np.random.default_rng(seed)
    total = np.zeros((h, w), dtype=np.float32)
    amp = 1.0
    norm = 0.0
    for o in range(octaves):
        res_h = max(2, int(2 ** (o + 1)))
        res_w = max(2, int(2 ** (o + 1) * w / h))
        base = rng.random((res_h, res_w)).astype(np.float32)
        img = Image.fromarray((base * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
        total += np.asarray(img, dtype=np.float32) / 255.0 * amp
        norm += amp
        amp *= persistence
    return total / norm


def tile_noise(h, w, octaves, persistence=0.5, seed=0):
    """Seamlessly tileable value noise via 4-way blend."""
    a = smooth_noise(h, w, octaves, persistence, seed)
    b = smooth_noise(h, w, octaves, persistence, seed + 101)
    y = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    x = np.linspace(0, 1, w, dtype=np.float32)[None, :]
    # blend toward shifted copies so edges match
    ay = a * (1 - y) + np.roll(a, h // 2, axis=0) * y
    by = b * (1 - x) + np.roll(b, w // 2, axis=1) * x
    return np.clip((ay + by) * 0.5, 0, 1)


def save_img(arr, path, mode="L"):
    if mode == "RGB":
        img = Image.fromarray(np.clip(arr * 255, 0, 255).astype(np.uint8), "RGB")
    else:
        img = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8), "L")
    img.save(path, optimize=True)
    print("  texture:", os.path.relpath(path, ROOT))


def srgb(c):
    return tuple(int(round(v * 255)) for v in c)


# --------------------------------------------------------------------------- #
# textures
# --------------------------------------------------------------------------- #
def make_textures():
    print("Generating textures...")

    # --- forest floor: dark humus + needles + dirt patches -------------------
    h = w = 512
    n1 = tile_noise(h, w, 6, 0.55, seed=3)
    n2 = tile_noise(h, w, 8, 0.6, seed=9)
    fine = tile_noise(h, w, 9, 0.75, seed=21)
    rgb = np.zeros((h, w, 3), dtype=np.float32)
    base = np.array([0.20, 0.18, 0.13], dtype=np.float32)
    green = np.array([0.16, 0.20, 0.11], dtype=np.float32)
    dark = np.array([0.09, 0.08, 0.06], dtype=np.float32)
    for i in range(3):
        col = base[i] * (0.55 + 0.9 * n1) + green[i] * n2 * 0.5
        col -= dark[i] * (fine ** 3) * 0.8
        rgb[:, :, i] = col
    # scattered bright needles
    rng = np.random.default_rng(5)
    needles = rng.random((h, w)) > 0.985
    rgb[needles] += np.array([0.16, 0.13, 0.08])
    rgb = np.clip(rgb, 0, 1)
    save_img(rgb, os.path.join(TEX, "ground.png"), "RGB")

    # --- bark ---------------------------------------------------------------
    bw, bh = 256, 512
    vert = np.sin(np.linspace(0, 34 * math.pi, bw, dtype=np.float32))[None, :] * 0.5 + 0.5
    n = tile_noise(bh, bw, 7, 0.62, seed=44)
    streak = tile_noise(bh, bw, 9, 0.5, seed=45)
    b = np.zeros((bh, bw, 3), dtype=np.float32)
    tone = (0.30 + 0.35 * n) * (0.55 + 0.45 * vert) * (0.7 + 0.6 * streak)
    b[:, :, 0] = tone * 0.85
    b[:, :, 1] = tone * 0.75
    b[:, :, 2] = tone * 0.60
    b = np.clip(b, 0, 1)
    save_img(b, os.path.join(TEX, "bark.png"), "RGB")

    # --- stone --------------------------------------------------------------
    sw = sh = 512
    sn = tile_noise(sh, sw, 6, 0.6, seed=77)
    grit = tile_noise(sh, sw, 9, 0.7, seed=78)
    rel = np.zeros((sh, sw, 3), dtype=np.float32)
    v = 0.30 + 0.42 * sn
    v = v * (0.85 + 0.3 * grit)
    rel[:, :, 0] = v * 1.0
    rel[:, :, 1] = v * 0.98
    rel[:, :, 2] = v * 0.92
    img = Image.fromarray(np.clip(rel * 255, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(11)
    # block seams
    y = 0
    while y < sh:
        hgt = int(rng.integers(48, 96))
        d.line([(0, y), (sw, y)], fill=(35, 34, 32), width=3)
        off = int(rng.integers(0, 100))
        for x in range(off, sw, 100):
            d.line([(x, y), (x, min(sh, y + hgt))], fill=(38, 37, 34), width=3)
        y += hgt
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    img.save(os.path.join(TEX, "stone.png"))
    print("  texture: assets/textures/stone.png")

    # --- paper page ---------------------------------------------------------
    pw, ph = 320, 420
    paper = tile_noise(ph, pw, 6, 0.5, seed=123) * 0.25 + 0.75
    grain = tile_noise(ph, pw, 9, 0.8, seed=124)
    pg = np.zeros((ph, pw, 3), dtype=np.float32)
    pg[:, :, 0] = 0.86 * paper + 0.06 * grain
    pg[:, :, 1] = 0.83 * paper + 0.05 * grain
    pg[:, :, 2] = 0.72 * paper + 0.04 * grain
    img = Image.fromarray(np.clip(pg * 255, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(31)
    # torn / dirty edges
    for _ in range(1400):
        x = int(rng.integers(0, pw))
        y = int(rng.integers(0, ph))
        edge = min(x, y, pw - x, ph - y)
        if edge < 14 and rng.random() > edge / 14.0:
            c = int(rng.integers(120, 175))
            d.point((x, y), fill=(c, c - 10, c - 30))
    # manic handwriting
    for line in range(16):
        y = 48 + line * 21 + int(rng.integers(-3, 3))
        x = 26
        while x < pw - 26:
            seg = int(rng.integers(10, 44))
            amp = int(rng.integers(2, 8))
            d.line([(x, y), (x + seg, y + int(rng.integers(-amp, amp)))], fill=(38, 33, 30), width=2)
            x += seg + int(rng.integers(4, 14))
        if rng.random() > 0.7:
            d.line([(26, y + 8), (pw - 26, y + 10)], fill=(52, 44, 40), width=1)
    img = img.filter(ImageFilter.GaussianBlur(0.4))
    img.save(os.path.join(TEX, "paper.png"))
    print("  texture: assets/textures/paper.png")


    # --- blank aged paper for the UI note popups ---------------------------
    img2 = Image.fromarray(np.clip(pg * 255, 0, 255).astype(np.uint8), "RGB").copy()
    d2 = ImageDraw.Draw(img2)
    rng2 = np.random.default_rng(312)
    for _ in range(2200):
        x = int(rng2.integers(0, pw))
        y = int(rng2.integers(0, ph))
        edge = min(x, y, pw - x, ph - y)
        if edge < 16 and rng2.random() > edge / 16.0:
            c = int(rng2.integers(115, 170))
            d2.point((x, y), fill=(c, c - 8, c - 26))
    for _ in range(26):
        x = int(rng2.integers(0, pw))
        y = int(rng2.integers(0, ph))
        r = int(rng2.integers(8, 40))
        d2.ellipse([x, y, x + r, y + r], fill=(196, 186, 158))
    img2 = img2.filter(ImageFilter.GaussianBlur(1.6))
    img2.save(os.path.join(TEX, "note.png"))
    print("  texture: assets/textures/note.png")

    # --- noise for the static post shader -----------------------------------
    nw = 256
    nrng = np.random.default_rng(99)
    noise = nrng.integers(0, 256, (nw, nw, 3), dtype=np.uint8)
    Image.fromarray(noise, "RGB").save(os.path.join(TEX, "noise.png"))
    print("  texture: assets/textures/noise.png")

    # --- icon ---------------------------------------------------------------
    icon = Image.new("RGBA", (128, 128), (8, 8, 10, 255))
    d = ImageDraw.Draw(icon)
    for i in range(9):
        a = i / 8.0
        d.ellipse([10 + i * 4, 20 + i * 5, 118 - i * 4, 112 - i * 3],
                  outline=(int(200 - 120 * a), int(196 - 130 * a), int(190 - 130 * a), 255), width=2)
    d.rectangle([56, 28, 72, 104], fill=(226, 222, 210, 255))
    icon.save(os.path.join(ROOT, "icon.png"))
    print("  texture: icon.png")



def _pine(d, x, base_y, h, col):
    w = h * 0.34
    d.rectangle([x - h * 0.022, base_y - h * 0.22, x + h * 0.022, base_y], fill=col)
    tiers = 5
    for t in range(tiers):
        ty = base_y - h * (0.16 + 0.155 * t)
        tw = w * (1.0 - t * 0.16)
        th = h * (0.34 - t * 0.03)
        d.polygon([(x - tw, ty), (x + tw, ty), (x, ty - th)], fill=col)


def make_title_bg():
    """Layered pine silhouettes under a hazy moon — title screen backdrop."""
    W, H = 1280, 720
    rng = np.random.default_rng(7)
    sky_top = np.array([9, 12, 18], dtype=np.float32)
    sky_bot = np.array([44, 52, 60], dtype=np.float32)
    grad = np.linspace(0, 1, H, dtype=np.float32)[:, None, None] ** 1.6
    img = (sky_top[None, None, :] * (1 - grad) + sky_bot[None, None, :] * grad).astype(np.float32)
    img = np.repeat(img, W, axis=1)
    out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(out, "RGBA")

    # --- moon -------------------------------------------------------------
    mx, my, mr = 912, 196, 44
    for r in range(mr * 6, mr, -4):
        a = int(22 * (1 - (r - mr) / float(mr * 6)) ** 2.2)
        d.ellipse([mx - r, my - r, mx + r, my + r], fill=(196, 208, 224, a))
    d.ellipse([mx - mr, my - mr, mx + mr, my + mr], fill=(222, 227, 232, 255))
    for _ in range(90):
        px, py = int(rng.integers(mx - mr, mx + mr)), int(rng.integers(my - mr, my + mr))
        if (px - mx) ** 2 + (py - my) ** 2 < (mr - 5) ** 2:
            d.point((px, py), fill=(178, 184, 194, int(rng.integers(25, 80))))
    # thin clouds across the moon
    for i in range(7):
        cy = my - 40 + i * 15 + int(rng.integers(-4, 4))
        cw = int(rng.integers(240, 520))
        d.ellipse([mx - cw // 2, cy, mx + cw // 2, cy + 13], fill=(24, 28, 34, 150))

    # --- distant jagged treeline -----------------------------------------
    horizon = int(H * 0.61)
    pts = [(0, H)]
    x = 0
    while x < W:
        step = int(rng.integers(14, 34))
        y = horizon - int(rng.integers(0, 46))
        pts.append((x, y))
        x += step
    pts.append((W, horizon + 40))
    pts.append((W, H))
    d.polygon(pts, fill=(19, 24, 29, 255))

    # --- mid pines --------------------------------------------------------
    for i in range(46):
        x = rng.uniform(-40, W + 40)
        h = rng.uniform(70, 150)
        _pine(d, x, horizon + rng.uniform(10, 26), h, (14, 18, 22, 255))

    # --- framing pines (left + right thirds, center stays clear) ---------
    for i in range(9):
        x = rng.uniform(-30, W * 0.30)
        _pine(d, x, H + rng.uniform(0, 30), rng.uniform(260, 430), (6, 8, 10, 255))
    for i in range(9):
        x = rng.uniform(W * 0.70, W + 30)
        _pine(d, x, H + rng.uniform(0, 30), rng.uniform(260, 430), (6, 8, 10, 255))

    # --- low ground fog ---------------------------------------------------
    fog = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    fd = ImageDraw.Draw(fog)
    for i in range(150):
        y = int(H * 0.55 + i * 1.8)
        a = int(30 * (1 - i / 150.0) ** 1.5)
        fd.rectangle([0, y, W, y + 5], fill=(126, 138, 150, a))
    fog = fog.filter(ImageFilter.GaussianBlur(8))
    out = Image.alpha_composite(out.convert("RGBA"), fog).convert("RGB")

    arr = np.asarray(out).astype(np.float32)
    grain = np.random.default_rng(3).normal(0, 5, (H, W, 1))
    arr = np.clip(arr + grain, 0, 255)
    Image.fromarray(arr.astype(np.uint8), "RGB").save(os.path.join(TEX, "title_bg.png"))
    print("  texture: assets/textures/title_bg.png")


# --------------------------------------------------------------------------- #
# audio
# --------------------------------------------------------------------------- #
def make_audio():
    """All sound is synthesised in gen_sfx.py (see the docstring there for the
    voice engine that makes the screams read as a throat, not a hiss)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import gen_sfx
    gen_sfx.generate(AUDIO, SR)


if __name__ == "__main__":
    os.makedirs(AUDIO, exist_ok=True)
    os.makedirs(TEX, exist_ok=True)
    make_textures()
    make_title_bg()
    make_audio()
    print("done.")
