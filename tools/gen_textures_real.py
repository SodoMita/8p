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
    """Tangent-space normal map in the OpenGL convention the renderer expects:
    +X in the map = toward the RIGHT of the image, +Y in the map = toward the TOP
    of the image, +Z = out of the surface.

    Image rows increase DOWNWARD, so with v_up = -y_image:
      nx = +dH/du                      = +dH/dx   (project convention)
      ny = -dH/dv_up = +dH/dy_image    = +dH/dy
    Getting the green sign wrong makes every bump read as a dent - which is what
    "inverted normals" looks like on bark ridges and stone pits.
    """
    dx = np.gradient(height, axis=1) * strength
    dy = np.gradient(height, axis=0) * strength
    nz = np.ones_like(height)
    ln = np.sqrt(dx * dx + dy * dy + nz * nz)
    nx, ny, nz = dx / ln, dy / ln, nz / ln
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
def _worley(h, w, nx, ny, seed, jitter=0.9):
    """F1 and F2 distances to jittered feature points on an nx-by-ny torus grid.

    Cells are 1/nx wide and 1/ny tall, so nx >> ny gives the tall narrow plates
    that tree bark is actually made of. Wrapping keeps the map tileable.
    """
    rng = np.random.default_rng(seed)
    off = rng.uniform(-0.5 * jitter, 0.5 * jitter, (ny, nx, 2)).astype(np.float32)
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    px = (xs + 0.5) / w * nx
    py = (ys + 0.5) / h * ny
    cx = np.floor(px).astype(np.int32)
    cy = np.floor(py).astype(np.int32)
    f1 = np.full((h, w), 1e9, np.float32)
    f2 = np.full((h, w), 1e9, np.float32)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            gx = cx + dx
            gy = cy + dy
            wx = np.mod(gx, nx)
            wy = np.mod(gy, ny)
            fx = gx + 0.5 + off[wy, wx, 0]
            fy = gy + 0.5 + off[wy, wx, 1]
            d = np.sqrt((fx - px) ** 2 + (fy - py) ** 2)
            closer = d < f1
            f2 = np.where(closer, f1, np.minimum(f2, d))
            f1 = np.where(closer, d, f1)
    return f1, f2


