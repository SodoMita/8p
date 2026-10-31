# Cloth + endless terrain audit

Read-only review. Verified against Godot 4.7.2 (`/home/user/tools/Godot_v4.7.2-stable_linux.x86_64`).

---

## 1. `scripts/page_cloth.gd` (8 sheets, 7x9 verts each)

### C1 — Normal smoothing sign is opposite the triangle winding (lighting inverted)
`page_cloth.gd:150` (with `:145`, `:171-176`)

```gdscript
n := (_pos[i + 1] - a).cross(_pos[i + COLS] - a)   # +X x -Y = -Z
```

Indices wind `(i, i+COLS, i+1)` -> winding normal `+Z`. `normals.fill(Vector3.BACK)` seeds `+Z`, then `-Z` contributions cancel it; a flat sheet ends with normal `-Z` (confirmed on 4.7.2). Result: the `+Z` face is lit as if facing `-Z`; the page only shows emission.

```gdscript
# :150
var n := (_pos[i + COLS] - a).cross(_pos[i + 1] - a)
```

### C2 — Mesh rebuilt every rendered frame, even when no sim step ran
`page_cloth.gd:88-94`, `:183-184`

`_rebuild()` runs unconditionally after the fixed-step loop. At >60 fps most frames do zero simulation but still do `clear_surfaces()` + `add_surface_from_arrays()` (GPU buffer realloc) for all 8 sheets = 8 surface re-creations/frame.

```gdscript
# :88-94
func _process(delta: float) -> void:
	_acc += minf(delta, 0.05)
	var stepped := false
	while _acc >= FIXED_STEP:
		_acc -= FIXED_STEP
		_t += FIXED_STEP
		_simulate(FIXED_STEP)
		stepped = true
	if stepped:
		_rebuild()
```

### C3 — Wall clamp desyncs `_prev`, injecting energy
`page_cloth.gd:136-137` (vs `_prev[i] = cur` at `:110`)

The clamp edits `_pos` after `_prev` was written, so the clamp delta is read back as velocity next step (z buzz / overshoot). Fold the correction into `_prev` instead:

```gdscript
for i in _pos.size():
	var z := clampf(_pos[i].z, -0.14, 0.14)
	if z != _pos[i].z:
		_prev[i].z += z - _pos[i].z   # keep velocity, drop only the position error
		_pos[i].z = z
```

### C4 — `_rebuild()` allocates four new packed arrays per call
`page_cloth.gd:143-160`, `:158-160`

`normals/verts/uvs/indices` are reallocated and UVs/indices refilled every call. Cache them as members, resize once in `_build()`, fill UVs/indices once, then only overwrite `verts`/`normals` per rebuild.

```gdscript
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
# _build(): resize/fill _uvs,_indices once
# _rebuild(): _normals.fill(...); ...; _verts[i] = _pos[i]; (reuse arrays)
```

### C5 — `_pinned.has()` is a linear scan inside the solver loop
`page_cloth.gd:105`, `:124-125`

Pinned set is 7 ints, but this is called ~`3 passes x 206 links x 2` = ~1236 scans per sheet per step. Cache flags once in `_build()`:

```gdscript
var _is_pinned := PackedByteArray()
# _build(): _is_pinned.resize(COLS*ROWS); if r == 0: _is_pinned[i] = 1
# integration:  if _is_pinned[i] == 1: continue
# solver:       var pinned_a := _is_pinned[a] == 1
#               var pinned_b := _is_pinned[b] == 1
```

### Verified correct (not bugs)
- Constraint correction sign `:123-134`: `d = pb-pa`, `diff=(dist-rest)/dist`; pinned branches and the 0.5 split shorten stretched / lengthen compressed links correctly.
- Packed sub-assignment `_pos[i].z = ...` at `:137` persists on 4.7.2 (not a no-op).

---

## 2. `scripts/endless_terrain.gd`

### T1 — 4000 m floor slab is exactly coplanar with the arena ground collider
`endless_terrain.gd:88-96` vs `scripts/map_builder.gd:209-217`

WorldFloor: size.y 2.0 at y=-1.0 -> top **y=0**. Arena `GroundCollision`: size.y 1.0 at y=-0.5 -> top **y=0**. Two StaticBody boxes overlap across the whole 150x150 arena -> duplicate contacts/jitter. Drop the slab 2 cm so it sits below the arena and flush with the chunk visual ground (`:192` uses y=-0.02):

```gdscript
# :94
cs.position = Vector3(0, -1.02, 0)   # top at -0.02, under arena top (0)
```

(Alternative: four slabs outside +-61 instead of one 4000 m slab.)

### T2 — Trees spawn inside the fenced arena in boundary-straddling chunks
`endless_terrain.gd:179-181`, `:236-240`

`_chunk_inside_arena()` only skips a chunk if it is *entirely* inside +-60. A 32 m chunk such as x=32..64 is generated, so its trees land inside the +-61 arena (overlap strip). Also the test uses 60 while the fence is at 61 (`map_builder.gd:223`). Reject per instance:

```gdscript
# in the placement loop, right after p is computed (:206)
if absf(p.x) <= 62.0 and absf(p.z) <= 62.0:
	continue
```

### T3 — Road-clear rejection uses a fake road path, so trees spawn on the road
`endless_terrain.gd:208`, `:243-248`

`_road_z_at()` returns `sin((x-gate)*0.012)*9` (max +-9 m), but the real road (`:109-121`) is a seeded random walk. With seed 20261031 it reaches **z≈158 m**; max `|actual_z - _road_z_at|` ≈ **158 m**. Trees are placed directly on the road. Keep the real polyline and test segment distance:

```gdscript
var _road_pts := PackedVector3Array()   # member
# _build_road(): _road_pts = pts         # after RoadRibbon.build

func _road_dist(p: Vector3) -> float:
	var best := 1e9
	for i in _road_pts.size() - 1:
		var a := _road_pts[i]
		var ab := Vector2(_road_pts[i + 1].x - a.x, _road_pts[i + 1].z - a.z)
		var ap := Vector2(p.x - a.x, p.z - a.z)
		var t := clampf(ap.dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		best = minf(best, ap.distance_to(ab * t))
	return best

# replace :208
if _road_dist(p) < 3.4:
	continue
```

### T4 — Chunk ground planes overlap by 0.5 m at the same height -> seam z-fighting
`endless_terrain.gd:185`, `:192`

`PlaneMesh.size = CHUNK + 0.5` centred on each chunk means adjacent planes overlap 0.5 m, all at y=-0.02. Fix to exact size; shared edges already coincide from the same origin math:

```gdscript
# :185
plane.size = Vector2(CHUNK, CHUNK)
```

### T5 — `clear_chunks()` leaves `_last_key` stale, so the world never repopulates
`endless_terrain.gd:265-268` (with `:139-142`)

After clearing, `_process` still sees `key == _last_key` and never calls `_update_chunks()` again. Reset the sentinel:

```gdscript
func clear_chunks() -> void:
	for n in _chunks.values():
		n.queue_free()
	_chunks.clear()
	_last_key = Vector2i(999999, 999999)
```

### Verified correct (not bugs)
- Chunk address math `:149-150` uses `floor`, not `int()` truncation; negative coordinates map correctly.
- Far chunks are freed: `:161-165` iterates a copy of `keys()` (verified 4.7.2) and `queue_free()` runs, so `_chunks` and memory stay bounded (~`(2*_view+1)^2`).
