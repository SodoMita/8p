extends Node3D
## Procedural dead forest.
##
## Every run is different:
##   * the eight landmarks are scattered over the map with random positions,
##     rotations, scales and one of several layout variants each,
##   * pages sit at a random spot around their landmark (never inside geometry),
##   * trees, snags, logs, stumps, shrubs, grass and ground detail are all
##     seeded from the run seed.
##
## Nothing here uses fixed coordinates, so the layout can never repeat.

const HALF := 60.0
const TREES_DESKTOP := 620
const TREES_MOBILE := 430
const DEAD_TREE_MESHES := 6
const SNAG_MESHES := 2
const PUMPKIN_MESHES := 3
const BUSH_MESHES := 3
const LAB_CELLS := 8
const LAB_CELL := 2.75
const LAB_WALL_THICK := 0.36
const LAB_HALF := LAB_CELLS * LAB_CELL * 0.5  # 11.0 m (22 x 22 m footprint)

signal built

var rng := RandomNumberGenerator.new()
var page_spots: Array[Dictionary] = []
var tree_positions: PackedVector3Array = PackedVector3Array()
var landmarks: Array[Dictionary] = []
var labyrinth: Dictionary = {}
var world_seed := 0

var _mats := {}
var _noise := FastNoiseLite.new()
var _density := FastNoiseLite.new()
var _tree_count := 0
var _occupied: Array[Dictionary] = []
var _placed_spacing: Array[float] = []
var _tree_meshes: Array[Mesh] = []
var _pumpkin_meshes: Array[Mesh] = []
var _bush_meshes: Array[Mesh] = []
var _snag_meshes: Array[Mesh] = []
var _props := {}
var _lab_built := false
var _lab_xf := Transform3D.IDENTITY
var _lab_inv_xf := Transform3D.IDENTITY
var _lab_wall_rects: Array[Rect2] = []
var _lab_h_wall: Array = []
var _lab_v_wall: Array = []


# --------------------------------------------------------------------------- #
# build
# --------------------------------------------------------------------------- #
func build(seed_value: int, quality: int) -> void:
	world_seed = seed_value
	rng.seed = seed_value
	_noise.seed = seed_value
	_noise.frequency = 0.018
	_noise.fractal_octaves = 3
	_density.seed = seed_value + 7
	_density.frequency = 0.045
	_density.fractal_octaves = 2

	_load_meshes()
	_make_materials()
	_ground()
	_place_landmarks(quality)
	_forest(TREES_DESKTOP if quality >= 1 else TREES_MOBILE, quality)
	_undergrowth(quality)
	_pumpkins_and_bushes(quality)
	_ground_detail(quality)
	_boundary()
	built.emit()


func _load_meshes() -> void:
	for i in DEAD_TREE_MESHES:
		var m: Mesh = load("res://assets/models/tree_%d.res" % i)
		if m != null:
			_tree_meshes.append(m)
	for i in SNAG_MESHES:
		var m: Mesh = load("res://assets/models/snag_%d.res" % i)
		if m != null:
			_snag_meshes.append(m)
	for key in ["log", "stump", "shrub"]:
		var m: Mesh = load("res://assets/models/%s_0.res" % key)
		if m != null:
			_props[key] = m
	# pumpkins and bushes come in per-variant meshes, picked per instance
	for i in PUMPKIN_MESHES:
		var pm: Mesh = load("res://assets/models/pumpkin_%d.res" % i)
		if pm != null:
			_pumpkin_meshes.append(pm)
	for i in BUSH_MESHES:
		var bm: Mesh = load("res://assets/models/bush_%d.res" % i)
		if bm != null:
			_bush_meshes.append(bm)


