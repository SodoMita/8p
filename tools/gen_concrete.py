#!/usr/bin/env python3
"""Poured, weathered 1970s concrete PBR texture set for EIGHT PAGES.

Builds a seamless 2048 px albedo / normal / roughness triple and writes it to
assets/textures/stone_albedo.png, stone_normal.png and stone_rough.png.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_textures_real import (
    fbm,
    anisotropic,
    normal_map,
    curve,
    overlay,
    save_rgb,
    save_gray,
    TEX,
)

SIZE = 2048


def _mask(layer, blur=0.0):
    if blur > 0.0:
        layer = layer.filter(ImageFilter.GaussianBlur(blur))
    return np.asarray(layer, dtype=np.float32) / 255.0


def _wrap_ellipse(draw, x, y, rx, ry, fill, w, h,
                  outline=None, width=1):
    xs = [x]
    if x - rx < 0.0:
        xs.append(x + w)
    if x + rx > w:
        xs.append(x - w)
    ys = [y]
    if y - ry < 0.0:
        ys.append(y + h)
    if y + ry > h:
        ys.append(y - h)
    for xx in xs:
        for yy in ys:
            draw.ellipse([xx - rx, yy - ry, xx + rx, yy + ry],
                         fill=fill, outline=outline, width=width)


def _draw_wrapped_line(draw, pts, fill, width, w, h):
    for ox in (-w, 0, w):
        for oy in (-h, 0, h):
            draw.line([(x + ox, y + oy) for x, y in pts],
                      fill=fill, width=width, joint="curve")


def _draw_wrapped_poly(draw, pts, fill, outline, width, w, h):
    for ox in (-w, 0, w):
        for oy in (-h, 0, h):
            p = [(x + ox, y + oy) for x, y in pts]
            if outline is None:
                draw.polygon(p, fill=fill)
            else:
                draw.polygon(p, fill=fill, outline=outline, width=width)


def _make_speckle(rng, size):
    w = h = size
    light = Image.new("L", (w, h), 0)
    dark = Image.new("L", (w, h), 0)
    dl = ImageDraw.Draw(light)
    dd = ImageDraw.Draw(dark)
    for _ in range(22000):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.uniform(0.6, 2.3)
        ry = r * rng.uniform(0.55, 1.0)
        value = int(rng.integers(70, 255))
        if rng.random() < 0.58:
            _wrap_ellipse(dl, x, y, r, ry, value, w, h)
        else:
            _wrap_ellipse(dd, x, y, r, ry, value, w, h)
    for _ in range(1500):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.uniform(1.6, 4.2)
        ry = r * rng.uniform(0.55, 1.0)
        value = int(rng.integers(80, 255))
        if rng.random() < 0.55:
            _wrap_ellipse(dl, x, y, r, ry, value, w, h)
        else:
            _wrap_ellipse(dd, x, y, r, ry, value, w, h)
    return light, dark


def _make_pits(rng, size, count, rmin, rmax, vmin, vmax):
    w = h = size
    img = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(img)
    for _ in range(count):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.uniform(rmin, rmax)
        ry = r * rng.uniform(0.55, 1.0)
        _wrap_ellipse(d, x, y, r, ry, int(rng.integers(vmin, vmax)), w, h)
    return img


def _make_bubbles(rng, size):
    w = h = size
    core = Image.new("L", (w, h), 0)
    rim = Image.new("L", (w, h), 0)
    dc = ImageDraw.Draw(core)
    dr = ImageDraw.Draw(rim)
    for _ in range(2100):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.uniform(0.7, 3.0)
        _wrap_ellipse(dr, x, y, r + 1.0, r + 1.0,
                      int(rng.integers(55, 150)), w, h)
        _wrap_ellipse(dc, x, y, r, r * rng.uniform(0.7, 1.0),
                      int(rng.integers(155, 255)), w, h)
    return core, rim


def _make_chips(rng, size):
    w = h = size
    mask = Image.new("L", (w, h), 0)
    edge = Image.new("L", (w, h), 0)
    rgb = Image.new("RGB", (w, h), (55, 53, 50))
    agg = Image.new("L", (w, h), 0)
    dm = ImageDraw.Draw(mask)
    de = ImageDraw.Draw(edge)
    drgb = ImageDraw.Draw(rgb)
    da = ImageDraw.Draw(agg)
    chips = []
    for _ in range(3):
        cx, cy = rng.uniform(0, w), rng.uniform(0, h)
        rad = rng.uniform(85, 155)
        n = 26
        pts = []
        for k in range(n):
            a = math.tau * k / n
            rr = rad * (0.62 + 0.38 * rng.random())
            pts.append((cx + math.cos(a) * rr,
                        cy + math.sin(a) * rr * rng.uniform(0.7, 1.0)))
        _draw_wrapped_poly(dm, pts, 255, None, 1, w, h)
        _draw_wrapped_line(de, pts + [pts[0]], 255, int(rng.integers(2, 4)), w, h)
        chips.append((cx, cy, rad))
    mask_np = _mask(mask)
    for cx, cy, rad in chips:
        for _ in range(int(rad * 2.4)):
            a = rng.uniform(0, math.tau)
            rr = rad * math.sqrt(rng.random()) * 0.92
            x = (cx + math.cos(a) * rr) % w
            y = (cy + math.sin(a) * rr) % h
            if mask_np[int(y), int(x)] < 0.5:
                continue
            r = rng.uniform(1.5, 5.6)
            ry = r * rng.uniform(0.6, 1.0)
            v = int(rng.integers(42, 138))
            if v < 72:
                c = (v, int(v * 0.97), int(v * 0.92))
            else:
                c = (min(255, int(v * 1.05)), int(v * 0.995), int(v * 0.90))
            _wrap_ellipse(drgb, x, y, r, ry, c, w, h)
            _wrap_ellipse(da, x, y, r, ry, min(255, int(v * 1.8)), w, h)
    return mask, edge, rgb, agg


def _make_cracks(rng, size):
    w = h = size
    img = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(img)
    polylines = []

    def grow(x, y, ang, steps, width, value, depth):
        pts = [(x, y)]
        for i in range(steps):
            ang += rng.uniform(-0.34, 0.34)
            step = rng.uniform(5.5, 14.0)
            x += math.cos(ang) * step
            y += math.sin(ang) * step
            pts.append((x, y))
            if depth < 2 and i > 2 and rng.random() < 0.055:
                grow(x, y, ang + rng.choice([-1.0, 1.0]) * rng.uniform(0.55, 1.15),
                     max(4, int(steps * 0.45)), max(1, width - 1),
                     int(value * 0.68), depth + 1)
        polylines.append((pts, width, value))

    for _ in range(11):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        grow(x, y, rng.uniform(0, math.tau), int(rng.integers(28, 62)),
             int(rng.integers(1, 3)), int(rng.integers(190, 255)), 0)
    for pts, width, value in polylines:
        _draw_wrapped_line(d, pts, value, width, w, h)
    return img


def make_concrete(size=SIZE):
    w = h = size
    rng = np.random.default_rng(7071)

    print("Generating weathered concrete PBR textures...")

    macro = fbm(h, w, 5, 2, 0.64, seed=7101)
    mid = fbm(h, w, 6, 5, 0.55, seed=7102)
    patch = fbm(h, w, 5, 3, 0.60, seed=7103)
    cement = fbm(h, w, 5, 9, 0.58, seed=7104)
    aggregate = fbm(h, w, 6, 120, 0.52, seed=7105)
    micro = fbm(h, w, 5, 360, 0.50, seed=7106)
    fine = fbm(h, w, 7, 28, 0.55, seed=7107)

    # Aggregate, not blotches. Real concrete varies mostly at the aggregate
    # scale inside a 1.2 m tile; the low-frequency terms used to dominate and
    # made the wall look like camouflage once the contrast was stretched.
    tone = (0.335
            + (macro - 0.5) * 0.080
            + (mid - 0.5) * 0.045
            + (cement - 0.5) * 0.038
            + (aggregate - 0.5) * 0.080
            + (micro - 0.5) * 0.045)
    albedo = np.stack([tone * 1.012, tone * 0.998, tone * 0.966], axis=-1)
    del tone

    pale = curve(patch, 0.56, 0.83) * 0.28
    albedo = overlay(albedo, (0.445, 0.438, 0.420), pale)
    del pale

    grime = curve(1.0 - patch, 0.55, 0.84) * 0.24
    albedo = overlay(albedo, (0.255, 0.258, 0.255), grime)
    del grime

    mottle = curve(cement, 0.42, 0.72) * 0.20
    albedo = overlay(albedo, (0.375, 0.370, 0.356), mottle)
    del mottle

    grains = curve(aggregate, 0.58, 0.79) * 0.44
    albedo = overlay(albedo, (0.455, 0.448, 0.430), grains)
    del grains
    dark_grains = curve(1.0 - aggregate, 0.63, 0.84) * 0.44
    albedo = overlay(albedo, (0.252, 0.251, 0.246), dark_grains)
    del dark_grains

    height = (0.46
              + (macro - 0.5) * 0.20
              + (mid - 0.5) * 0.10
              + (cement - 0.5) * 0.035
              + (fine - 0.5) * 0.055
              + (aggregate - 0.5) * 0.040)
    rough = (0.902
             + (fine - 0.5) * 0.060
             + (aggregate - 0.5) * 0.045
             + (micro - 0.5) * 0.030)
    del macro, mid, patch, cement, aggregate, micro, fine

    light_layer, dark_layer = _make_speckle(rng, size)
    speck_light = _mask(light_layer, 0.20)
    speck_dark = _mask(dark_layer, 0.20)
    del light_layer, dark_layer
    albedo = overlay(albedo, (0.465, 0.457, 0.438), speck_light * 0.42)
    albedo = overlay(albedo, (0.250, 0.250, 0.245), speck_dark * 0.42)
    del speck_light, speck_dark

    pit_layer = _make_pits(rng, size, 760, 1.2, 6.5, 55, 205)
    pit_draw = ImageDraw.Draw(pit_layer)
    for _ in range(170):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.uniform(5.0, 13.0)
        _wrap_ellipse(pit_draw, x, y, r, r * rng.uniform(0.6, 1.0),
                      int(rng.integers(45, 135)), w, h)
    pits = _mask(pit_layer, 0.35)
    del pit_layer, pit_draw
    core_layer, rim_layer = _make_bubbles(rng, size)
    bubble_core = _mask(core_layer, 0.30)
    bubble_rim = _mask(rim_layer, 0.30)
    del core_layer, rim_layer

    albedo = overlay(albedo, (0.460, 0.455, 0.442), bubble_rim * 0.52)
    albedo *= (1.0 - 0.40 * pits)[..., None]
    albedo *= (1.0 - 0.42 * bubble_core)[..., None]

    chip_mask_img, chip_edge_img, chip_rgb, chip_agg_img = _make_chips(rng, size)
    chip_mask = _mask(chip_mask_img, 0.7)
    chip_edge = _mask(chip_edge_img, 0.55)
    chip_agg = _mask(chip_agg_img, 0.45)
    del chip_mask_img, chip_edge_img, chip_agg_img
    chip_arr = np.asarray(chip_rgb, dtype=np.float32) / 255.0
    del chip_rgb
    albedo = albedo * (1.0 - chip_mask[..., None]) + chip_arr * chip_mask[..., None]
    del chip_arr
    albedo *= (1.0 - 0.32 * chip_edge)[..., None]

    # Damp patches, not runoff. Anisotropic streaks running down every tile read
    # as "stretched texture" once the map is repeated up a 3 m wall, so the wet
    # layer is built from isotropic blobs with only a whisper of vertical bias.
    blob = fbm(h, w, 5, 4, 0.62, seed=7111)
    fine_wet = fbm(h, w, 6, 10, 0.55, seed=7112)
    stain = fbm(h, w, 5, 4, 0.62, seed=7113)
    wet = curve(blob, 0.52, 0.74)
    del blob
    wet *= 0.35 + 0.65 * curve(fine_wet, 0.42, 0.68)
    del fine_wet
    wet *= 0.70 + 0.60 * curve(stain, 0.34, 0.68)
    del stain
    wet = np.clip(wet * 1.05, 0.0, 1.0)
    albedo *= (1.0 - 0.34 * wet)[..., None]

    # No bottom-of-tile moss gradient: it repeats once per 1.2 m of wall and shows
    # up as a horizontal green stripe. Moss is now a sparse isotropic patch that
    # could equally sit anywhere on the surface.
    moss_fine = fbm(h, w, 6, 9, 0.56, seed=7114)
    moss_patch = fbm(h, w, 4, 3, 0.60, seed=7115)
    moss_noise = 0.55 * moss_fine + 0.45 * moss_patch
    del moss_fine, moss_patch
    moss = curve(moss_noise, 0.62, 0.84)
    moss_detail = curve(fbm(h, w, 7, 34, 0.52, seed=7116), 0.4, 0.7)
    moss *= 0.72 + 0.28 * moss_detail
    del moss_detail
    moss = np.clip(moss * 0.95, 0.0, 1.0)
    albedo = overlay(albedo, (0.205, 0.225, 0.175), moss * 0.85)

    # A 2048 map with std 7.5/255 reads as flat grey paint once it is lit by a
    # torch. Stretch the tonal range around the mean before the maps are saved.
    albedo = np.clip(0.335 + (albedo - 0.335) * 1.85, 0.055, 0.80)

    crack_layer = _make_cracks(rng, size)
    cracks = _mask(crack_layer, 0.3)
    del crack_layer
    albedo *= (1.0 - 0.58 * cracks)[..., None]

    albedo = np.clip(albedo, 0.25, 0.55)

    height -= 0.22 * pits
    height -= 0.13 * bubble_core
    height += 0.045 * bubble_rim
    height -= 0.30 * chip_mask
    height += 0.22 * chip_agg * chip_mask
    height -= 0.055 * chip_edge
    height -= 0.17 * cracks
    height -= 0.018 * moss

    rough -= 0.205 * wet
    rough -= 0.115 * moss
    rough -= 0.050 * pits
    rough -= 0.035 * bubble_core
    rough += 0.045 * chip_mask
    rough += 0.020 * chip_agg * chip_mask
    rough = np.clip(rough, 0.64, 0.96)

    del pits, bubble_core, bubble_rim, chip_mask, chip_edge, chip_agg, cracks, moss, wet

    pad = 8
    hp = np.pad(np.clip(height, 0.0, 1.0), ((pad, pad), (pad, pad)), mode="wrap")
    # 4.6 left the surface reading as flat paint (median tilt 0.3 deg).
    # Concrete at 1.2 m per tile needs visible aggregate relief.
    normal = normal_map(hp, strength=11.0)
    normal = normal[pad:pad + h, pad:pad + w]

    save_rgb(albedo * 255.0, "stone_albedo.png")
    save_rgb(normal, "stone_normal.png")
    save_gray(rough, "stone_rough.png")

    mean255 = albedo.mean(axis=(0, 1)) * 255.0
    print("  albedo mean RGB:", np.round(mean255, 1))
    print("  albedo range:", np.round(albedo.min(), 3), "-", np.round(albedo.max(), 3))
    print("  roughness range:", np.round(rough.min(), 3), "-", np.round(rough.max(), 3))
    print("done.")


if __name__ == "__main__":
    os.makedirs(TEX, exist_ok=True)
    make_concrete()
