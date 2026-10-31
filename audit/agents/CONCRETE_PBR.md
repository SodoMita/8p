# Concrete / stone PBR audit

**Snapshot (current working tree, 2026-10-31 16:48:07 UTC)**
- `scripts/map_builder.gd` sha256 `bdee8276…c8fc` — changed during this review; current version uses triplanar. Pre-16:48 values are in §2.3.
- `tools/gen_concrete.py` sha256 `471db3c6…8e70`; `assets/textures/stone_albedo.png` 2048×2048 RGB sha256 `e0605153…b8ee`.
- Only `_mats["stone"]` and `_mats["concrete"]` use the stone maps (`map_builder.gd:139-140`). Both load `stone_albedo/normal/rough`.

---

## 1. Generated maps

| Map | Resolution | Construction | Directional streaks | Tiling seam |
|---|---|---|---|---|
| `stone_albedo.png` | 2048² RGB | fbm stack: macro 5oct/base2, mid 6/5, patch 5/3, cement 5/9, aggregate 6/120, micro 5/360, fine 7/28 (`gen_concrete.py:205-219`); overlays for pale/grime/mottle/grain (`:222-239`); 23,500 speckles, 930 pits, 2,100 bubbles, 3 chips (r85-155 px), 11 crack polylines w1-3 px (`:253-320`); vertical water streaks (`:290-300`); moss bottom band (`:302-315`) | **Yes, vertical** (`mean|dx|/mean|dy| = 1.375`) | None hard. Edge Δ 1.0/1.9 8-bit levels; 0.4%/1.3% of edge pixels > interior p99 |
| `stone_normal.png` | 2048² RGB | height = 0.46 + macro·0.20 + mid·0.10 + cement·0.035 + fine·0.055 + aggregate·0.040, minus pits 0.22, bubble core 0.13, chip mask 0.30, cracks 0.17; `normal_map(strength=4.6)`, wrap-padded 8 px (`:241-250,343-346`) | No (`dx/dy = 0.928`) | None hard. Edge Δ 0.95/2.71 levels; below interior mean |
| `stone_rough.png` | 2048² L | 0.902 + fine·0.060 + aggregate·0.045 + micro·0.030, minus wet 0.205, moss 0.115, pits 0.050, bubble core 0.035, plus chips; clipped 0.64-0.96 (`:247-250,333-339`) | **Strong vertical** (`dx/dy = 2.98`) | None hard. Edge Δ 2.25/2.25 levels (21.9% > p99 but absolute ≤3/255) |

**Resolution/order:** `gen_concrete.py:26` `SIZE=2048`, writes the three maps at `:348-350`. `gen_textures_real.py:217` `make_stone(size=1024)` writes the **same filenames**; `tools/regen_all.sh:30` runs `gen_concrete.py` last, so on-disk is 2048. Running `gen_textures_real.py` alone silently downgrades stone to 1024. `gen_assets.py:127` also writes an unused 512² `stone.png`.

**Seams:** no hard seam. All primitives wrap: fbm value-noise grids (`gen_textures_real.py:20-38`), anisotropic grids (`:41-48`), ellipses/lines/polygons (`gen_concrete.py:35-67`), normal wrap-pad (`:343-346`). Repetition is the real issue: the moss band is a bottom-of-tile Y gradient (`gen_concrete.py:302-315`; `gen_textures_real.py:232-236`), so it repeats every tile — at the current 1.2 m repeat that is a horizontal moss stripe every 1.2 m up a wall.

**Realism metrics (actual PNGs):** albedo mean RGB **80.1/79.1/76.5** (sRGB 8-bit), std **9.4/9.1/8.4** → ~0.078 linear, very dark/low contrast. Roughness mean **0.861**, std **0.058**, range 0.639-0.957 (flat). Normal map mean **127.5/127.4/254.9**, XY std **4.4/4.7**; normal perturbation mean **1.0°**, median **0.3°**, p99 **16.4°**, max 36.3° (mostly flat; relief only in sparse pits/cracks).

---

## 2. Materials in `scripts/map_builder.gd`

### 2.1 Current state (16:48 snapshot)
- `map_builder.gd:113-127` `_triplanar()`: `uv1_triplanar = true`, `uv1_world_triplanar = true`, `uv1_scale = Vector3.ONE / metres_per_repeat`, repeat, `LINEAR_WITH_MIPMAPS_ANISOTROPIC`.
- `map_builder.gd:139` `_mats["stone"] = _triplanar("stone", 1.2, 0.95, 1.0)`
- `map_builder.gd:140` `_mats["concrete"] = _triplanar("stone", 1.2, 1.0, 0.85)`
- **Current density = 2048 / 1.2 = 1706.7 px/m** on every axis, every face, every landmark scale (`s = 0.88-1.22`, `:366,403`). Variation **0%**. No single stretched copy.
- `normal_scale`: stone 1.0, concrete 0.85.