def make_bark(size=1024):
    """Dead spruce bark: narrow fissures between irregular plates.

    Two earlier attempts are worth not repeating. Anisotropic noise smeared down
    the image gives streaks, not bark: no plate structure for the torch to catch.
    Plain Voronoi cells give the opposite failure - a hard lattice of black bands
    that reads as cracked glass, because the fissures are as wide as the plates
    and perfectly regular.

    So: warp the cell coordinates with low-frequency noise first (plates are not a
    grid), keep the fissure NARROW (a fissure is a few centimetres in a metre of
    bark), and never let the crack go fully black - the sides of a fissure still
    catch light.
    """
    h = w = size

    # domain warp: bend the lattice so the plates are irregular
    warp = fbm(h, w, 4, 5, 0.55, seed=27)
    warp2 = fbm(h, w, 3, 7, 0.5, seed=28)

    def warped_worley(nx, ny, seed, jitter, wobble=0.55):
        # build the lattice on warped coordinates by resampling the distance field
        wf = np.dstack([warp, warp2]).astype(np.float32)
        ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
        px = ((xs + 0.5) / w + (wf[..., 0] - 0.5) * wobble * 0.35) * nx
        py = ((ys + 0.5) / h + (wf[..., 1] - 0.5) * wobble * 0.35) * ny
        rng = np.random.default_rng(seed)
        off = rng.uniform(-0.5 * jitter, 0.5 * jitter, (ny, nx, 2)).astype(np.float32)
        cx = np.floor(px).astype(np.int32)
        cy = np.floor(py).astype(np.int32)
        f1 = np.full((h, w), 1e9, np.float32)
        f2 = np.full((h, w), 1e9, np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                gx = cx + dx
                gy = cy + dy
                wx_ = np.mod(gx, nx)
                wy_ = np.mod(gy, ny)
                fx = gx + 0.5 + off[wy_, wx_, 0]
                fy = gy + 0.5 + off[wy_, wx_, 1]
                d = np.sqrt((fx - px) ** 2 + (fy - py) ** 2)
                closer = d < f1
                f2 = np.where(closer, f1, np.minimum(f2, d))
                f1 = np.where(closer, d, f1)
        return f1, f2

    # plates: taller than wide, but not extreme
    p1, p2 = warped_worley(8, 3, seed=31, jitter=0.95, wobble=0.30)
    edge = np.clip((p2 - p1) / 0.5, 0, 1)
    fissure = (1.0 - edge) ** 3.2            # thin: only right on the boundary

    # a second, offset layer breaks the first one up so nothing looks tiled
    q1, q2 = warped_worley(13, 6, seed=32, jitter=0.9, wobble=0.35)
    edge2 = np.clip((q2 - q1) / 0.45, 0, 1)
    fissure = np.maximum(fissure, (1.0 - edge2) ** 4.0 * 0.7)

    # cross-fractures: few, thin, shallow
    r1, r2 = warped_worley(3, 19, seed=33, jitter=0.65, wobble=0.3)
    cross = (1.0 - np.clip((r2 - r1) / 0.28, 0, 1)) ** 5.0

    grain = anisotropic(h, w, 480, 30, seed=34)      # vertical fibre
    fine = anisotropic(h, w, 900, 90, seed=35)       # finer fibre
    grit = fbm(h, w, 5, 10, 0.55, seed=36)           # pores and roughness
    blotch = fbm(h, w, 4, 3, 0.6, seed=37)           # lichen / weathering

    crown = np.clip(1.0 - fissure, 0, 1) ** 0.5
    height = crown * 0.85 + grain * 0.13 + fine * 0.07 + grit * 0.08
    height = np.clip(height - fissure * 0.60 - cross * 0.28, 0, 1.3)
    # 0 in the deepest crack, 1 on a plate crown - but a crack never reads black
    depth = np.clip(1.0 - fissure * 0.75 - cross * 0.40, 0.30, 1.0)

    # ---- albedo: weathered grey-brown, dark between the plates ------------
    lift = np.clip(height * 0.70 + grit * 0.25 + fine * 0.10, 0, 1)
    tone = np.zeros((h, w, 3), dtype=np.float32)
    tone[..., 0] = 0.225 + 0.245 * lift
    tone[..., 1] = 0.210 + 0.225 * lift
    tone[..., 2] = 0.185 + 0.195 * lift
    albedo = tone * (0.34 + 0.66 * depth)[..., None]
    # bleached grey plates, kept subtle: birch-white bark this is not
    weather = curve(blotch, 0.52, 0.90) * (0.40 + 0.60 * crown)
    albedo = overlay(albedo, (0.40, 0.395, 0.375), weather * 0.30)
    # lichen, sparse, crowns only
    moss = curve(blotch, 0.76, 0.97) * np.clip(crown - fissure * 2.0, 0, 1) * 0.30
    albedo = overlay(albedo, (0.29, 0.33, 0.235), moss)
    # surface grit so a lit trunk is not smooth marble
    albedo *= (0.82 + 0.34 * grit)[..., None]
    # vertical fibre running through the plates: the strongest "this is wood" cue
    fibre = anisotropic(h, w, 620, 22, seed=38)
    albedo *= (0.84 + 0.30 * fibre)[..., None]
    albedo *= (0.90 + 0.20 * fine)[..., None]
    albedo *= (0.94 + 0.12 * blotch)[..., None]

    rough = np.clip(0.99 - crown * 0.16 + grit * 0.06 - fine * 0.04, 0.66, 1.0)

    save_rgb(albedo * 255, "bark_albedo.png")
    Image.fromarray(normal_map(height, strength=7.0), "RGB").save(
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
# chain-link fabric (alpha cutout, tiles as a diamond weave)
# --------------------------------------------------------------------------- #
def make_chainlink(size=512):
    """Diamond-weave wire mesh with an alpha cutout. One tile == ~0.5 m of fence."""
    h = w = size
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(77)
    cell = size / 8.0          # 8 diamonds across the tile
    wire = max(2.0, size / 190.0)
    # two families of diagonals; drawn with wrap-around so the tile is seamless
    for k in range(-9, 10):
        off = k * cell
        for sign in (1.0, -1.0):
            x0, y0 = -size, off
            x1, y1 = size * 2, off + sign * (size * 2)
            shade = int(120 + rng.integers(-16, 22))
            col = (shade, shade + 2, shade + 4, 255)
            d.line([(x0, y0), (x1, y1)], fill=col, width=int(round(wire)))
            # wrap copies one tile up and down
            d.line([(x0, y0 - size), (x1, y1 - size)], fill=col, width=int(round(wire)))
            d.line([(x0, y0 + size), (x1, y1 + size)], fill=col, width=int(round(wire)))
    # the wire is round stock: brighten a thin highlight along its centre
    hi = img.filter(ImageFilter.GaussianBlur(0.7))
    arr = np.asarray(hi, dtype=np.float32)
    alpha = arr[..., 3:4]
    rgb = arr[..., :3] * (0.85 + 0.30 * (alpha / 255.0))
    out = np.concatenate([np.clip(rgb, 0, 255), alpha], axis=-1)
    Image.fromarray(out.astype(np.uint8), "RGBA").save(
        os.path.join(TEX, "chainlink.png"), optimize=True)
    print("  texture: chainlink.png")


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


def self_check() -> bool:
    """Guards the normal-map sign. A ramp rising toward the bottom of the image
    must encode green > 127 (normal tilting toward the TOP of the image), and a
    ramp rising to the right must encode red > 127 via +dH/dx."""
    n = 64
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    nm_v = normal_map(yy / n, strength=40.0)
    nm_h = normal_map(xx / n, strength=40.0)
    green = float(nm_v[..., 1].mean())
    red = float(nm_h[..., 0].mean())
    ok = green > 170.0 and red > 170.0
    print("  self-check normal sign: green=%.1f (want >170) red=%.1f (want >170) -> %s"
          % (green, red, "PASS" if ok else "FAIL"))
    return ok


if __name__ == "__main__":
    os.makedirs(TEX, exist_ok=True)
    if not self_check():
        raise SystemExit("normal_map() green channel is inverted - refusing to write textures")
    print("Generating realistic PBR textures...")
    make_bark()
    make_ground()
    make_stone()
    make_pumpkin()
    make_chainlink()
    make_grass()
    make_litter()
    print("done.")

def make_page_blank(size=(512, 672)):
    """Clean aged paper stock for the page notes (no printed lines).

    paper.png already carries ruled handwriting, so it cannot be used as the
    substrate for a page that has its own text drawn on it.
    """
    import numpy as np
    from PIL import Image, ImageFilter

    w, h = size
    rng = np.random.default_rng(7)

    def fbm(octaves, base, gain, seed):
        r = np.random.default_rng(seed)
        acc = np.zeros((h, w), np.float32)
        amp, tot = 1.0, 0.0
        for o in range(octaves):
            g = r.random((max(2, base * 2 ** o), max(2, base * 2 ** o)), dtype=np.float32)
            g = np.asarray(Image.fromarray((g * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC), np.float32) / 255.0
            acc += g * amp
            tot += amp
            amp *= gain
        return acc / tot

    macro, mid, fine = fbm(4, 3, 0.58, 11), fbm(5, 9, 0.55, 12), fbm(4, 64, 0.5, 13)
    base_col = np.stack([0.855, 0.822, 0.752], axis=-1)[None, None, :]
    out = base_col * (0.90 + 0.22 * macro[..., None])
    out = out * (0.96 + 0.09 * mid[..., None])
    out = out * (0.985 + 0.03 * fine[..., None])

    fib = Image.new("L", (w, h), 0)
    px = fib.load()
    for _ in range(1400):
        x0, y0 = int(rng.integers(0, w)), int(rng.integers(0, h))
        ln, a = int(rng.integers(4, 22)), float(rng.random() * 6.283)
        for t in range(ln):
            x, y = int(x0 + np.cos(a) * t), int(y0 + np.sin(a) * t)
            if 0 <= x < w and 0 <= y < h:
                px[x, y] = int(rng.integers(90, 160))
    fib_a = np.asarray(fib.filter(ImageFilter.GaussianBlur(0.6)), np.float32) / 255.0
    out = out * (1.0 - 0.16 * fib_a[..., None])

    yy, xx = np.mgrid[0:h, 0:w]
    edge = 1.0 - 0.16 * np.clip(((xx - w / 2) ** 2 / (w * 0.62) ** 2 + (yy - h / 2) ** 2 / (h * 0.62) ** 2), 0.0, 1.2)
    out = out * edge[..., None]
    Image.fromarray(np.clip(out * 255.0, 0, 255).astype(np.uint8)).save("assets/textures/page_blank.png")
    print("  texture: page_blank.png")