# --------------------------------------------------------------------------- #
# materials — albedo + normal + roughness (PBR), shared across instances
# --------------------------------------------------------------------------- #
func _pbr(name: String, uv_scale := 1.0, rough := 1.0, normal_scale := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/%s_albedo.png" % name)
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/%s_normal.png" % name)
	m.normal_scale = normal_scale
	m.roughness_texture = load("res://assets/textures/%s_rough.png" % name)
	m.roughness = rough
	m.metallic = 0.0
	m.metallic_specular = 0.35
	m.uv1_scale = Vector3(uv_scale, uv_scale, 1.0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.texture_repeat = true
	return m


func _make_materials() -> void:
	# trees use world-space UVs baked in the mesh generator, so scale 1
	_mats["bark"] = _pbr("bark", 1.0, 1.0, 1.15)
	_mats["bark_coll"] = _mats["bark"]
	_mats["ground"] = _pbr("ground", 26.0, 1.0, 1.0)
	_mats["stone"] = _pbr("stone", 1.6, 0.95, 1.0)
	_mats["concrete"] = _pbr("stone", 1.45, 1.0, 0.85)
	_mats["lab_wall"] = _pbr("stone", 1.0, 0.96, 1.3)
	_mats["lab_floor"] = _pbr("stone", 1.0, 0.98, 1.1)
	_mats["metal"] = _flat(Color(0.13, 0.135, 0.14), 0.42, 0.65)
	_mats["rust"] = _flat(Color(0.30, 0.17, 0.10), 0.85, 0.3)
	_mats["dark"] = _flat(Color(0.022, 0.022, 0.025), 0.95, 0.0)
	_mats["wood"] = _pbr("bark", 1.0, 1.0, 1.0)
	_mats["pumpkin"] = _pbr("pumpkin", 1.0, 1.0, 1.35)
	_mats["fabric"] = _flat(Color(0.16, 0.15, 0.13), 1.0, 0.0)

	var grass := StandardMaterial3D.new()
	grass.albedo_texture = load("res://assets/textures/grass.png")
	grass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	grass.alpha_scissor_threshold = 0.42
	grass.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	grass.cull_mode = BaseMaterial3D.CULL_DISABLED
	grass.roughness = 1.0
	grass.metallic = 0.0
	grass.vertex_color_use_as_albedo = true
	grass.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_mats["grass"] = grass

	var litter := StandardMaterial3D.new()
	litter.albedo_texture = load("res://assets/textures/litter.png")
	litter.albedo_color = Color(0.5, 0.45, 0.38)
	litter.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	litter.alpha_scissor_threshold = 0.28
	litter.cull_mode = BaseMaterial3D.CULL_DISABLED
	litter.vertex_color_use_as_albedo = true
	litter.roughness = 1.0
	_mats["litter"] = litter

	for key in ["bark", "wood", "lab_wall", "lab_floor"]:
		_mats[key].vertex_color_use_as_albedo = true


func _flat(color: Color, rough := 0.8, metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metallic
	m.metallic_specular = 0.4
	return m


# --------------------------------------------------------------------------- #
# ground
# --------------------------------------------------------------------------- #
func _ground() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(150, 150)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = _mats["ground"]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	var floor_body := StaticBody3D.new()
	floor_body.name = "GroundCollision"
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(150, 1, 150)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	add_child(floor_body)


func _boundary() -> void:
	# invisible square fence so you cannot leave the forest
	var fence := StaticBody3D.new()
	fence.name = "BoundaryFence"
	var span := (HALF + 1.0) * 2.0
	for i in 4:
		var shape := BoxShape3D.new()
		shape.size = Vector3(span, 24.0, 1.0)
		var col := CollisionShape3D.new()
		col.shape = shape
		var ang := TAU * float(i) / 4.0
		col.position = Vector3(cos(ang), 6.0, sin(ang)) * (HALF + 1.0)
		# thin axis must point radially outward, long axis along the edge
		col.rotation.y = PI / 2.0 - ang
		fence.add_child(col)
	add_child(fence)


# --------------------------------------------------------------------------- #
# landmark placement — fully randomised
# --------------------------------------------------------------------------- #
func _place_landmarks(_quality: int) -> void:
	# 1) Place the procedural stone labyrinth first so it gets clean ground
	#    well clear of both the central spawn clearing and the outer fence.
	var lab_ang := rng.randf() * TAU
	var lab_dist := rng.randf_range(30.0, 40.5)
	var lab_pos := Vector3(cos(lab_ang) * lab_dist, 0.0, sin(lab_ang) * lab_dist)
	var lab_rot := float(rng.randi_range(0, 3)) * (PI * 0.5) + rng.randf_range(-0.045, 0.045)
	_build_landmark("labyrinth", lab_pos, lab_rot, 1.0)
	_occupied.append({"pos": lab_pos, "radius": 15.5})
	_placed_spacing.append(28.0)

	# 2) Scatter the remaining seven set pieces around the forest.
	var types := ["tunnel", "silo", "truck", "shed", "rocks", "bathroom", "tower"]
	_shuffle(types)
	var placed := 0
	var tries := 0
	# progressively relax spacing if the map gets crowded, so all eight always fit
	while placed < types.size() and tries < 7000:
		tries += 1
		var spacing := 29.0 if tries < 1400 else (26.0 if tries < 3200 else 23.0)
		var lab_gap := 27.5 if tries < 3200 else 25.0
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(19.0, HALF - 13.0)
		var pos := Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		if Vector2(pos.x, pos.z).length() < 14.0:
			continue
		if _overlaps_landmarks(pos, spacing, lab_gap):
			continue
		var rot := rng.randf() * TAU
		var scale := rng.randf_range(0.88, 1.22)
		var type: String = types[placed]
		_build_landmark(type, pos, rot, scale)
		_occupied.append({"pos": pos, "radius": spacing * 0.5})
		_placed_spacing.append(spacing)
		placed += 1
	if placed < types.size():
		push_warning("map_builder: only placed %d/8 landmarks" % (placed + 1))


func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func _overlaps(pos: Vector3, radius: float) -> bool:
	for o in _occupied:
		if Vector2(pos.x - o["pos"].x, o["pos"].z - pos.z).length() < radius + float(o["radius"]):
			return true
	return false


## circular spacing keeps genuinely wide corridors between landmarks
## (a square test would still allow diagonal neighbours to sit too close)
func _overlaps_landmarks(pos: Vector3, spacing: float, lab_spacing: float) -> bool:
	for l in landmarks:
		var lp: Vector3 = l["pos"]
		var need := lab_spacing if l["name"] == "labyrinth" else spacing
		if Vector2(pos.x - lp.x, pos.z - lp.z).length() < need:
			return true
	return false


func _build_landmark(type: String, base: Vector3, rot: float, s: float) -> void:
	# all local geometry is rotated by `rot` and uniformly scaled by `s`
	var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3(s, s, s)), base)
	if type == "labyrinth":
		_labyrinth(xf, base, rot)
		return
	match type:
		"walls": _concrete_walls(xf)
		"tunnel": _tunnel(xf)
		"silo": _silo(xf)
		"truck": _truck(xf)
		"shed": _shed(xf)
		"rocks": _rock_circle(xf)
		"bathroom": _bathroom(xf)
		"tower": _tower(xf)
	var radius := 13.0 * s
	landmarks.append({"name": type, "pos": base, "radius": radius, "rot": rot, "scale": s})
	_add_page_spot(type, xf)


func _add_page_spot(type: String, xf: Transform3D) -> void:
	# candidate offsets in landmark-local space; pick one that is clear
	var candidates := [
		Vector3(0, 0, 5.0), Vector3(3.0, 0, 4.0), Vector3(-3.0, 0, 4.0),
		Vector3(5.0, 0, 0.0), Vector3(-5.0, 0, -1.0), Vector3(0, 0, -5.0),
		Vector3(4.0, 0, -4.0), Vector3(-4.0, 0, -4.5),
		Vector3(0, 0, 6.8), Vector3(0, 0, -6.8), Vector3(6.8, 0, 0.0), Vector3(-6.8, 0, 0.0),
	]
	_shuffle(candidates)
	for c in candidates:
		var world: Vector3 = xf * c
		if Vector2(world.x, world.z).length() > HALF - 6.0:
			continue
		if _point_inside_prop(world):
			continue
		page_spots.append({"pos": world, "name": type})
		return
	page_spots.append({"pos": xf * Vector3(0, 0, 6.5), "name": type})


# --------------------------------------------------------------------------- #
# primitives (local-to-landmark transforms)
# --------------------------------------------------------------------------- #
func _box(xf: Transform3D, pos: Vector3, size: Vector3, mat: Material, rot := Vector3.ZERO, collide := true) -> Node3D:
	var root: Node3D
	if collide:
		root = StaticBody3D.new()
	else:
		root = Node3D.new()
	var t := xf * Transform3D(Basis.from_euler(rot), pos)
	root.transform = t
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	root.add_child(mi)
	if collide:
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		col.shape = shape
		root.add_child(col)
	add_child(root)
	if collide:
		_occupied.append({"pos": t.origin, "radius": size.length() * 0.35, "prop": true})
	return root


func _cyl(xf: Transform3D, pos: Vector3, radius: float, height: float, mat: Material, top := -1.0, collide := true) -> Node3D:
	var root: Node3D
	if collide:
		root = StaticBody3D.new()
	else:
		root = Node3D.new()
	var t := xf * Transform3D(Basis(), pos)
	root.transform = t
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.bottom_radius = radius
	cyl.top_radius = radius if top < 0.0 else top
	cyl.height = height
	cyl.radial_segments = 16
	cyl.rings = 2
	mi.mesh = cyl
	mi.material_override = mat
	root.add_child(mi)
	if collide:
		var col := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = radius
		shape.height = height
		col.shape = shape
		root.add_child(col)
		_occupied.append({"pos": t.origin, "radius": radius + 1.0, "prop": true})
	add_child(root)
	return root


func _point_inside_prop(p: Vector3) -> bool:
	if point_in_labyrinth_wall(p, 0.45):
		return true
	for o in _occupied:
		if o.get("prop", false) and Vector2(p.x - o["pos"].x, p.z - o["pos"].z).length() < float(o["radius"]) + 0.8:
			return true
	return false


# --------------------------------------------------------------------------- #
# procedural stone labyrinth + spatial reverb zone
# --------------------------------------------------------------------------- #
func _labyrinth(xf: Transform3D, base: Vector3, rot: float) -> void:
	_lab_built = true
	_lab_xf = xf
	_lab_inv_xf = xf.affine_inverse()
	_lab_wall_rects.clear()
	_lab_h_wall.clear()
	_lab_v_wall.clear()

	# 1) Initialize 8x8 cell wall grids (all closed) + visited table.
	var visited: Array = []
	for cz in LAB_CELLS + 1:
		var row_h: Array[bool] = []
		for cx in LAB_CELLS:
			row_h.append(true)
		_lab_h_wall.append(row_h)
	for cz in LAB_CELLS:
		var row_v: Array[bool] = []
		for cx in LAB_CELLS + 1:
			row_v.append(true)
		_lab_v_wall.append(row_v)
		var row_vis: Array[bool] = []
		for cx in LAB_CELLS:
			row_vis.append(false)
		visited.append(row_vis)

	# 2) Carve the 2x2 Central Sanctum at cells (3..4, 3..4).
	_lab_v_wall[3][4] = false
	_lab_v_wall[4][4] = false
	_lab_h_wall[4][3] = false
	_lab_h_wall[4][4] = false
	for sz in [3, 4]:
		for sx in [3, 4]:
			visited[sz][sx] = true

	# 3) Open two Sanctum thresholds on distinct faces and seed DFS from them.
	var faces := [0, 1, 2, 3]
	_shuffle(faces)
	var archways: Array[Dictionary] = []
	var stack: Array[Vector2i] = []
	for fi in 2:
		var face: int = faces[fi]
		var k := 3 if rng.randf() < 0.5 else 4
		var ring_cell := Vector2i.ZERO
		match face:
			0:  # North face of sanctum (cz=3 -> cz=2)
				_lab_h_wall[3][k] = false
				ring_cell = Vector2i(k, 2)
				archways.append({"pos": Vector3((float(k) - 3.5) * LAB_CELL, 0.0, -LAB_CELL), "horiz": true, "outer": false})
			1:  # South face of sanctum (cz=4 -> cz=5)
				_lab_h_wall[5][k] = false
				ring_cell = Vector2i(k, 5)
				archways.append({"pos": Vector3((float(k) - 3.5) * LAB_CELL, 0.0, LAB_CELL), "horiz": true, "outer": false})
			2:  # West face of sanctum (cx=3 -> cx=2)
				_lab_v_wall[k][3] = false
				ring_cell = Vector2i(2, k)
				archways.append({"pos": Vector3(-LAB_CELL, 0.0, (float(k) - 3.5) * LAB_CELL), "horiz": false, "outer": false})
			3:  # East face of sanctum (cx=4 -> cx=5)
				_lab_v_wall[k][5] = false
				ring_cell = Vector2i(5, k)
				archways.append({"pos": Vector3(LAB_CELL, 0.0, (float(k) - 3.5) * LAB_CELL), "horiz": false, "outer": false})
		visited[ring_cell.y][ring_cell.x] = true
		stack.append(ring_cell)

	# 4) Iterative randomized DFS backtracker over the 60 outer corridor cells.
	var dirs: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	while not stack.is_empty():
		var cur: Vector2i = stack.back()
		var cands: Array[Vector2i] = []
		for d in dirs:
			var nx := cur.x + d.x
			var nz := cur.y + d.y
			if nx >= 0 and nx < LAB_CELLS and nz >= 0 and nz < LAB_CELLS and not visited[nz][nx]:
				cands.append(Vector2i(nx, nz))
		if cands.is_empty():
			stack.pop_back()
		else:
			var nxt: Vector2i = cands[rng.randi_range(0, cands.size() - 1)]
			_lab_carve_between(cur, nxt)
			visited[nxt.y][nxt.x] = true
			stack.append(nxt)

	# 5) Braid ~42% of dead ends so chases have loops while keeping dead-end traps.
	var dead_ends: Array[Vector2i] = []
	for cz in LAB_CELLS:
		for cx in LAB_CELLS:
			if _lab_is_sanctum(cx, cz):
				continue
			if _lab_cell_open_degree(cx, cz) == 1:
				dead_ends.append(Vector2i(cx, cz))
	_shuffle(dead_ends)
	var braid_target := int(dead_ends.size() * 0.42)
	for bi in braid_target:
		var cell: Vector2i = dead_ends[bi]
		var closed_nbs: Array[Vector2i] = []
		for d in dirs:
			var nx := cell.x + d.x
			var nz := cell.y + d.y
			if nx < 0 or nx >= LAB_CELLS or nz < 0 or nz >= LAB_CELLS:
				continue
			if _lab_is_sanctum(nx, nz):
				continue
			if not _lab_open_between(cell, Vector2i(nx, nz)):
				closed_nbs.append(Vector2i(nx, nz))
		if not closed_nbs.is_empty():
			_lab_carve_between(cell, closed_nbs[rng.randi_range(0, closed_nbs.size() - 1)])

	# 6) Carve 4 outer stone archways (off-axis slots {1,2,5,6} on N/S/W/E).
	var edge_slots := [1, 2, 5, 6]
	var entrance_cells: Array[Vector2i] = []
	var entrance_world: Array[Vector3] = []

	var kn: int = edge_slots[rng.randi_range(0, 3)]
	_lab_h_wall[0][kn] = false
	entrance_cells.append(Vector2i(kn, 0))
	var gn := Vector3((float(kn) - 3.5) * LAB_CELL, 0.0, -LAB_HALF)
	archways.append({"pos": gn, "horiz": true, "outer": true})
	entrance_world.append(xf * gn)

	var ks: int = edge_slots[rng.randi_range(0, 3)]
	_lab_h_wall[LAB_CELLS][ks] = false
	entrance_cells.append(Vector2i(ks, LAB_CELLS - 1))
	var gs := Vector3((float(ks) - 3.5) * LAB_CELL, 0.0, LAB_HALF)
	archways.append({"pos": gs, "horiz": true, "outer": true})
	entrance_world.append(xf * gs)

	var kw: int = edge_slots[rng.randi_range(0, 3)]
	_lab_v_wall[kw][0] = false
	entrance_cells.append(Vector2i(0, kw))
	var gw := Vector3(-LAB_HALF, 0.0, (float(kw) - 3.5) * LAB_CELL)
	archways.append({"pos": gw, "horiz": false, "outer": true})
	entrance_world.append(xf * gw)

	var ke: int = edge_slots[rng.randi_range(0, 3)]
	_lab_v_wall[ke][LAB_CELLS] = false
	entrance_cells.append(Vector2i(LAB_CELLS - 1, ke))
	var ge := Vector3(LAB_HALF, 0.0, (float(ke) - 3.5) * LAB_CELL)
	archways.append({"pos": ge, "horiz": false, "outer": true})
	entrance_world.append(xf * ge)

	# 7) Build single-draw-call stone floor + stonework mesh + single StaticBody3D.
	var body := StaticBody3D.new()
	body.name = "LabyrinthBody"
	body.transform = xf
	add_child(body)

	# Raised dark flagstone floor slab (top at y = +0.035 above forest dirt)
	var st_floor := SurfaceTool.new()
	st_floor.begin(Mesh.PRIMITIVE_TRIANGLES)
	_st_add_box(st_floor, Vector3(0.0, -0.025, 0.0), Vector3(LAB_HALF * 2.0 + 0.85, 0.12, LAB_HALF * 2.0 + 0.85),
		Color(0.56, 0.57, 0.60), Vector3.ZERO, false, 1.85)
	st_floor.index()
	st_floor.generate_tangents()
	var floor_mi := MeshInstance3D.new()
	floor_mi.name = "LabyrinthFloor"
	floor_mi.transform = xf
	floor_mi.mesh = st_floor.commit()
	floor_mi.material_override = _mats["lab_floor"]
	floor_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_mi)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wall_count := 0

	# Horizontal walls (parallel to local X)
	for cz in LAB_CELLS + 1:
		var is_outer := (cz == 0 or cz == LAB_CELLS)
		var z := (float(cz) - 4.0) * LAB_CELL
		for cx in LAB_CELLS:
			if not _lab_h_wall[cz][cx]:
				continue
			var x := (float(cx) - 3.5) * LAB_CELL
			var h := rng.randf_range(3.55, 3.88) if is_outer else rng.randf_range(3.26, 3.60)
			var shade := rng.randf_range(0.62, 0.92)
			var col := Color(shade * 0.94, shade * 0.97, shade)
			var sz := Vector3(LAB_CELL + 0.04, h, LAB_WALL_THICK)
			_st_add_box(st, Vector3(x, h * 0.5, z), sz, col)
			_lab_add_collider(body, Vector3(x, h * 0.5, z), sz, true)
			wall_count += 1
			# occasional weathered coping block on top of the wall
			if rng.randf() < 0.42:
				var cw := rng.randf_range(0.75, 1.45)
				var ch := rng.randf_range(0.16, 0.34)
				var cx_off := rng.randf_range(-0.45, 0.45)
				_st_add_box(st, Vector3(x + cx_off, h + ch * 0.5, z),
					Vector3(cw, ch, LAB_WALL_THICK * 1.12), col.darkened(0.12))

	# Vertical walls (parallel to local Z)
	for cz in LAB_CELLS:
		var z := (float(cz) - 3.5) * LAB_CELL
		for cx in LAB_CELLS + 1:
			if not _lab_v_wall[cz][cx]:
				continue
			var is_outer := (cx == 0 or cx == LAB_CELLS)
			var x := (float(cx) - 4.0) * LAB_CELL
			var h := rng.randf_range(3.55, 3.88) if is_outer else rng.randf_range(3.26, 3.60)
			var shade := rng.randf_range(0.62, 0.92)
			var col := Color(shade * 0.94, shade * 0.97, shade)
			var sz := Vector3(LAB_WALL_THICK, h, LAB_CELL + 0.04)
			_st_add_box(st, Vector3(x, h * 0.5, z), sz, col)
			_lab_add_collider(body, Vector3(x, h * 0.5, z), sz, true)
			wall_count += 1
			if rng.randf() < 0.42:
				var cl := rng.randf_range(0.75, 1.45)
				var ch := rng.randf_range(0.16, 0.34)
				var cz_off := rng.randf_range(-0.45, 0.45)
				_st_add_box(st, Vector3(x, h + ch * 0.5, z + cz_off),
					Vector3(LAB_WALL_THICK * 1.12, ch, cl), col.darkened(0.12))

	# Stone piers at grid corners where walls meet or terminate
	for gz in LAB_CELLS + 1:
		for gx in LAB_CELLS + 1:
			var deg := 0
			if gx < LAB_CELLS and _lab_h_wall[gz][gx]:
				deg += 1
			if gx > 0 and _lab_h_wall[gz][gx - 1]:
				deg += 1
			if gz < LAB_CELLS and _lab_v_wall[gz][gx]:
				deg += 1
			if gz > 0 and _lab_v_wall[gz - 1][gx]:
				deg += 1
			if deg == 0 or deg == 2 and (
					(gx > 0 and gx < LAB_CELLS and _lab_h_wall[gz][gx] and _lab_h_wall[gz][gx - 1]) or
					(gz > 0 and gz < LAB_CELLS and _lab_v_wall[gz][gx] and _lab_v_wall[gz - 1][gx])):
				continue
			var px := (float(gx) - 4.0) * LAB_CELL
			var pz := (float(gz) - 4.0) * LAB_CELL
			var ph := rng.randf_range(3.68, 4.02)
			var pcol := Color(0.68, 0.70, 0.74).darkened(rng.randf_range(0.0, 0.22))
			var psz := Vector3(0.48, ph, 0.48)
			_st_add_box(st, Vector3(px, ph * 0.5, pz), psz, pcol)
			_lab_add_collider(body, Vector3(px, ph * 0.5, pz), psz, true)

	# Stone archways (heavy gateposts + overhead lintel with 2.98 m headroom)
	for arch in archways:
		var ap: Vector3 = arch["pos"]
		var horiz: bool = arch["horiz"]
		var outer: bool = arch["outer"]
		var post_h := 4.18 if outer else 3.92
		var span := LAB_CELL
		var pcol := Color(0.74, 0.75, 0.78) if outer else Color(0.66, 0.68, 0.72)
		var off := Vector3(span * 0.5, 0.0, 0.0) if horiz else Vector3(0.0, 0.0, span * 0.5)
		var post_sz := Vector3(0.54, post_h, 0.58) if horiz else Vector3(0.58, post_h, 0.54)
		for side in [-1.0, 1.0]:
			var jp: Vector3 = ap + off * float(side) + Vector3(0.0, post_h * 0.5, 0.0)
			_st_add_box(st, jp, post_sz, pcol)
			_lab_add_collider(body, jp, post_sz, true)
		# Overhead lintel (bottom at y = 2.98 m -> player & Slender walk cleanly under)
		var lintel_sz := Vector3(span + 0.62, 0.52, 0.62) if horiz else Vector3(0.62, 0.52, span + 0.62)
		var lp_pos := ap + Vector3(0.0, 3.24, 0.0)
		_st_add_box(st, lp_pos, lintel_sz, pcol.darkened(0.08), Vector3.ZERO, true)
		_lab_add_collider(body, lp_pos, lintel_sz, false)

	# Central Sanctum set-piece: low carved stone dais at the centre + four
	# weathered corner steles framing the chamber (leaves the whole central
	# floor open from every cardinal approach).
	_st_add_box(st, Vector3(0.0, 0.06, 0.0), Vector3(1.65, 0.12, 1.65), Color(0.60, 0.62, 0.66))
	for sx in [-1.85, 1.85]:
		for sz_c in [-1.85, 1.85]:
			var sh := rng.randf_range(1.55, 2.15)
			var st_sz := Vector3(0.46, sh, 0.46)
			var spos := Vector3(float(sx), sh * 0.5, float(sz_c))
			_st_add_box(st, spos, st_sz, Color(0.70, 0.72, 0.76))
			_lab_add_collider(body, spos, st_sz, true)

	st.index()
	st.generate_tangents()
	var lab_mi := MeshInstance3D.new()
	lab_mi.name = "LabyrinthMesh"
	lab_mi.transform = xf
	lab_mi.mesh = st.commit()
	lab_mi.material_override = _mats["lab_wall"]
	lab_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Game.quality >= 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lab_mi)

	# 8) Spatial ReverbZone covering the stone labyrinth interior.
	var rzone: Area3D = load("res://scripts/reverb_zone.gd").new()
	rzone.name = "LabyrinthReverbZone"
	rzone.transform = Transform3D(xf.basis, base + Vector3(0.0, 2.2, 0.0))
	rzone.setup(Vector3(LAB_HALF + 0.45, 2.6, LAB_HALF + 0.45), 2.4)
	add_child(rzone)

	# 9) Verify BFS path from every entrance to the Sanctum and record metadata.
	var sanctum_goals: Array[Vector2i] = [Vector2i(3, 3), Vector2i(4, 3), Vector2i(3, 4), Vector2i(4, 4)]
	var min_path := 999
	var max_path := 0
	for ec in entrance_cells:
		var d := _lab_bfs_distance(ec, sanctum_goals)
		min_path = mini(min_path, d)
		max_path = maxi(max_path, d)

	var sanctum_page := xf * Vector3.ZERO
	page_spots.append({"pos": sanctum_page, "name": "labyrinth"})
	landmarks.append({"name": "labyrinth", "pos": base, "radius": 14.8, "rot": rot, "scale": 1.0})

	labyrinth = {
		"pos": base,
		"rot": rot,
		"half": LAB_HALF,
		"cells": LAB_CELLS,
		"cell_size": LAB_CELL,
		"wall_count": wall_count,
		"dead_ends": dead_ends.size(),
		"entrances": entrance_world,
		"entrance_cells": entrance_cells,
		"sanctum_pos": sanctum_page,
		"shortest_path": min_path,
		"longest_path": max_path,
		"signature": _lab_signature(),
		"reverb_zone": rzone,
	}