### 2.2 Every current stone/concrete surface
All rows below are **1706.7 px/m in both axes** because of world triplanar; none is >30% off the others.

| Surface / `map_builder.gd` line | Mesh | Real size (m) | Current px/m | Flag |
|---|---|---|---|---|
| Concrete walls long 513/514 | BoxMesh | 5.6-8.4 × 2.3-3.3 × 0.32 | 1706.7 | none |
| Concrete walls short 515/516 | BoxMesh | 0.32 × 2.3-3.3 × 5.6-9.6 | 1706.7 | none |
| Wall variant 518 | BoxMesh | 4.8-7.2 × 2.116-3.036 × 0.3 | 1706.7 | none |
| Collapsed slab 521 | BoxMesh | 4.0 × 0.28 × 3.0 | 1706.7 | none |
| Rubble block 522 | BoxMesh | 1.6 × 0.35 × 1.2 | 1706.7 | none |
| Tunnel sides 529/530 | BoxMesh | 0.45 × 2.9-3.5 × 6.5-8.5 | 1706.7 | none |
| Tunnel ceiling 531 | BoxMesh | 4.85 × 0.45 × 6.5-8.5 | 1706.7 | none |
| Tunnel ends 533 | BoxMesh | 1.6-3.4 × 2.9-3.5 × 0.35 | 1706.7 | none |
| Tunnel ends 534 | BoxMesh | 1.4-3.0 × 2.465-2.975 × 0.35 | 1706.7 | none |
| Tunnel rubble 537-538 | BoxMesh | 0.4-1.2 × 0.32 × 0.4-1.0 (3-6×) | 1706.7 | none |
| Silo pad 547 | BoxMesh | 1.7 × 0.55 × 1.6 | 1706.7 | none |
| Rock pillars 598 | CylinderMesh, r0.45-0.75, h1.0-2.2, top0.55r, 16 seg, 2 rings, 7-11× | side 2.83-4.71 circumference × 1.0-2.2 | 1706.7 | none |
| Toppled stone 601 | BoxMesh | 1.5 × 0.8 × 0.9 | 1706.7 | none |
| Bathroom sides 609/610 | BoxMesh | 0.28 × 2.6-3.2 × 4.6-6.0 | 1706.7 | none |
| Bathroom back 611 | BoxMesh | 3.4-4.4 × 2.6-3.2 × 0.28 | 1706.7 | none |
| Bathroom front 615/617 | BoxMesh | 1.0 × 2.6-3.2 × 0.28 | 1706.7 | none |
| Bathroom front 616 | BoxMesh | 0.6 × 2.6-3.2 × 0.28 | 1706.7 | none |
| Stall dividers 620 | BoxMesh | 2.7-3.7 × 2.0 × 0.12 (2×) | 1706.7 | none |

Adjacent ground is **512 px/m** (1024 px ground map / 2.0 m repeat, `map_builder.gd:136`), **3.33× lower** than stone/concrete — a visible detail jump at wall bases.

### 2.3 Prior state (git HEAD / live before 16:48) — this is what looked stretched
BoxMesh in Godot 4.7 uses a **fixed 1/3 × 1/2 UV rect per face**, independent of size (verified by dumping `BoxMesh` arrays). With `uv1_scale = S`, repeats per face are `S/3 × S/2`; density = `682.67·S/W` × `1024·S/H`. Old values: stone `S=1.6`, concrete `S=1.45`, no triplanar (`git show HEAD:scripts/map_builder.gd:115-116`).

| Surface | Main-face size (m) | Old px/m (u × v) | Stretch |
|---|---|---|---|
| Walls long 513/514 | 5.6-8.4 × 2.3-3.3 | 117.8-176.8 × 449.9-645.6 | 2.55-5.48:1 |
| Walls short 515/516 | 6.4-9.6 × 2.3-3.3 | 103.1-152.3 × 449.9-645.6 | 2.95-6.26:1 |
| Wall variant 518 | 4.8-7.2 × 2.116-3.036 | 136.5-206.4 × 489.1-702.2 | 2.55-5.14:1 |
| Collapsed slab top 521 | 4.0 × 3.0 | 247.5 × 494.9 | 2.00:1 |
| Tunnel sides 529/530 | 6.5-8.5 × 2.9-3.5 | 116.5-152.3 × 424.2-512.0 | 2.79-4.40:1 |
| Tunnel ceiling bottom 531 | 4.85 × 6.5-8.5 | 204.1 × 174.7-228.5 | 0.86-1.12:1 (OK) |
| Silo pad top 547 | 1.7 × 1.6 | 582.3 × 928.0 | 1.59:1 |
| Bathroom sides 609/610 | 4.6-6.0 × 2.6-3.2 | 165.0-215.2 × 464.0-571.1 | 2.16-3.46:1 |
| Bathroom back 611 | 3.4-4.4 × 2.6-3.2 | 225.0-291.2 × 464.0-571.1 | 1.59-2.54:1 |
| Stall divider 620 | 2.7-3.7 × 2.0 | 267.5-366.7 × 742.4 | 2.03-2.78:1 |
| Rock pillar 598 side | 2.83-4.71 circ. × 1.0-2.2 | 695.4-1158.9 × 744.7-1638.4 | 0.64-2.36:1 |
| Toppled stone top 601 | 1.5 × 0.9 | 728.2 × 1820.4 | 2.50:1 |

