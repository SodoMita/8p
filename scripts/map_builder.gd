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

signal built

var rng := RandomNumberGenerator.new()
var page_spots: Array[Dictionary] = []
var tree_positions: PackedVector3Array = PackedVector3Array()
var landmarks: Array[Dictionary] = []
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
	_mats["metal"] = _weathered_metal(Color(0.19, 0.23, 0.20), 0.46)
	_mats["rust"] = _weathered_metal(Color(0.22, 0.18, 0.14), 0.78)
	_mats["dark"] = _flat(Color(0.022, 0.022, 0.025), 0.95, 0.0)
	_mats["wood"] = _pbr("bark", 1.0, 1.0, 1.0)
	_mats["pumpkin"] = _pbr("pumpkin", 1.0, 1.0, 1.35)
	_mats["lamp"] = _flat(Color(0.42, 0.39, 0.28), 0.24, 0.15)
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

	for key in ["bark", "wood"]:
		_mats[key].vertex_color_use_as_albedo = true


func _weathered_metal(paint: Color, corrosion: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/weathered_metal.gdshader")
	mat.set_shader_parameter("paint_color", paint)
	mat.set_shader_parameter("corrosion", corrosion)
	return mat


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
func _place_landmarks(quality: int) -> void:
	var types := ["walls", "tunnel", "silo", "truck", "shed", "rocks", "bathroom", "tower"]
	_shuffle(types)
	var placed := 0
	var tries := 0
	# progressively relax spacing if the map gets crowded, so all eight always fit
	while placed < types.size() and tries < 6000:
		tries += 1
		var spacing := 30.0 if tries < 1200 else (27.0 if tries < 2600 else 24.0)
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(19.0, HALF - 13.0)
		var pos := Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		if Vector2(pos.x, pos.z).length() < 14.0:
			continue
		if _overlaps_square(pos, spacing):
			continue
		var rot := rng.randf() * TAU
		var scale := rng.randf_range(0.88, 1.22)
		var type: String = types[placed]
		_build_landmark(type, pos, rot, scale)
		_occupied.append({"pos": pos, "radius": spacing * 0.5})
		_placed_spacing.append(spacing)
		placed += 1
	if placed < types.size():
		push_warning("map_builder: only placed %d/8 landmarks" % placed)


func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func _overlaps(pos: Vector3, radius: float) -> bool:
	for o in _occupied:
		if Vector2(pos.x - o["pos"].x, pos.z - o["pos"].z).length() < radius + float(o["radius"]):
			return true
	return false


## circular spacing keeps genuinely wide corridors between landmarks
## (a square test would still allow diagonal neighbours to sit too close)
func _overlaps_square(pos: Vector3, spacing: float) -> bool:
	for l in landmarks:
		var lp: Vector3 = l["pos"]
		if Vector2(pos.x - lp.x, pos.z - lp.z).length() < spacing:
			return true
	return false


func _build_landmark(type: String, base: Vector3, rot: float, s: float) -> void:
	# all local geometry is rotated by `rot` and uniformly scaled by `s`
	var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3(s, s, s)), base)
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
	for o in _occupied:
		if o.get("prop", false) and Vector2(p.x - o["pos"].x, p.z - o["pos"].z).length() < float(o["radius"]) + 0.8:
			return true
	return false


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
	# Rolled sheet-metal bands break up the smooth primitive silhouette.
	for band in range(1, int(h / 1.15)):
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = r - 0.018
		torus.outer_radius = r + 0.035
		torus.rings = 32
		torus.ring_segments = 6
		ring.mesh = torus
		ring.material_override = _mats["rust"]
		ring.transform = xf * Transform3D(Basis(), Vector3(0, band * 1.15, 0))
		add_child(ring)
	# ladder up the side + a rusted hatch
	_box(xf, Vector3(-0.5, h * 0.45, r + 0.06), Vector3(0.09, h * 0.85, 0.09), _mats["rust"], Vector3.ZERO, false)
	_box(xf, Vector3(0.5, h * 0.45, r + 0.06), Vector3(0.09, h * 0.85, 0.09), _mats["rust"], Vector3.ZERO, false)
	for i in int(h / 0.7):
		_box(xf, Vector3(0, 0.6 + i * 0.7, r + 0.06), Vector3(1.05, 0.05, 0.05), _mats["rust"], Vector3.ZERO, false)
	_box(xf, Vector3(0, 1.0, r + 0.09), Vector3(1.0, 1.9, 0.05), _mats["dark"], Vector3.ZERO, false)