func _lab_is_sanctum(cx: int, cz: int) -> bool:
	return cx >= 3 and cx <= 4 and cz >= 3 and cz <= 4


func _lab_open_between(a: Vector2i, b: Vector2i) -> bool:
	var dx := b.x - a.x
	var dy := b.y - a.y
	if dx == 1 and dy == 0:
		return not _lab_v_wall[a.y][a.x + 1]
	if dx == -1 and dy == 0:
		return not _lab_v_wall[a.y][a.x]
	if dx == 0 and dy == 1:
		return not _lab_h_wall[a.y + 1][a.x]
	if dx == 0 and dy == -1:
		return not _lab_h_wall[a.y][a.x]
	return false


func _lab_carve_between(a: Vector2i, b: Vector2i) -> void:
	var dx := b.x - a.x
	var dy := b.y - a.y
	if dx == 1 and dy == 0:
		_lab_v_wall[a.y][a.x + 1] = false
	elif dx == -1 and dy == 0:
		_lab_v_wall[a.y][a.x] = false
	elif dx == 0 and dy == 1:
		_lab_h_wall[a.y + 1][a.x] = false
	elif dx == 0 and dy == -1:
		_lab_h_wall[a.y][a.x] = false


func _lab_cell_open_degree(cx: int, cz: int) -> int:
	var deg := 0
	if cz > 0 and not _lab_h_wall[cz][cx]:
		deg += 1
	if cz < LAB_CELLS - 1 and not _lab_h_wall[cz + 1][cx]:
		deg += 1
	if cx > 0 and not _lab_v_wall[cz][cx]:
		deg += 1
	if cx < LAB_CELLS - 1 and not _lab_v_wall[cz][cx + 1]:
		deg += 1
	return deg