Old main-face range **103-3535 px/m** (thin 0.12-0.35 m faces up to 12,373 px/m); walls 1.6-6.3:1 stretched. Each BoxMesh face sampled only **0.483 × 0.725 of one tile** (`S/3 × S/2`) — effectively a single stretched partial copy. Cylinder sides sampled half the tile vertically (`v 0-0.5`). This matches the reported look; the current triplanar patch removes it.

---

## 3. Recommended `uv1_scale`

With triplanar, `uv1_scale = 1 / metres_per_repeat`. Recommended target: **1024 px/m everywhere** (2048/2.0 m), which matches the ground at 1.0 m repeat and halves the 1.2 m macro/moss repetition.

| Surface | Current px/m | Recommended `uv1_scale` | Why |
|---|---|---|---|
| All concrete BoxMesh (513-620) | 1706.7 | **0.5** (2.0 m repeat → 1024 px/m) | 1.2 m tile repeats macro stains/moss every 1.2 m; 2.0 m halves it. 1024 px/m is still 6-10× the old wall density; 1 px = 0.98 mm so pits/cracks stay realistic. |
| Stone rock pillars 598 + toppled block 601 | 1706.7 | **0.5** (2.0 m → 1024 px/m) | Same value keeps stone/concrete identical (0% variance); 2.0 m still shows 0.25-0.75 tile across a 0.9-1.5 m rock, so no visible repeat. |
| Ground (adjacent, not stone) | 512 | **1.0** (1.0 m → 1024 px/m) | Removes the 3.33× density jump at wall/ground junctions. |
| If you accept 1.2 m tiling | 1706.7 | 0.8333 (keep current) | Current density is uniform and sharp; only the 1.2 m repetition argues for 0.5. Do not go below 0.8333 without also fixing the moss band. |

Do **not** try to fix BoxMesh with a larger scalar `uv1_scale` alone: its per-face UV rect is fixed at 1/3 × 1/2, so one scalar cannot equalize a 8.4 m wall and a 0.32 m edge. Triplanar (or world-space UVs) is required.

---

## 4. Remaining concrete defects (current state)

1. **Mipmaps disabled** — `assets/textures/stone_albedo.png.import`, `stone_normal.png.import`, `stone_rough.png.import` all have `mipmaps/generate=false`, while the material requests `LINEAR_WITH_MIPMAPS_ANISOTROPIC`. At 1706.7 px/m this aliases/shimmer at >2 m and reads as low-res. Fix: set `mipmaps/generate=true` in all three and reimport.
2. **Normal map not flagged as normal** — `stone_normal.png.import` has `compress/normal_map=0` and `detect_3d/compress_to=1`; a 3D-triggered VRAM reimport can use generic compression and damage the normals. Fix: `compress/normal_map=1` (or `detect_3d/compress_to=0`).
3. **Weak relief** — measured normal perturbation median 0.3°, mean 1.0°, p99 16.4°; concrete `normal_scale` is 0.85 (`map_builder.gd:140`). Fix: `gen_concrete.py:345` strength 4.6 → 8-10 and/or increase pit/chip/crack height deltas; set concrete `normal_scale` 0.85 → 1.2.
4. **Periodic moss band** — `gen_concrete.py:302-315` (`env` peaks at yy=0.88) and `gen_textures_real.py:232-236`; repeats every tile. Fix: remove the Y-gradient and use a 2D fbm moss mask only, or cut the overlay weight from 0.85 to ≤0.3.
5. **Albedo dark/low contrast** — mean 80/79/76 sRGB, std 9/255, ~0.078 linear. Fix: gamma-encode before `save_rgb` (or raise base tone 0.335 → 0.48-0.55) and add macro contrast.
6. **Roughness flat** — mean 0.861, std 0.058. Fix: widen the wet/dry range (≈0.45-0.95) and lower the 0.902 base.
7. **Vertical streaks on horizontal faces** — the anisotropic streaks are vertical in texture space; under triplanar's Y projection they lie horizontally across slab/pad tops. Fix: separate floor material with rotated UVs, or reduce streak weight for the top projection.
8. **Patch is uncommitted** — `git status` shows `scripts/map_builder.gd` modified. If the build reverts to HEAD, the old 103-3535 px/m stretched version returns. Commit the triplanar patch.