func _truck(xf: Transform3D) -> void:
	var detail_start := get_child_count()
	# Separate chassis, cab and open bed rather than one solid toy-like block.
	var metal: Material = _mats["metal"]
	var rust: Material = _mats["rust"]
	var dark: Material = _mats["dark"]
	var ln := rng.randf_range(4.6, 6.0)
	var cab_z := ln * 0.34
	_box(xf, Vector3(0, 0.72, 0), Vector3(1.8, 0.24, ln), rust)
	_box(xf, Vector3(0, 1.28, cab_z), Vector3(2.15, 0.9, 1.7), metal)
	_box(xf, Vector3(0, 1.65, cab_z + 1.03), Vector3(2.08, 0.2, 0.7), metal)
	_box(xf, Vector3(0, 2.55, cab_z), Vector3(2.23, 0.12, 1.83), metal)
	# Recessed glazing, pillars, windshield divider, door seams and handles.
	_box(xf, Vector3(0, 2.13, cab_z + 0.82), Vector3(1.91, 0.72, 0.035), dark, Vector3(-0.10, 0, 0), false)
	for side in [-1.0, 1.0]:
		_box(xf, Vector3(side * 1.04, 2.12, cab_z), Vector3(0.035, 0.70, 1.36), dark, Vector3.ZERO, false)
		for dz in [-0.81, 0.81]:
			_box(xf, Vector3(side * 1.05, 2.12, cab_z + dz), Vector3(0.09, 0.88, 0.09), metal, Vector3.ZERO, false)
		_box(xf, Vector3(side * 1.083, 1.62, cab_z - 0.35), Vector3(0.035, 0.045, 0.22), rust, Vector3.ZERO, false)
		_box(xf, Vector3(side * 1.24, 2.14, cab_z + 0.65), Vector3(0.21, 0.27, 0.10), metal, Vector3.ZERO, false)
	_box(xf, Vector3(0, 2.12, cab_z + 0.85), Vector3(0.055, 0.76, 0.05), metal, Vector3.ZERO, false)
	# Cargo bed: visibly hollow, with raised side rails and a tailgate.
	var bed_len := ln * 0.53
	var bed_z := -ln * 0.19
	_box(xf, Vector3(0, 1.0, bed_z), Vector3(2.25, 0.16, bed_len), rust)
	for side in [-1.0, 1.0]:
		_box(xf, Vector3(side * 1.08, 1.47, bed_z), Vector3(0.12, 0.85, bed_len), metal)
		for rib in 4:
			_box(xf, Vector3(side * 1.15, 1.47, bed_z - bed_len * 0.4 + rib * bed_len * 0.26), Vector3(0.06, 0.9, 0.065), rust, Vector3.ZERO, false)
	_box(xf, Vector3(0, 1.47, bed_z - bed_len * 0.5), Vector3(2.25, 0.85, 0.12), metal)
	# Wheels rotate about Z so their axle is X (old wheels stood vertically).
	for wx in [-1.12, 1.12]:
		for wz in [-ln * 0.32, -ln * 0.06, ln * 0.3]:
			var wheel := _cyl(xf, Vector3(wx, 0.53, wz), 0.53, 0.32, dark, -1.0, false)
			wheel.transform.basis = xf.basis * Basis(Vector3.FORWARD, PI * 0.5)
			var hub := _cyl(xf, Vector3(wx + signf(wx) * 0.18, 0.53, wz), 0.27, 0.045, rust, -1.0, false)
			hub.transform.basis = wheel.transform.basis
	_box(xf, Vector3(0, 0.88, cab_z + 1.4), Vector3(2.35, 0.18, 0.18), rust, Vector3.ZERO, false)
	_box(xf, Vector3(0, 1.3, cab_z + 1.39), Vector3(1.12, 0.35, 0.025), dark, Vector3.ZERO, false)
	for side in [-1.0, 1.0]:
		_box(xf, Vector3(side * 0.81, 1.4, cab_z + 1.4), Vector3(0.30, 0.24, 0.03), _mats["lamp"], Vector3.ZERO, false)

	_batch_prop_details(detail_start)