func _lab_bfs_distance(start: Vector2i, goals: Array[Vector2i]) -> int:
	var dist := {}
	var queue: Array[Vector2i] = [start]
	dist[start] = 0
	var head := 0
	var dirs: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		var d_cur: int = dist[cur]
		if cur in goals:
			return d_cur
		for d in dirs:
			var nb := cur + d
			if nb.x < 0 or nb.x >= LAB_CELLS or nb.y < 0 or nb.y >= LAB_CELLS:
				continue
			if dist.has(nb) or not _lab_open_between(cur, nb):
				continue
			dist[nb] = d_cur + 1
			queue.append(nb)
	return -1


func _lab_signature() -> String:
	var bits := PackedStringArray()
	for cz in LAB_CELLS + 1:
		var s := ""
		for cx in LAB_CELLS:
			s += "1" if _lab_h_wall[cz][cx] else "0"
		bits.append(s)
	for cz in LAB_CELLS:
		var s2 := ""
		for cx in LAB_CELLS + 1:
			s2 += "1" if _lab_v_wall[cz][cx] else "0"
		bits.append(s2)
	return "/".join(bits)


func _lab_add_collider(body: StaticBody3D, local_pos: Vector3, size: Vector3, blocks_ground: bool) -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	col.position = local_pos
	body.add_child(col)
	if blocks_ground:
		_lab_wall_rects.append(Rect2(local_pos.x - size.x * 0.5, local_pos.z - size.z * 0.5, size.x, size.z))


