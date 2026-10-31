#!/usr/bin/env python3
"""Realistic PBR texture set for EIGHT PAGES.

Produces albedo + normal + roughness maps for bark, forest ground, stone and
dry grass, all tileable and procedurally synthesised (no photo sources).
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEX = os.path.join(ROOT, "assets", "textures")


# --------------------------------------------------------------------------- #
# noise helpers
# --------------------------------------------------------------------------- #
def _value_noise(h, w, res, rng):
    grid = rng.random((res + 1, res + 1)).astype(np.float32)
    grid[-1, :] = grid[0, :]
    grid[:, -1] = grid[:, 0]
    img = Image.fromarray((grid * 255).astype(np.uint8), "L").resize((w, h), Image.BICUBIC)
    return np.asarray(img, dtype=np.float32) / 255.0


def fbm(h, w, octaves=6, base_res=4, persistence=0.5, seed=0):
    rng = np.random.default_rng(seed)
    out = np.zeros((h, w), dtype=np.float32)
    amp, norm = 1.0, 0.0
    res = base_res
    for _ in range(octaves):
        out += _value_noise(h, w, res, rng) * amp
        norm += amp
        amp *= persistence
        res = min(res * 2, max(h, w))
    return out / norm


def anisotropic(h, w, res_x, res_y, seed=0):
    """Noise stretched along one axis (vertical wood grain / horizontal strata)."""
    rng = np.random.default_rng(seed)
    grid = rng.random((res_y + 1, res_x + 1)).astype(np.float32)
    grid[-1, :] = grid[0, :]
    grid[:, -1] = grid[:, 0]
    img = Image.fromarray((grid * 255).astype(np.uint8), "L").resize((w, h), Image.BICUBIC)
    return np.asarray(img, dtype=np.float32) / 255.0


def normal_map(height, strength=2.0):
    dx = np.gradient(height, axis=1) * strength
    dy = np.gradient(height, axis=0) * strength
    nz = np.ones_like(height)
    ln = np.sqrt(dx * dx + dy * dy + nz * nz)
    nx, ny, nz = -dx / ln, -dy / ln, nz / ln
    rgb = np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5], axis=-1)
    return (np.clip(rgb, 0, 1) * 255).astype(np.uint8)


def save_rgb(arr, name):
    Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").save(
        os.path.join(TEX, name), optimize=True)
    print("  texture:", name)


def save_gray(arr, name):
    Image.fromarray(np.clip(arr * 255, 0, 255).astype(np.uint8), "L").save(
        os.path.join(TEX, name), optimize=True)
    print("  texture:", name)


def overlay(base, color, mask):
    """alpha-composite a flat colour over an RGB float array."""
    m = np.clip(mask, 0, 1)[..., None]
    c = np.array(color, dtype=np.float32)[None, None, :]
    return base * (1.0 - m) + c * m


def curve(x, a=0.5, b=1.6):
    return np.clip((x - a) / (b - a), 0, 1) ** 1.4


# --------------------------------------------------------------------------- #
# bark — dead spruce: deep vertical furrows, cracked plates, lichen
# --------------------------------------------------------------------------- #
def make_bark(size=1024):
    h = w = size
    grain = anisotropic(h, w, 300, 12, seed=11)          # long vertical fibres
    grain2 = anisotropic(h, w, 620, 40, seed=12)         # fine striations
    plate = anisotropic(h, w, 190, 10, seed=13)          # bark plates, strongly vertical
    crack = anisotropic(h, w, 420, 22, seed=14)
    blotch = fbm(h, w, 4, 3, 0.6, seed=15)

    # vertical furrows: sharp ridges between deep channels
    ridge = np.clip((plate - 0.34) * 3.2, 0, 1)
    furrow = np.clip(ridge * 0.9 + grain * 0.45 - 0.12, 0, 1)
    deep = curve(1.0 - (crack * 0.7 + grain * 0.3), 0.35, 0.72)   # 0 = crack

    height = furrow * (0.35 + 0.65 * deep)
    height = height * 0.8 + grain2 * 0.2

    # weathered grey-brown bark: bright enough for a flashlight to sculpt
    light = np.clip(height * 0.55 + grain2 * 0.2, 0, 1)
    tone = np.zeros((h, w, 3), dtype=np.float32)
    tone[..., 0] = 0.30 + 0.42 * light
    tone[..., 1] = 0.27 + 0.38 * light
    tone[..., 2] = 0.24 + 0.33 * light
    albedo = tone * (0.55 + 0.6 * height[..., None])
    # furrows are darker but never pure black
    albedo *= (0.34 + 0.66 * deep)[..., None]

    # lichen / moss patches on the ridges
    moss = curve(blotch, 0.55, 0.78) * np.clip(height, 0, 1) * 0.55
    albedo = overlay(albedo, (0.26, 0.30, 0.20), moss)
    # grey weathering
    weather = curve(blotch, 0.6, 0.9) * 0.25
    albedo = overlay(albedo, (0.42, 0.41, 0.39), weather)

    # roughness: smooth-ish ridges, very rough furrows, moss is matte
    rough = 1.0 - (height * 0.30) - moss * 0.05 + grain2 * 0.05
    rough = np.clip(rough, 0.62, 1.0)

    save_rgb(albedo * 255, "bark_albedo.png")
    Image.fromarray(normal_map(height, strength=6.0), "RGB").save(
        os.path.join(TEX, "bark_normal.png"), optimize=True)
    print("  texture: bark_normal.png")
    save_gray(rough, "bark_rough.png")


# --------------------------------------------------------------------------- #
# ground — damp humus, dead needles, dirt, moss, twigs and pebbles
# --------------------------------------------------------------------------- #
def make_ground(size=1024):
    h = w = size
    rng = np.random.default_rng(21)
    coarse = fbm(h, w, 6, 4, 0.55, seed=22)
    medium = fbm(h, w, 7, 9, 0.5, seed=23)
    fine = fbm(h, w, 8, 26, 0.55, seed=24)

    height = coarse * 0.6 + medium * 0.3 + fine * 0.1

    # base humus
    albedo = np.zeros((h, w, 3), dtype=np.float32)
    albedo[..., 0] = 0.125 + 0.14 * coarse
    albedo[..., 1] = 0.108 + 0.12 * coarse
    albedo[..., 2] = 0.082 + 0.09 * coarse

    # bare dirt patches
    dirt = curve(medium, 0.52, 0.72) * curve(coarse * 0.7 + 0.3, 0.5, 0.85)
    albedo = overlay(albedo, (0.21, 0.175, 0.135), dirt * 0.85)

    # damp moss in hollows
    hollow = 1.0 - curve(height, 0.35, 0.65)
    moss = curve(medium * 0.6 + hollow * 0.5, 0.55, 0.8) * 0.6
    albedo = overlay(albedo, (0.105, 0.135, 0.075), moss)

    # scattered needles (thin orange-brown dashes) drawn straight into buffers
    img = Image.fromarray(np.clip(albedo * 255, 0, 255).astype(np.uint8), "RGB")
    height_img = Image.fromarray((np.clip(height, 0, 1) * 255).astype(np.uint8), "L")
    d = ImageDraw.Draw(img)
    dh = ImageDraw.Draw(height_img)
    for _ in range(3400):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        ang = rng.uniform(-0.5, 0.5) + (math.pi if rng.random() < 0.5 else 0.0)
        ln = rng.uniform(5, 20)
        jitter = rng.uniform(-0.35, 0.35)
        x2 = x + math.cos(ang) * ln
        y2 = y + math.sin(ang) * ln
        c = rng.integers(95, 155)
        d.line([(x, y), (x2, y2)], fill=(int(c), int(c * 0.72), int(c * 0.42)), width=1)
        dh.line([(x, y), (x2, y2)], fill=int(150 + jitter * 80), width=1)
    # pebbles
    for _ in range(140):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.uniform(2.5, 7.0)
        v = int(rng.integers(56, 88))
        d.ellipse([x - r, y - r * 0.8, x + r, y + r * 0.8], fill=(v, int(v * 0.97), int(v * 0.92)))
        dh.ellipse([x - r, y - r * 0.8, x + r, y + r * 0.8], fill=205)
    # twigs
    for _ in range(160):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        ang = rng.uniform(0, math.tau)
        ln = rng.uniform(10, 46)
        d.line([(x, y), (x + math.cos(ang) * ln, y + math.sin(ang) * ln)],
               fill=(58, 48, 38), width=int(rng.integers(1, 3)))
    img = img.filter(ImageFilter.GaussianBlur(0.5))

    albedo = np.asarray(img, dtype=np.float32) / 255.0
    # large-scale tonal variation so tiling is not obvious
    macro = fbm(h, w, 3, 2, 0.6, seed=25)
    albedo *= (0.82 + 0.36 * macro)[..., None]

    hm = np.asarray(height_img.filter(ImageFilter.GaussianBlur(0.7)), dtype=np.float32) / 255.0

    save_rgb(albedo * 255, "ground_albedo.png")
    Image.fromarray(normal_map(hm, strength=3.2), "RGB").save(
        os.path.join(TEX, "ground_normal.png"), optimize=True)
    print("  texture: ground_normal.png")
    rough = np.clip(0.98 - dirt * 0.12 - moss * 0.05 + fine * 0.05, 0.72, 1.0)
    save_gray(rough, "ground_rough.png")


# --------------------------------------------------------------------------- #
# stone / weathered concrete (landmarks)
# --------------------------------------------------------------------------- #
def make_stone(size=1024):
    h = w = size
    rng = np.random.default_rng(31)
    coarse = fbm(h, w, 6, 5, 0.55, seed=32)
    fine = fbm(h, w, 8, 22, 0.5, seed=33)
    stains = fbm(h, w, 4, 3, 0.65, seed=34)

    base = 0.32 + 0.22 * coarse + 0.08 * fine
    albedo = np.stack([base, base * 0.985, base * 0.95], axis=-1)

    # dark water streaks running down
    streak = anisotropic(h, w, 260, 18, seed=35)
    wet = curve(streak, 0.62, 0.85) * curve(stains, 0.3, 0.7)
    albedo = overlay(albedo, (0.13, 0.13, 0.125), wet * 0.7)

    # moss concentrated in the lower part of the tile (tiles vertically on walls)
    yy = np.linspace(0, 1, h)[:, None]
    moss_noise = curve(fbm(h, w, 5, 7, 0.55, seed=36), 0.5, 0.8)
    moss = moss_noise * curve(1.0 - yy, 0.55, 0.95) * 0.75
    albedo = overlay(albedo, (0.10, 0.14, 0.075), moss)

    # hairline cracks
    img = Image.fromarray(np.clip(albedo * 255, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    for _ in range(26):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        ang = rng.uniform(0, math.tau)
        for _ in range(int(rng.integers(6, 22))):
            ang += rng.uniform(-0.6, 0.6)
            nx = x + math.cos(ang) * rng.uniform(6, 18)
            ny = y + math.sin(ang) * rng.uniform(6, 18)
            d.line([(x, y), (nx, ny)], fill=(44, 43, 41), width=1)
            x, y = nx, ny

    height = coarse * 0.55 + fine * 0.45
    height = height - moss * 0.15
    save_rgb(np.asarray(img, dtype=np.float32), "stone_albedo.png")
    Image.fromarray(normal_map(height, strength=2.6), "RGB").save(
        os.path.join(TEX, "stone_normal.png"), optimize=True)
    print("  texture: stone_normal.png")
    rough = np.clip(0.92 - wet * 0.35 + fine * 0.06, 0.45, 1.0)
    save_gray(rough, "stone_rough.png")


# --------------------------------------------------------------------------- #
# pumpkin rind — ribbed orange squash with warts, dirt and a matte waxy sheen
# --------------------------------------------------------------------------- #
def make_pumpkin(size=512):
    h = w = size
    # ribs run vertically on the sphere UVs, so use anisotropic furrows along Y
    ribs = anisotropic(h, w, 9, 220, seed=61)
    fine = fbm(h, w, 7, 18, 0.55, seed=62)
    blotch = fbm(h, w, 4, 4, 0.6, seed=63)
    warts = fbm(h, w, 9, 70, 0.6, seed=64)

    rib_field = 0.5 + 0.5 * np.sign(np.sin(ribs * math.pi * 9.0)) if False else ribs
    # vertical rib shading: darker in the valleys between lobes
    valley = curve(rib_field, 0.42, 0.62)
    light = np.clip(0.55 + 0.45 * (1.0 - valley), 0, 1)

    base = np.zeros((h, w, 3), dtype=np.float32)
    base[..., 0] = 0.62 + 0.22 * light
    base[..., 1] = 0.30 + 0.20 * light
    base[..., 2] = 0.055 + 0.05 * light
    albedo = base * (0.72 + 0.34 * fine[..., None])
    albedo *= (0.62 + 0.38 * (1.0 - valley))[..., None]

    # pale warty specks
    specks = curve(warts, 0.72, 0.92)
    albedo = overlay(albedo, (0.72, 0.55, 0.26), specks * 0.55)
    # field dirt and mould in the low spots
    grime = curve(blotch, 0.55, 0.85) * 0.5
    albedo = overlay(albedo, (0.16, 0.12, 0.07), grime)
    grey = curve(blotch, 0.62, 0.9) * 0.25
    albedo = overlay(albedo, (0.30, 0.29, 0.26), grey)

    height = (1.0 - valley) * 0.6 + fine * 0.25 + specks * 0.4
    save_rgb(albedo * 255, "pumpkin_albedo.png")
    Image.fromarray(normal_map(height, strength=3.0), "RGB").save(
        os.path.join(TEX, "pumpkin_normal.png"), optimize=True)
    print("  texture: pumpkin_normal.png")
    rough = np.clip(0.52 + valley * 0.26 + fine * 0.12, 0.42, 1.0)
    save_gray(rough, "pumpkin_rough.png")


# --------------------------------------------------------------------------- #
# dry grass / weed billboard (alpha cutout)
# --------------------------------------------------------------------------- #
def make_grass(size=512):
    h = w = size
    rng = np.random.default_rng(41)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for _ in range(90):
        x = rng.uniform(w * 0.12, w * 0.88)
        base_y = h - rng.uniform(0, 12)
        ln = rng.uniform(h * 0.35, h * 0.8)
        bend = rng.uniform(-70, 70)
        width = rng.uniform(1.2, 3.0)
        c = int(rng.integers(74, 132))
        col = (c, int(c * 0.86), int(c * 0.55), 255)
        pts = []
        steps = 8
        for i in range(steps + 1):
            t = i / steps
            xx = x + bend * t * t
            yy = base_y - ln * t
            pts.append((xx, yy))
        d.line(pts, fill=col, width=int(width), joint="curve")
    # seed heads
    for _ in range(26):
        x = rng.uniform(w * 0.15, w * 0.85)
        y = rng.uniform(h * 0.1, h * 0.45)
        d.ellipse([x - 2, y - 6, x + 2, y + 6], fill=(120, 105, 70, 255))
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    img.save(os.path.join(TEX, "grass.png"))
    print("  texture: grass.png")


# --------------------------------------------------------------------------- #
# dead-leaf litter decal (adds broken silhouette at the ground line)
# --------------------------------------------------------------------------- #
def make_litter(size=512):
    h = w = size
    rng = np.random.default_rng(51)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for _ in range(420):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        ln = rng.uniform(4, 14)
        ang = rng.uniform(0, math.tau)
        c = int(rng.integers(52, 96))
        wdt = int(rng.integers(1, 3))
        d.line([(x, y), (x + math.cos(ang) * ln, y + math.sin(ang) * ln)],
               fill=(c, int(c * 0.8), int(c * 0.55), 255), width=wdt)
    img.save(os.path.join(TEX, "litter.png"))
    print("  texture: litter.png")


if __name__ == "__main__":
    os.makedirs(TEX, exist_ok=True)
    print("Generating realistic PBR textures...")
    make_bark()
    make_ground()
    make_stone()
    make_pumpkin()
    make_grass()
    make_litter()
    print("done.")