func _batch_prop_details(first_child: int) -> void:
	# Cosmetic parts share a handful of material draw calls; collision stays simple.
	var batches := {}
	var remove: Array[Node] = []
	for i in range(first_child, get_child_count()):
		var node := get_child(i)
		if node is StaticBody3D or not node is Node3D or node.get_child_count() != 1:
			continue
		var mi := node.get_child(0) as MeshInstance3D
		if mi == null:
			continue
		var mat := mi.material_override
		if not batches.has(mat):
			var surface := SurfaceTool.new()
			surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			batches[mat] = surface
		batches[mat].append_from(mi.mesh, 0, node.transform * mi.transform)
		remove.append(node)
	for node in remove:
		node.free()
	for mat in batches:
		var mi := MeshInstance3D.new()
		mi.mesh = batches[mat].commit()
		mi.material_override = mat
		mi.name = "TruckDetailBatch"
		add_child(mi)


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
		(body.get_child(0) as MeshInstance3D).mesh = _weathered_rock(rad, hh, i)
		body.rotation = xf.basis.get_rotation_quaternion().get_euler() + Vector3(rng.randf_range(-0.08, 0.08), rng.randf() * 0.6, rng.randf_range(-0.08, 0.08))
	# toppled stone in the middle
	_box(xf, Vector3(rng.randf_range(-0.8, 0.8), 0.4, rng.randf_range(-0.8, 0.8)), Vector3(1.5, 0.8, 0.9), _mats["stone"], Vector3(0.3, rng.randf() * TAU, 0.2))


func _weathered_rock(radius: float, height: float, variant: int) -> ArrayMesh:
	# Ring-correlated erosion creates fractured strata, not perfect columns.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array[PackedVector3Array] = []
	const SIDES := 9
	for j in 5:
		var row := PackedVector3Array()
		var t := j / 4.0
		for k in SIDES:
			var angle := TAU * k / SIDES
			var erosion := 1.0 + 0.16 * sin(k * 2.73 + variant * 1.7) + 0.075 * cos(j * 4.1 + k)
			var r := radius * erosion * (1.0 - 0.43 * t)
			row.append(Vector3(cos(angle) * r + t * 0.09, (t - 0.5) * height + sin(k * 3.4 + variant) * 0.09 * t, sin(angle) * r))
		rings.append(row)
	for j in 4:
		for k in SIDES:
			var n := (k + 1) % SIDES
			for v in [rings[j][k], rings[j + 1][n], rings[j + 1][k], rings[j][k], rings[j][n], rings[j + 1][n]]:
				st.set_uv(Vector2(v.x + v.z * 0.4, v.y) * 0.6)
				st.add_vertex(v)
	for k in SIDES:
		for v in [Vector3(0.09, height * 0.5, 0), rings[4][k], rings[4][(k + 1) % SIDES]]:
			st.set_uv(Vector2(v.x, v.z))
			st.add_vertex(v)
	st.generate_normals()
	st.generate_tangents()
	st.index()
	return st.commit()


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
	for l in landmarks:
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
			var centre: Vector3 = lm["pos"]
			var radius: float = float(lm["radius"])
			for k in rng.randi_range(2, 5):
				var a := rng.randf() * TAU
				var d := radius * rng.randf_range(0.55, 1.15)
				var p := centre + Vector3(cos(a) * d, 0.0, sin(a) * d)
				if _point_inside_prop(p):
					continue
				spots.append(p)
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
			var lift := Vector3(0, 0.27 * s, 0) if not tipped else Vector3(0, 0.19 * s, 0)
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
			if _point_inside_prop(p) or _too_close(p, 1.4):
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
		if _point_inside_prop(p):
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


func is_walkable(p: Vector3, radius := 0.9) -> bool:
	if Vector2(p.x, p.z).length() > HALF - 2.0:
		return false
	if nearest_tree_distance(p, 900) < radius:
		return false
	return not _point_inside_prop(p)