## Appends an outward-wound, world-UV-scaled box to `st` (matches selftest normal guard).
func _st_add_box(st: SurfaceTool, pos: Vector3, size: Vector3, color: Color,
		rot := Vector3.ZERO, include_bottom := false, uv_tile := 2.2) -> void:
	var basis := Basis.from_euler(rot)
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	# Each face: [normal, u_axis, v_axis, half_u, half_v, half_n] with u.cross(v) == +normal
	var faces := [
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0), hx, hy, hz],
		[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0), hx, hy, hz],
		[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0), hz, hy, hx],
		[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0), hz, hy, hx],
		[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1), hx, hz, hy],
	]
	if include_bottom:
		faces.append([Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1), hx, hz, hy])
	st.set_color(color)
	for f in faces:
		var n_dir: Vector3 = (basis * (f[0] as Vector3)).normalized()
		var u_dir: Vector3 = basis * (f[1] as Vector3)
		var v_dir: Vector3 = basis * (f[2] as Vector3)
		var hu: float = f[3]
		var hv: float = f[4]
		var hn: float = f[5]
		var centre := pos + n_dir * hn
		var p0 := centre - u_dir * hu - v_dir * hv
		var p1 := centre + u_dir * hu - v_dir * hv
		var p2 := centre + u_dir * hu + v_dir * hv
		var p3 := centre - u_dir * hu + v_dir * hv
		var su := (hu * 2.0) / uv_tile
		var sv := (hv * 2.0) / uv_tile
		var ua := Vector2(0.0, sv)
		var ub := Vector2(su, sv)
		var uc := Vector2(su, 0.0)
		var ud := Vector2(0.0, 0.0)
		st.set_normal(n_dir); st.set_uv(ua); st.add_vertex(p0)
		st.set_normal(n_dir); st.set_uv(ub); st.add_vertex(p1)
		st.set_normal(n_dir); st.set_uv(uc); st.add_vertex(p2)
		st.set_normal(n_dir); st.set_uv(ua); st.add_vertex(p0)
		st.set_normal(n_dir); st.set_uv(uc); st.add_vertex(p2)
		st.set_normal(n_dir); st.set_uv(ud); st.add_vertex(p3)


# --------------------------------------------------------------------------- #
# landmark builders (local space; variant chosen by seed)
# --------------------------------------------------------------------------- #
func _concrete_walls(xf: Transform3D) -> void:
	var m: Material = _mats["concrete"]
	var h := rng.randf_range(2.3, 3.3)
	var variant := rng.randi_range(0, 2)
	# long broken perimeter wall, gap placement varies
	var span := rng.randf_range(8.0, 12.0)
	var gap := rng.randf_range(-span * 0.35, span * 0.35)
	_box(xf, Vector3(gap - span * 0.75, h * 0.5, -3), Vector3(span * 0.7, h, 0.32), m, Vector3(0, rng.randf_range(-0.03, 0.03), 0))
	_box(xf, Vector3(gap + span * 0.75, h * 0.5, -3), Vector3(span * 0.7, h, 0.32), m)
	_box(xf, Vector3(-7.2, h * 0.5, rng.randf_range(-1, 2)), Vector3(0.32, h, span * 0.8), m, Vector3(0, 0, rng.randf_range(-0.02, 0.02)))
	_box(xf, Vector3(7.2, h * 0.5, rng.randf_range(0, 3)), Vector3(0.32, h, span * 0.7), m)
	if variant >= 1:
		_box(xf, Vector3(rng.randf_range(-2, 2), h * 0.5 + 0.2, 3.4), Vector3(span * 0.6, h * 0.92, 0.3), m, Vector3(0, 0.2 * rng.randf_range(-1, 1), 0))
	if variant == 2:
		# collapsed slab leaning on the wall
		_box(xf, Vector3(2.0, 1.1, 0.4), Vector3(4.0, 0.28, 3.0), m, Vector3(rng.randf_range(-0.2, 0.2), rng.randf_range(-0.4, 0.4), 0.55))
		_box(xf, Vector3(-3.2, 0.2, 1.0), Vector3(1.6, 0.35, 1.2), m, Vector3(0.1, 0.8, 0))


func _tunnel(xf: Transform3D) -> void:
	var m: Material = _mats["concrete"]
	var h := rng.randf_range(2.9, 3.5)
	var ln := rng.randf_range(6.5, 8.5)
	_box(xf, Vector3(-2.2, h * 0.5, 0), Vector3(0.45, h, ln), m)
	_box(xf, Vector3(2.2, h * 0.5, 0), Vector3(0.45, h, ln), m)
	_box(xf, Vector3(0, h + 0.22, 0), Vector3(4.85, 0.45, ln), m)
	# both ends are broken open with random rubble
	_box(xf, Vector3(rng.randf_range(-1.4, 1.4), h * 0.5, ln * 0.5), Vector3(rng.randf_range(1.6, 3.4), h, 0.35), m)
	_box(xf, Vector3(rng.randf_range(-1.4, 1.4), h * 0.42, -ln * 0.5), Vector3(rng.randf_range(1.4, 3.0), h * 0.85, 0.35), m)
	# spilled rubble outside
	for i in rng.randi_range(3, 6):
		_box(xf, Vector3(rng.randf_range(-3.5, 3.5), 0.16, rng.randf_range(ln * 0.5, ln * 0.5 + 2.5)),
			Vector3(rng.randf_range(0.4, 1.2), 0.32, rng.randf_range(0.4, 1.0)), m, Vector3(0, rng.randf() * TAU, rng.randf_range(-0.2, 0.2)))


func _silo(xf: Transform3D) -> void:
	var r := rng.randf_range(1.9, 2.6)
	var h := rng.randf_range(6.0, 8.5)
	_cyl(xf, Vector3(0, h * 0.5, 0), r, h, _mats["metal"])
	_cyl(xf, Vector3(0, h + 0.35, 0), r * 1.06, 0.6, _mats["metal"], r * 0.2)
	_cyl(xf, Vector3(0, h + 0.7, 0), r * 0.3, 0.5, _mats["rust"])
	_box(xf, Vector3(0, 0.28, r + 0.9), Vector3(1.7, 0.55, 1.6), _mats["concrete"])
	# ladder up the side + a rusted hatch
	_box(xf, Vector3(-0.5, h * 0.45, r + 0.06), Vector3(0.09, h * 0.85, 0.09), _mats["rust"], Vector3.ZERO, false)
	_box(xf, Vector3(0.5, h * 0.45, r + 0.06), Vector3(0.09, h * 0.85, 0.09), _mats["rust"], Vector3.ZERO, false)
	for i in int(h / 0.7):
		_box(xf, Vector3(0, 0.6 + i * 0.7, r + 0.06), Vector3(1.05, 0.05, 0.05), _mats["rust"], Vector3.ZERO, false)
	_box(xf, Vector3(0, 1.0, r + 0.09), Vector3(1.0, 1.9, 0.05), _mats["dark"], Vector3.ZERO, false)


func _truck(xf: Transform3D) -> void:
	var m: Material = _mats["metal"]
	var ln := rng.randf_range(4.6, 6.0)
	_box(xf, Vector3(0, 1.15, 0), Vector3(2.25, 1.65, ln), m)
	_box(xf, Vector3(0, 2.3, ln * 0.34), Vector3(2.15, 1.1, 1.6), m)
	_box(xf, Vector3(0, 2.32, ln * 0.34 + 0.81), Vector3(1.9, 0.7, 0.05), _mats["dark"], Vector3.ZERO, false)
	# cargo bed walls
	_box(xf, Vector3(0, 2.05, -ln * 0.12), Vector3(2.3, 0.12, ln * 0.52), _mats["rust"], Vector3.ZERO, false)
	for wx in [-1.12, 1.12]:
		for wz in [-ln * 0.32, -ln * 0.06, ln * 0.3]:
			_cyl(xf, Vector3(wx, 0.5, wz), 0.5, 0.34, _mats["dark"])


func _shed(xf: Transform3D) -> void:
	var m: Material = _mats["wood"]
	var w := rng.randf_range(3.6, 4.8)
	var d := rng.randf_range(3.8, 5.2)
	var h := rng.randf_range(2.1, 2.8)
	_box(xf, Vector3(-w * 0.5, h * 0.5, 0), Vector3(0.24, h, d), m)
	_box(xf, Vector3(w * 0.5, h * 0.5, 0), Vector3(0.24, h, d), m)
	_box(xf, Vector3(0, h * 0.5, -d * 0.5), Vector3(w, h, 0.24), m)
	# front wall with a doorway, offset randomly
	var door_w := rng.randf_range(0.8, 1.3)
	var door_x := rng.randf_range(-w * 0.25, w * 0.25)
	var side_w := (w - door_w) * 0.5
	_box(xf, Vector3(door_x - door_w * 0.5 - side_w * 0.5, h * 0.5, d * 0.5), Vector3(side_w, h, 0.24), m)
	_box(xf, Vector3(door_x + door_w * 0.5 + side_w * 0.5, h * 0.5, d * 0.5), Vector3(side_w, h, 0.24), m)
	# roof panels, slightly skewed
	_box(xf, Vector3(0, h + 0.09, 0), Vector3(w + 0.7, 0.16, d + 0.7), _mats["dark"], Vector3(rng.randf_range(-0.03, 0.03), 0, rng.randf_range(-0.04, 0.04)))
	# broken plank leaning by the door
	_box(xf, Vector3(door_x + door_w, 0.9, d * 0.5 + 0.6), Vector3(0.9, 1.6, 0.08), m, Vector3(0.15, rng.randf_range(-0.3, 0.3), 0.35), false)


func _rock_circle(xf: Transform3D) -> void:
	var n := rng.randi_range(7, 11)
	var radius := rng.randf_range(2.8, 4.0)
	for i in n:
		var a := TAU * float(i) / n + rng.randf_range(-0.15, 0.15)
		var rr := radius * rng.randf_range(0.9, 1.12)
		var p := Vector3(cos(a) * rr, 0, sin(a) * rr)
		var hh := rng.randf_range(1.0, 2.2)
		var rad := rng.randf_range(0.45, 0.75)
		var body := _cyl(xf, p + Vector3(0, hh * 0.5, 0), rad, hh, _mats["stone"], rad * 0.55)
		body.rotation = xf.basis.get_rotation_quaternion().get_euler() + Vector3(rng.randf_range(-0.08, 0.08), rng.randf() * 0.6, rng.randf_range(-0.08, 0.08))
	# toppled stone in the middle
	_box(xf, Vector3(rng.randf_range(-0.8, 0.8), 0.4, rng.randf_range(-0.8, 0.8)), Vector3(1.5, 0.8, 0.9), _mats["stone"], Vector3(0.3, rng.randf() * TAU, 0.2))


func _bathroom(xf: Transform3D) -> void:
	var m: Material = _mats["concrete"]
	var w := rng.randf_range(3.4, 4.4)
	var d := rng.randf_range(4.6, 6.0)
	var h := rng.randf_range(2.6, 3.2)
	_box(xf, Vector3(-w * 0.5, h * 0.5, 0), Vector3(0.28, h, d), m)
	_box(xf, Vector3(w * 0.5, h * 0.5, 0), Vector3(0.28, h, d), m)
	_box(xf, Vector3(0, h * 0.5, -d * 0.5), Vector3(w, h, 0.28), m)
	_box(xf, Vector3(0, h + 0.1, 0), Vector3(w + 0.5, 0.2, d + 0.5), _mats["dark"])
	# front with two doorways
	var door := 0.95
	_box(xf, Vector3(-w * 0.5 + 0.5, h * 0.5, d * 0.5), Vector3(1.0, h, 0.28), m)
	_box(xf, Vector3(0, h * 0.5, d * 0.5), Vector3(0.6, h, 0.28), m)
	_box(xf, Vector3(w * 0.5 - 0.5, h * 0.5, d * 0.5), Vector3(1.0, h, 0.28), m)
	# stall dividers inside
	for i in 2:
		_box(xf, Vector3(rng.randf_range(-1.2, 1.2), 1.0, -d * 0.5 + 1.4 + i * 1.5), Vector3(w - 0.7, 2.0, 0.12), m)
	_box(xf, Vector3(0, 0.45, d * 0.5 + 0.4), Vector3(0.6, 0.5, 0.5), _mats["dark"])  # drain


func _tower(xf: Transform3D) -> void:
	var m: Material = _mats["rust"]
	var top := rng.randf_range(6.5, 9.0)
	var half_w := rng.randf_range(0.65, 0.95)
	for dx in [-half_w, half_w]:
		for dz in [-half_w, half_w]:
			_box(xf, Vector3(dx, top * 0.5, dz), Vector3(0.14, top, 0.14), m)
	for y in [1.1, 2.7, 4.3, 5.9]:
		if y > top:
			continue
		_box(xf, Vector3(0, y, -half_w), Vector3(half_w * 2, 0.06, 0.06), m, Vector3.ZERO, false)
		_box(xf, Vector3(0, y, half_w), Vector3(half_w * 2, 0.06, 0.06), m, Vector3.ZERO, false)
		_box(xf, Vector3(-half_w, y, 0), Vector3(0.06, 0.06, half_w * 2), m, Vector3.ZERO, false)
		_box(xf, Vector3(half_w, y, 0), Vector3(0.06, 0.06, half_w * 2), m, Vector3.ZERO, false)
	_box(xf, Vector3(0, top + 0.08, 0), Vector3(half_w * 2.6, 0.16, half_w * 2.6), _mats["wood"])
	for dz in [-half_w, half_w]:
		_box(xf, Vector3(0, top + 0.75, dz), Vector3(half_w * 2.6, 0.06, 0.06), m, Vector3.ZERO, false)
	for dx in [-half_w, half_w]:
		_box(xf, Vector3(dx, top + 0.75, 0), Vector3(0.06, 0.06, half_w * 2.6), m, Vector3.ZERO, false)


# --------------------------------------------------------------------------- #
# forest
# --------------------------------------------------------------------------- #
func _in_clearing(p: Vector3, extra := 0.0) -> bool:
	if in_labyrinth(p, 1.65 + extra):
		return true
	for sp in page_spots:
		var spos: Vector3 = sp["pos"]
		if Vector2(p.x - spos.x, p.z - spos.z).length() < 1.6 + extra * 0.5:
			return true
	for l in landmarks:
		if l["name"] == "labyrinth":
			continue
		if Vector2(p.x - l["pos"].x, p.z - l["pos"].z).length() < float(l["radius"]) * 0.62 + extra:
			return true
	return false


func _too_close(p: Vector3, dist: float) -> bool:
	for t in tree_positions:
		if Vector2(p.x - t.x, p.z - t.z).length() < dist:
			return true
	return false


func _forest(max_trees: int, quality: int) -> void:
	var buckets: Array = []
	for i in _tree_meshes.size():
		buckets.append({"xf": [], "col": []})
	var snag_buckets: Array = []
	for i in _snag_meshes.size():
		snag_buckets.append({"xf": [], "col": []})

	var tries := 0
	var target := max_trees
	while tree_positions.size() < target and tries < target * 20:
		tries += 1
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * (HALF - 2.0)
		var p := Vector3(cos(a) * r, 0.0, sin(a) * r)
		if Vector2(p.x, p.z).length() < 8.0:
			continue
		if _in_clearing(p, 1.5) or _too_close(p, 2.9):
			continue
		if _point_inside_prop(p):
			continue
		var density := _density.get_noise_2d(p.x, p.z) * 0.5 + 0.5
		if density < 0.30 and rng.randf() > 0.3:
			continue
		var s := rng.randf_range(0.78, 1.35)
		var tilt := Vector3(rng.randf_range(-0.045, 0.045), rng.randf() * TAU, rng.randf_range(-0.045, 0.045))
		var basis := Basis.from_euler(tilt).scaled(Vector3(s, s, s))
		var is_snag := rng.randf() < 0.14
		var tint := Color(1, 1, 1).darkened(rng.randf_range(0.0, 0.45))
		if is_snag and snag_buckets.size() > 0:
			var bi := rng.randi_range(0, snag_buckets.size() - 1)
			snag_buckets[bi]["xf"].append(Transform3D(basis, p))
			snag_buckets[bi]["col"].append(tint)
		else:
			var bi2 := rng.randi_range(0, buckets.size() - 1)
			buckets[bi2]["xf"].append(Transform3D(basis, p))
			buckets[bi2]["col"].append(tint)
		tree_positions.append(p)
	_tree_count = tree_positions.size()

	for i in buckets.size():
		_add_multimesh(_tree_meshes[i], _mats["bark"], buckets[i]["xf"], buckets[i]["col"], "Trees_%d" % i)
	for i in snag_buckets.size():
		_add_multimesh(_snag_meshes[i], _mats["bark"], snag_buckets[i]["xf"], snag_buckets[i]["col"], "Snags_%d" % i)

	_tree_collisions()


func _add_multimesh(mesh: Mesh, mat: Material, xforms: Array, colors: Array, node_name: String) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		if i < colors.size():
			mm.set_instance_color(i, colors[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Game.quality >= 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


func _tree_collisions() -> void:
	var body := StaticBody3D.new()
	body.name = "TreeCollision"
	add_child(body)
	for t in tree_positions:
		var shape := CylinderShape3D.new()
		shape.radius = 0.42
		shape.height = 7.0
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = t + Vector3(0, 2.2, 0)
		body.add_child(col)


# --------------------------------------------------------------------------- #
# undergrowth: fallen logs, stumps, dead shrubs, grass tufts, litter
# --------------------------------------------------------------------------- #
func _undergrowth(quality: int) -> void:
	var log_mesh: Mesh = _props.get("log")
	var stump_mesh: Mesh = _props.get("stump")
	var shrub_mesh: Mesh = _props.get("shrub")
	var body := StaticBody3D.new()
	body.name = "PropCollision"
	add_child(body)

	if log_mesh != null:
		var xf: Array = []
		var col: Array = []
		for i in int(34 * quality_scale(quality)):
			var p := _random_clear_spot(4.0)
			if p == Vector3.INF:
				continue
			var yaw := rng.randf() * TAU
			var s := rng.randf_range(0.8, 1.4)
			var b := Basis.from_euler(Vector3(0, yaw, rng.randf_range(-0.06, 0.06))).scaled(Vector3(s, s, s))
			xf.append(Transform3D(b, p))
			col.append(Color(1, 1, 1).darkened(rng.randf_range(0.0, 0.4)))
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = Vector3(0.9 * s, 0.8 * s, 5.6 * s)
			cs.shape = bs
			cs.position = p + Vector3(0, 0.42 * s, 0)
			cs.rotation.y = yaw
			body.add_child(cs)
		_add_multimesh(log_mesh, _mats["bark"], xf, col, "Logs")

	if stump_mesh != null:
		var xf: Array = []
		var col: Array = []
		for i in int(30 * quality_scale(quality)):
			var p := _random_clear_spot(1.0, 8.0)
			if p == Vector3.INF:
				continue
			var s := rng.randf_range(0.7, 1.5)
			xf.append(Transform3D(Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)).scaled(Vector3(s, s, s)), p))
			col.append(Color(1, 1, 1).darkened(rng.randf_range(0.0, 0.4)))
		_add_multimesh(stump_mesh, _mats["bark"], xf, col, "Stumps")

	if shrub_mesh != null:
		var xf: Array = []
		var col: Array = []
		for i in int(260 * quality_scale(quality)):
			var p := _random_clear_spot(1.6, 3.0)
			if p == Vector3.INF:
				continue
			var s := rng.randf_range(0.55, 1.5)
			xf.append(Transform3D(Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)).scaled(Vector3(s, s, s)), p))
			col.append(Color(1, 1, 1).darkened(rng.randf_range(0.0, 0.5)))
		_add_multimesh(shrub_mesh, _mats["bark"], xf, col, "Shrubs")


# --------------------------------------------------------------------------- #
# pumpkins and dead bushes
# --------------------------------------------------------------------------- #
func _pumpkins_and_bushes(quality: int) -> void:
	var qs := quality_scale(quality)

	# --- pumpkins: small patches in the open + a couple at every landmark ---
	if not _pumpkin_meshes.is_empty():
		var buckets := []
		for i in _pumpkin_meshes.size():
			buckets.append({"xf": [], "col": []})
		var spots: Array[Vector3] = []
		# a scatter of patches: three to seven pumpkins growing together
		var patches := int(9 * qs) + 4
		for p_i in patches:
			var centre := _random_clear_spot(2.2, HALF - 8.0)
			if centre == Vector3.INF:
				continue
			var n := rng.randi_range(3, 7)
			for k in n:
				var a := rng.randf() * TAU
				var d := rng.randf_range(0.2, 1.9)
				var p := centre + Vector3(cos(a) * d, 0.0, sin(a) * d)
				if _point_inside_prop(p) or _too_close(p, 0.9):
					continue
				spots.append(p)
		# every landmark gets a few, so they read as "someone was here"
		for lm in landmarks:
			if lm["name"] == "labyrinth":
				continue
			var centre: Vector3 = lm["pos"]
			var radius: float = float(lm["radius"])
			for k in rng.randi_range(2, 5):
				var a := rng.randf() * TAU
				var d := radius * rng.randf_range(0.55, 1.15)
				var p := centre + Vector3(cos(a) * d, 0.0, sin(a) * d)
				if _point_inside_prop(p) or in_labyrinth(p, 0.3):
					continue
				spots.append(p)
		# scatter pumpkins outside the labyrinth archways + beside the sanctum altar
		if _lab_built and labyrinth.has("entrances"):
			var ents: Array = labyrinth["entrances"]
			for ep_v in ents:
				var ep: Vector3 = ep_v
				var out_dir := (ep - (labyrinth["pos"] as Vector3))
				out_dir.y = 0.0
				out_dir = out_dir.normalized()
				for k in rng.randi_range(1, 2):
					var side := Vector3(-out_dir.z, 0.0, out_dir.x) * (1.25 if k == 0 else -1.25)
					var pp := ep + out_dir * rng.randf_range(0.75, 1.35) + side
					if not _point_inside_prop(pp):
						spots.append(pp)
			spots.append(_lab_xf * Vector3(-1.32, 0.0, -1.82))
			spots.append(_lab_xf * Vector3(1.32, 0.0, 1.82))
		for p in spots:
			var idx := rng.randi_range(0, _pumpkin_meshes.size() - 1)
			var s := rng.randf_range(0.75, 1.35)
			# some pumpkins have been knocked over
			var tipped := rng.randf() < 0.18
			var euler := Vector3(0, rng.randf() * TAU, 0)
			if tipped:
				euler.x = rng.randf_range(1.2, 1.75)
			var basis := Basis.from_euler(euler).scaled(Vector3(s, s, s))
			# the pumpkin mesh is centred on its middle, so lift it out of the dirt
			var stone_lift := 0.035 if in_labyrinth(p, 0.4) else 0.0
			var lift := Vector3(0, 0.27 * s + stone_lift, 0) if not tipped else Vector3(0, 0.19 * s + stone_lift, 0)
			buckets[idx]["xf"].append(Transform3D(basis, p + lift))
			var t := rng.randf_range(0.72, 1.12)
			buckets[idx]["col"].append(Color(t, t * 0.97, t * 0.9))
		for i in _pumpkin_meshes.size():
			if not buckets[i]["xf"].is_empty():
				_add_multimesh(_pumpkin_meshes[i], _mats["pumpkin"],
					buckets[i]["xf"], buckets[i]["col"], "Pumpkins_%d" % i)

	# --- dead bushes: dense thickets, thicker at the arena edge -------------
	if not _bush_meshes.is_empty():
		var buckets := []
		for i in _bush_meshes.size():
			buckets.append({"xf": [], "col": []})
		var count := int(230 * qs)
		for i in count:
			var a := rng.randf() * TAU
			# bias toward the outer ring of the forest
			var r := pow(rng.randf(), 0.6) * (HALF - 3.0)
			var p := Vector3(cos(a) * r, 0.0, sin(a) * r)
			if Vector2(p.x, p.z).length() < 9.0:
				continue
			if in_labyrinth(p, 1.2) or _point_inside_prop(p) or _too_close(p, 1.4):
				continue
			var idx := rng.randi_range(0, _bush_meshes.size() - 1)
			var s := rng.randf_range(0.7, 1.5)
			var b := Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)).scaled(Vector3(s, s * rng.randf_range(0.85, 1.25), s))
			buckets[idx]["xf"].append(Transform3D(b, p))
			var t := rng.randf_range(0.55, 1.0)
			buckets[idx]["col"].append(Color(t, t * 0.98, t * 0.92))
		for i in _bush_meshes.size():
			if not buckets[i]["xf"].is_empty():
				_add_multimesh(_bush_meshes[i], _mats["bark"],
					buckets[i]["xf"], buckets[i]["col"], "Bushes_%d" % i)


func _ground_detail(quality: int) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var offset := 0.5  # base at the ground
	# --- grass tufts -------------------------------------------------------
	var xf: Array = []
	var col: Array = []
	var count := int(1500 * quality_scale(quality))
	for i in count:
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * (HALF - 1.0)
		var p := Vector3(cos(a) * r, 0.0, sin(a) * r)
		if in_labyrinth(p, 0.6) or _point_inside_prop(p):
			continue
		var s := rng.randf_range(0.35, 0.75)
		var b := Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)).scaled(Vector3(s, s * rng.randf_range(0.8, 1.5), s))
		xf.append(Transform3D(b, p + Vector3(0, s * offset, 0)))
		var tint := rng.randf_range(0.35, 0.8)
		col.append(Color(tint, tint * 0.95, tint * 0.8))
	_add_multimesh(quad, _mats["grass"], xf, col, "Grass")

	# --- flat litter decals ------------------------------------------------
	var decal := PlaneMesh.new()
	decal.size = Vector2(1.3, 1.3)
	var xf2: Array = []
	var col2: Array = []
	for i in int(420 * quality_scale(quality)):
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * (HALF - 1.0)
		var p := Vector3(cos(a) * r, 0.02, sin(a) * r)
		if in_labyrinth(p, 0.5):
			continue
		var s := rng.randf_range(0.7, 2.0)
		xf2.append(Transform3D(Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)).scaled(Vector3(s, 1, s)), p))
		var t := rng.randf_range(0.5, 1.0)
		col2.append(Color(t, t * 0.92, t * 0.78))
	_add_multimesh(decal, _mats["litter"], xf2, col2, "Litter")


func quality_scale(q: int) -> float:
	return [0.45, 0.75, 1.0][clampi(q, 0, 2)]


func _random_clear_spot(min_from_trees: float, max_radius := HALF - 4.0) -> Vector3:
	for i in 12:
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * max_radius
		var p := Vector3(cos(a) * r, 0.0, sin(a) * r)
		if Vector2(p.x, p.z).length() < 7.0:
			continue
		if _too_close(p, min_from_trees):
			continue
		if _in_clearing(p, 0.0) or _point_inside_prop(p):
			continue
		return p
	return Vector3.INF


# --------------------------------------------------------------------------- #
# queries used by the AI / world
# --------------------------------------------------------------------------- #
func pumpkin_count() -> int:
	var total := 0
	for n in get_children():
		if n is MultiMeshInstance3D and String(n.name).begins_with("Pumpkins_"):
			total += n.multimesh.instance_count
	return total


func bush_count() -> int:
	var total := 0
	for n in get_children():
		if n is MultiMeshInstance3D and String(n.name).begins_with("Bushes_"):
			total += n.multimesh.instance_count
	return total


func tree_count() -> int:
	return _tree_count


func nearest_tree_distance(p: Vector3, max_check := 400) -> float:
	var best := 9999.0
	var n := mini(tree_positions.size(), max_check)
	for i in n:
		var t := tree_positions[i]
		var d := Vector2(p.x - t.x, p.z - t.z).length()
		if d < best:
			best = d
	return best


func in_labyrinth(p: Vector3, margin := 0.0) -> bool:
	if not _lab_built:
		return false
	var lp: Vector3 = _lab_inv_xf * p
	var h := LAB_HALF + margin
	return absf(lp.x) <= h and absf(lp.z) <= h


func point_in_labyrinth_wall(p: Vector3, pad := 0.35) -> bool:
	if not _lab_built:
		return false
	var lp: Vector3 = _lab_inv_xf * p
	var bound := LAB_HALF + pad + 0.6
	if absf(lp.x) > bound or absf(lp.z) > bound:
		return false
	var pt := Vector2(lp.x, lp.z)
	for r in _lab_wall_rects:
		if r.grow(pad).has_point(pt):
			return true
	return false


func _lab_world_to_cell(p: Vector3) -> Vector2i:
	var lp: Vector3 = _lab_inv_xf * p
	var cx := clampi(int(floor((lp.x + LAB_HALF) / LAB_CELL)), 0, LAB_CELLS - 1)
	var cz := clampi(int(floor((lp.z + LAB_HALF) / LAB_CELL)), 0, LAB_CELLS - 1)
	return Vector2i(cx, cz)


func _lab_cell_to_world(c: Vector2i) -> Vector3:
	return _lab_xf * Vector3((float(c.x) - 3.5) * LAB_CELL, 0.0, (float(c.y) - 3.5) * LAB_CELL)


## Returns a horizontal unit steering vector through open labyrinth doorways
## from `from_pos` toward `to_pos`, or Vector3.ZERO when outside / already same cell.
func labyrinth_flow_dir(from_pos: Vector3, to_pos: Vector3) -> Vector3:
	if not _lab_built:
		return Vector3.ZERO
	if not in_labyrinth(from_pos, 1.8) and not in_labyrinth(to_pos, 0.6):
		return Vector3.ZERO
	# If Slender is just outside the walls trying to enter, aim at the nearest entrance first.
	if not in_labyrinth(from_pos, 0.1) and labyrinth.has("entrances"):
		var best_ent := Vector3.INF
		var best_d := 1e9
		for ev in labyrinth["entrances"]:
			var ep: Vector3 = ev
			var d := ep.distance_to(from_pos) + 0.45 * ep.distance_to(to_pos)
			if d < best_d:
				best_d = d
				best_ent = ep
		if best_ent != Vector3.INF:
			var into := best_ent - from_pos
			into.y = 0.0
			return into.normalized() if into.length() > 0.05 else Vector3.ZERO

	var src := _lab_world_to_cell(from_pos)
	var dst := _lab_world_to_cell(to_pos)
	if not in_labyrinth(to_pos, 0.2) and labyrinth.has("entrance_cells"):
		# Player left the labyrinth -> route Slender out the closest entrance to the player.
		var best_c := dst
		var best_ed := 1e9
		var ents_w: Array = labyrinth["entrances"]
		var ents_c: Array = labyrinth["entrance_cells"]
		for i in ents_c.size():
			var d2 := (ents_w[i] as Vector3).distance_to(to_pos)
			if d2 < best_ed:
				best_ed = d2
				best_c = ents_c[i]
		dst = best_c
	if src == dst:
		return Vector3.ZERO

	# Backwards BFS from `dst` across the 64-cell maze.
	var dist := {dst: 0}
	var queue: Array[Vector2i] = [dst]
	var head := 0
	var dirs: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if cur == src:
			break
		var dc: int = dist[cur]
		for d in dirs:
			var nb := cur + d
			if nb.x < 0 or nb.x >= LAB_CELLS or nb.y < 0 or nb.y >= LAB_CELLS:
				continue
			if dist.has(nb) or not _lab_open_between(cur, nb):
				continue
			dist[nb] = dc + 1
			queue.append(nb)
	if not dist.has(src):
		return Vector3.ZERO
	var cur_d: int = dist[src]
	var next_cell := src
	for d in dirs:
		var nb := src + d
		if dist.has(nb) and _lab_open_between(src, nb) and int(dist[nb]) < cur_d:
			cur_d = int(dist[nb])
			next_cell = nb
	var wp := _lab_cell_to_world(next_cell)
	var v := wp - from_pos
	v.y = 0.0
	return v.normalized() if v.length() > 0.05 else Vector3.ZERO


func random_labyrinth_corridor_spot(rng_src: RandomNumberGenerator) -> Vector3:
	if not _lab_built:
		return Vector3.INF
	for _i in 16:
		var cx := rng_src.randi_range(0, LAB_CELLS - 1)
		var cz := rng_src.randi_range(0, LAB_CELLS - 1)
		if _lab_is_sanctum(cx, cz):
			continue
		var p := _lab_cell_to_world(Vector2i(cx, cz))
		if is_walkable(p, 0.45):
			return p
	return Vector3.INF


func is_walkable(p: Vector3, radius := 0.9) -> bool:
	if Vector2(p.x, p.z).length() > HALF - 2.0:
		return false
	if nearest_tree_distance(p, 900) < radius:
		return false
	if point_in_labyrinth_wall(p, minf(radius, 0.55)):
		return false
	for o in _occupied:
		if o.get("prop", false) and Vector2(p.x - o["pos"].x, p.z - o["pos"].z).length() < float(o["radius"]) + 0.8:
			return false
	return true
