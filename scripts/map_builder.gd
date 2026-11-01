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
const TERRAIN_SHAPE_AMPLITUDE := 0.84
const TERRAIN_DETAIL_AMPLITUDE := 0.22
const TERRAIN_EDGE_FADE := 12.0
const TERRAIN_PAD_FADE := 5.0
const TREES_DESKTOP := 620
const TREES_MOBILE := 430
const DEAD_TREE_MESHES := 6
const SNAG_MESHES := 2
const PUMPKIN_MESHES := 3
const BUSH_MESHES := 3
const LAB_CELLS := 10
const LAB_CELL := 2.45
const LAB_WALL_THICK := 0.36
const LAB_HALF := LAB_CELLS * LAB_CELL * 0.5  # 12.25 m (24.5 x 24.5 m footprint)
const TreeCollisionMesh = preload("res://scripts/tree_collision.gd")
const TerrainSurfaceMesh = preload("res://scripts/terrain_surface.gd")

signal built

var rng := RandomNumberGenerator.new()
var page_spots: Array[Dictionary] = []
# set by each landmark builder: a surface point (landmark-local) and its outward
# normal, so a page is pinned to something real instead of floating in a clearing
var _attach_hint: Dictionary = {}
var GATE_OPEN_HALF := GATE_HALF   # effective gate opening, set by _boundary()
var gate_leaf_half := GATE_HALF
var boundary_panels: Array = []
var boundary_gate_leaves: Array = []
var boundary_rails: Array = []
var boundary_posts: Array = []
var tree_positions: PackedVector3Array = PackedVector3Array()
var tree_collision_instances: Array[Dictionary] = []
var landmarks: Array[Dictionary] = []
var labyrinth: Dictionary = {}
var world_seed := 0

var _mats := {}
var _noise := FastNoiseLite.new()
var _density := FastNoiseLite.new()
var _terrain_shape := FastNoiseLite.new()
var _terrain_detail := FastNoiseLite.new()
var _terrain_origin_height := 0.0
var _terrain_pads: Array[Dictionary] = []
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
	_terrain_shape.seed = seed_value + 431
	_terrain_shape.frequency = 0.014
	_terrain_shape.fractal_octaves = 3
	_terrain_detail.seed = seed_value + 971
	_terrain_detail.frequency = 0.042
	_terrain_detail.fractal_octaves = 2
	_terrain_pads.clear()
	_terrain_origin_height = _raw_terrain_height(0.0, 0.0)

	_load_meshes()
	_make_materials()
	# A level spawn clearing keeps the first moments readable; the rest of the
	# forest rolls naturally and each landmark gets its own gently blended pad.
	_add_terrain_pad(Vector3.ZERO, 9.0, 0.0, 4.0)
	_place_landmarks(quality)
	_ground()
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
func _pbr(name: String, repeats_per_metre := 1.0, rough := 1.0, normal_scale := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/%s_albedo.png" % name)
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/%s_normal.png" % name)
	m.normal_scale = normal_scale
	m.roughness_texture = load("res://assets/textures/%s_rough.png" % name)
	m.roughness = rough
	m.metallic = 0.0
	m.metallic_specular = 0.35
	# All PBR channels use the same world-space projection, including normals.
	# UV scale is repeats per world metre, not repeats per mesh UV island.
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_triplanar_sharpness = 4.0
	m.uv1_scale = Vector3.ONE * repeats_per_metre
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.texture_repeat = true
	# every surface in this wood is double sided: the walls are broken, the
	# truck's bed is open and the shed's planks are single quads, so a culled
	# back face reads as a hole straight into the fog
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Metre-space triplanar PBR (stone rotates with the object, scale does not stretch): the texture is projected in metres on all three
## axes, so a 2048 px map at `metres_per_repeat` gives the same texel density on
## a 1 m pillar and a 20 m wall - nothing stretches, nothing looks low-res.
func _triplanar(tex: String, metres_per_repeat: float, rough: float, normal_scale: float) -> Material:
	if tex == "stone":
		var surface := ShaderMaterial.new()
		surface.shader = load("res://shaders/concrete_surface.gdshader")
		surface.set_shader_parameter("albedo_map", load("res://assets/textures/stone_albedo.png"))
		surface.set_shader_parameter("normal_map", load("res://assets/textures/stone_normal.png"))
		surface.set_shader_parameter("roughness_map", load("res://assets/textures/stone_rough.png"))
		surface.set_shader_parameter("metres_per_repeat", metres_per_repeat)
		surface.set_shader_parameter("normal_strength", normal_scale)
		surface.set_shader_parameter("roughness_multiplier", rough)
		return surface
	var m := StandardMaterial3D.new()
	m.albedo_texture = load("res://assets/textures/%s_albedo.png" % tex)
	m.normal_enabled = true
	m.normal_texture = load("res://assets/textures/%s_normal.png" % tex)
	m.normal_scale = normal_scale
	m.roughness_texture = load("res://assets/textures/%s_rough.png" % tex)
	m.roughness = rough
	m.metallic = 0.0
	m.metallic_specular = 0.35
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * (1.0 / maxf(metres_per_repeat, 0.05))
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.texture_repeat = true
	return m


func _make_materials() -> void:
	# Trees carry world-space UVs baked in the mesh generator, so scale 1 -- and
	# the same world-anchored projection the model pass added, so no parent or
	# MultiMesh scale can stretch the texels.
	#
	# Bark is dark to begin with (albedo mean 0.20 linear) and the normal map is
	# steep (18 deg mean tilt), so at grazing angles a lit trunk used to fall to
	# nothing but a few highlights. Lift the albedo, soften the relief and use a
	# wrapped diffuse term so the terminator does not go black.
	# 0.62 uv scale: the plate grid is ~8 across a texture repeat, so at 1.0 the
	# plates came out about 12 cm wide on a 40 cm trunk and read as scales rather
	# than bark. Stretching the repeat makes each plate a hand's width.
	_mats["bark"] = _pbr("bark", 0.62, 1.0, 0.75)
	# OBJECT space, not world space, for bark and planks. World-space projection
	# anchors the texture to the world, so as soon as the trunk bends or sways the
	# surface slides through the pattern instead of turning with it - the bark
	# appears to crawl. Object space rides the deformation.
	_mats["bark"].uv1_world_triplanar = false
	_mats["bark"].albedo_color = Color(1.55, 1.50, 1.42)
	_mats["bark"].diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	_mats["bark_coll"] = _mats["bark"]
	# 2048 px over 2 m -> ~1000 px/m of dirt detail everywhere
	_mats["ground"] = _triplanar("ground", 2.0, 1.0, 1.0)
	# 2048 px over 1.2 m -> ~1700 px/m on every concrete and stone face,
	# independent of how big the surface is
	_mats["stone"] = _triplanar("stone", 1.2, 0.95, 1.0)
	# concrete goes through the rotation-following metre projection too, now that it
	# blends cracks into the real stone maps rather than faking them with noise
	_mats["concrete"] = _triplanar("stone", 1.2, 1.0, 0.85)
	_mats["metal"] = _weathered_metal(Color(0.19, 0.23, 0.20), 0.46)
	_mats["rust"] = _weathered_metal(Color(0.22, 0.18, 0.14), 0.78)
	_mats["dark"] = _flat(Color(0.022, 0.022, 0.025), 0.95, 0.0)
	_mats["wood"] = _pbr("bark", 0.75, 1.0, 0.65)
	_mats["wood"].uv1_world_triplanar = false
	_mats["wood"].albedo_color = Color(1.42, 1.38, 1.31)
	_mats["wood"].diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	# The stump's top is a separately UV-mapped end-grain surface. Do not use
	# bark triplanar here: that was why the cut face read as more bark.
	_mats["endgrain"] = _pbr("endgrain", 1.0, 0.96, 0.40)
	_mats["endgrain"].uv1_triplanar = false
	_mats["endgrain"].uv1_world_triplanar = false
	_mats["endgrain"].albedo_color = Color(1.45, 1.24, 1.04)
	_mats["endgrain"].diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	var stump_resource: Mesh = _props.get("stump")
	if stump_resource != null and stump_resource.get_surface_count() >= 2:
		# ResourceLoader caches meshes globally; duplicate before setting per-map
		# materials so a second procedural run cannot replace the first map's
		# bark/end-grain references.
		stump_resource = stump_resource.duplicate() as Mesh
		_props["stump"] = stump_resource
		stump_resource.surface_set_material(0, _mats["bark"])
		stump_resource.surface_set_material(1, _mats["endgrain"])
	# approved pumpkin rind from the restore branch (its own shader material)
	var pumpkin_skin := ShaderMaterial.new()
	pumpkin_skin.shader = load("res://shaders/pumpkin_skin.gdshader")
	_mats["pumpkin"] = pumpkin_skin
	_mats["lamp"] = _flat(Color(0.42, 0.39, 0.28), 0.24, 0.15)
	# the labyrinth's industrial dressing
	_mats["lab_wall"] = _triplanar("stone", 0.9, 0.96, 1.35)
	_mats["lab_floor"] = _triplanar("stone", 1.0, 0.98, 1.15)
	_mats["lab_metal"] = _flat(Color(1.0, 1.0, 1.0), 0.46, 0.72)
	_mats["lab_wire"] = _flat(Color(1.0, 1.0, 1.0), 0.40, 0.22)

	var link := StandardMaterial3D.new()
	link.albedo_texture = load("res://assets/textures/chainlink.png")
	link.albedo_color = Color(0.72, 0.74, 0.78)
	link.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	link.alpha_scissor_threshold = 0.42
	link.cull_mode = BaseMaterial3D.CULL_DISABLED
	link.metallic = 0.55
	link.roughness = 0.62
	link.uv1_scale = Vector3(6.0, 4.2, 1.0)   # ~5 cm diamonds on a 3 m panel
	link.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_mats["chainlink"] = link
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

	# StandardMaterial3D can fold vertex colour into albedo; ShaderMaterial cannot
	# (the concrete/stone shader multiplies COLOR in itself), so only touch the
	# ones that actually have the property.
	for key in ["bark", "wood", "lab_wall", "lab_floor", "lab_metal", "lab_wire"]:
		var m: Material = _mats[key]
		if m is StandardMaterial3D:
			(m as StandardMaterial3D).vertex_color_use_as_albedo = true


func _procedural_surface(shader_name: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/%s.gdshader" % shader_name)
	return mat


func _chamfered_concrete(size: Vector3, pos: Vector3) -> ArrayMesh:
	# Real edge geometry catches the flashlight; collision remains a simple box.
	var h := size * 0.5
	var bevel := minf(minf(size.x, size.y), size.z) * 0.18
	bevel = minf(bevel, 0.065) * (0.8 + 0.2 * sin(pos.x * 7.1 + pos.z * 3.9))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for axis in 3:
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		for side in [-1.0, 1.0]:
			var points: Array[Vector3] = []
			for corner in [Vector2(-1,-1), Vector2(1,-1), Vector2(1,1), Vector2(-1,1)]:
				var p := Vector3.ZERO
				p[axis] = h[axis] * side
				p[u] = (h[u] - bevel) * corner.x
				p[v] = (h[v] - bevel) * corner.y
				points.append(p)
			var n := Vector3.ZERO
			n[axis] = side
			_concrete_face(st, points, n)
	# Twelve bevel strips, then eight triangular corner chips.
	for axis in 3:
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		for su in [-1.0, 1.0]:
			for sv in [-1.0, 1.0]:
				var points: Array[Vector3] = []
				for c in [Vector2(-1,0), Vector2(1,0), Vector2(1,1), Vector2(-1,1)]:
					var p := Vector3.ZERO
					p[axis] = (h[axis] - bevel) * c.x
					p[u] = (h[u] - bevel * c.y) * su
					p[v] = (h[v] - bevel * (1.0 - c.y)) * sv
					points.append(p)
				var n := Vector3.ZERO
				n[u] = su
				n[v] = sv
				_concrete_face(st, points, n.normalized())
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				var sign_vec := Vector3(x,y,z)
				var points: Array[Vector3] = []
				for axis in 3:
					var p := (h - Vector3.ONE * bevel) * sign_vec
					p[axis] = h[axis] * sign_vec[axis]
					points.append(p)
				_concrete_face(st, points, sign_vec.normalized())
	st.index()
	return st.commit()


func _concrete_face(st: SurfaceTool, points: Array[Vector3], n: Vector3) -> void:
	for i in range(1, points.size() - 1):
		var tri := [points[0], points[i], points[i + 1]]
		if (tri[1] - tri[0]).cross(tri[2] - tri[0]).dot(n) > 0.0:
			tri.reverse()
		for p in tri:
			st.set_normal(n)
			st.set_uv(Vector2(p.x + p.z, p.y))
			st.add_vertex(p)


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
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# --------------------------------------------------------------------------- #
# ground
# --------------------------------------------------------------------------- #
func _ground() -> void:
	var terrain_mesh: ArrayMesh = TerrainSurfaceMesh.build_grid(
		Vector3.ZERO, Vector2(150.0, 150.0), 75, 75,
		Callable(self, "ground_height_at"))
	var mi := MeshInstance3D.new()
	mi.name = "GroundMesh"
	mi.mesh = terrain_mesh
	mi.material_override = _mats["ground"]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	var floor_body := StaticBody3D.new()
	floor_body.name = "GroundCollision"
	floor_body.collision_layer = 4 # dedicated terrain layer; anchor rays ignore the ground
	floor_body.collision_mask = 5 # player and loose physical page nails
	var terrain_shape := CollisionShape3D.new()
	terrain_shape.name = "TerrainTriangles"
	terrain_shape.shape = terrain_mesh.create_trimesh_shape()
	floor_body.add_child(terrain_shape)
	# A buried safety slab catches only a fall through a missing terrain chunk;
	# its top is safely below the lowest procedural valley.
	var safety_shape := CollisionShape3D.new()
	safety_shape.name = "SafetyFloor"
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(150.0, 3.0, 150.0)
	safety_shape.shape = floor_box
	safety_shape.position = Vector3(0.0, -3.0, 0.0)
	floor_body.add_child(safety_shape)
	add_child(floor_body)


func _raw_terrain_height(x: float, z: float) -> float:
	return _terrain_shape.get_noise_2d(x, z) * TERRAIN_SHAPE_AMPLITUDE \
		+ _terrain_detail.get_noise_2d(x, z) * TERRAIN_DETAIL_AMPLITUDE


func _smooth_01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Shared height query for the arena and the streamed outside terrain. The square
## fence edge eases to sea level so the gate, posts and road meet without a lip.
func ground_height_at(point: Vector3) -> float:
	var edge := HALF + 1.0 - maxf(absf(point.x), absf(point.z))
	var edge_blend := _smooth_01(absf(edge) / TERRAIN_EDGE_FADE)
	var raw := (_raw_terrain_height(point.x, point.z) - _terrain_origin_height) * edge_blend
	var height := raw
	for pad in _terrain_pads:
		var centre: Vector3 = pad["centre"]
		var distance := Vector2(point.x - centre.x, point.z - centre.z).length()
		var radius := float(pad["radius"])
		if distance <= radius:
			return float(pad["height"])
		var fade := float(pad["fade"])
		if fade > 0.0 and distance < radius + fade:
			var blend := _smooth_01((distance - radius) / fade)
			height = lerpf(float(pad["height"]), raw, blend)
	return height


func _add_terrain_pad(centre: Vector3, radius: float, height: float, fade := TERRAIN_PAD_FADE) -> void:
	_terrain_pads.append({
		"centre": Vector3(centre.x, 0.0, centre.z),
		"radius": radius,
		"height": height,
		"fade": fade,
	})


# --------------------------------------------------------------------------- #
# boundary: a real chain-link fence — posts, fabric panels, rails and a gate
# --------------------------------------------------------------------------- #
const FENCE_SIDE := 61.0        # distance of each fence run from the centre
const PANEL_WIDTH := 3.0        # one fabric panel / one post spacing, metres
const POST_HEIGHT := 2.35
const FENCE_FABRIC_H := 2.05
const GATE_HALF := 2.5          # half the opening, metres

var gate_centre := Vector3(FENCE_SIDE, 0.0, 0.0)


func _boundary() -> void:
	var body := StaticBody3D.new()
	body.name = "FenceBody"
	add_child(body)

	# --- shared meshes -----------------------------------------------------
	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = 0.042
	post_mesh.bottom_radius = 0.052
	post_mesh.height = POST_HEIGHT
	post_mesh.radial_segments = 6
	post_mesh.rings = 1

	var rail_mesh := BoxMesh.new()
	rail_mesh.size = Vector3(PANEL_WIDTH, 0.05, 0.05)

	var panel_mesh := PlaneMesh.new()
	panel_mesh.size = Vector2(PANEL_WIDTH, FENCE_FABRIC_H)
	panel_mesh.orientation = PlaneMesh.FACE_Z

	var posts: Array = []
	var rails: Array = []
	var panels: Array = []

	# Four runs; side 0 (+X) carries the gate.
	#
	# Each run spans the FULL side, corner to corner. It used to be truncated to a
	# whole number of panels (`int(FENCE_SIDE / PANEL_WIDTH)`), which left the run
	# 2 m short of both corners: with FENCE_SIDE 61 and 3 m panels that is a 1 m
	# gap at every run end, and two of them meeting at a corner made a 2x2 m hole.
	# Now the bay count is rounded UP and the bay width derived from it, so the
	# fabric reaches the corner exactly; the slight width change is absorbed by
	# scaling each panel along its length.
	var run_length := FENCE_SIDE * 2.0
	var bays := int(ceil(run_length / PANEL_WIDTH))
	var bay_w := run_length / float(bays)
	# the gate opening has to be a whole number of bays, so measure the opening the
	# bays actually leave and hang the leaves on that
	var gate_open_half := GATE_HALF
	for bay in bays:
		var tc := (float(bay) + 0.5) * bay_w - run_length * 0.5
		if absf(tc) < GATE_HALF:
			gate_open_half = maxf(gate_open_half, absf(tc) + bay_w * 0.5)
	for side in 4:
		var ang := TAU * float(side) / 4.0
		var out := Vector3(cos(ang), 0.0, sin(ang))
		var along := Vector3(-sin(ang), 0.0, cos(ang))
		for bay in bays:
			# panel centre, measured along the run
			var t := (float(bay) + 0.5) * bay_w - run_length * 0.5
			var centre: Vector3 = out * FENCE_SIDE + along * t
			var in_gate := side == 0 and absf(t) < gate_open_half - 0.001
			if in_gate:
				continue
			# the panel spans the run, not the outward normal; scale it to the
			# derived bay width so the run closes on the corner
			var b := _along_basis(along).scaled(Vector3(bay_w / PANEL_WIDTH, 1.0, 1.0))
			panels.append(Transform3D(b, centre + Vector3(0, FENCE_FABRIC_H * 0.5 + 0.04, 0)))
			# top rail, same direction as the fabric it clamps
			rails.append(Transform3D(b, centre + Vector3(0, FENCE_FABRIC_H + 0.08, 0)))
			# one fabric collider per panel: thin slab exactly on the fence line
			var shape := BoxShape3D.new()
			shape.size = Vector3(bay_w, FENCE_FABRIC_H, 0.1)
			var col := CollisionShape3D.new()
			col.shape = shape
			col.transform = Transform3D(b, centre + Vector3(0, FENCE_FABRIC_H * 0.5 + 0.04, 0))
			body.add_child(col)
		# posts between bays (shared, so bays + 1). The LAST one sits exactly on the
		# corner, where the next run's first post already is, so it is skipped
		# rather than drawn twice in the same place.
		for p_i in bays + 1:
			if p_i == bays:
				continue
			var t2 := float(p_i) * bay_w - run_length * 0.5
			var ppos: Vector3 = out * FENCE_SIDE + along * t2
			if side == 0 and absf(t2) <= gate_open_half + 0.01:
				continue
			# sunk 0.35 m into the ground so the fence sits IN the terrain
			posts.append(Transform3D(Basis.IDENTITY, ppos + Vector3(0, POST_HEIGHT * 0.5 - 0.35, 0)))
			var pshape := CylinderShape3D.new()
			pshape.radius = 0.09
			pshape.height = POST_HEIGHT + 0.7
			var pcol := CollisionShape3D.new()
			pcol.shape = pshape
			pcol.position = ppos + Vector3(0, POST_HEIGHT * 0.5 - 0.35, 0)
			body.add_child(pcol)
		if side == 0:
			gate_leaf_half = gate_open_half
			GATE_OPEN_HALF = gate_open_half
			_gate_leaves(body, panels, rails, gate_open_half)

	# keep what we built: MultiMesh.get_instance_transform() returns identity in a
	# headless run, so the tests read these instead of the GPU buffer
	boundary_panels = panels
	boundary_rails = rails
	boundary_posts = posts

	_add_multimesh(panel_mesh, _mats["chainlink"], panels, _blank_tints(panels.size()), "FencePanels")
	_add_multimesh(post_mesh, _mats["metal"], posts, _blank_tints(posts.size()), "FencePosts")
	_add_multimesh(rail_mesh, _mats["metal"], rails, _blank_tints(rails.size()), "FenceRails")


## A basis for a flat panel that spans `dir` and stands upright.
## Local X becomes the panel's length, local Y is up, local Z is the face normal.
## Deriving the yaw by hand is what put the fence panels at 90 degrees: the old
## `face_yaw` pointed the panel's *width* along the outward normal.
func _along_basis(dir: Vector3) -> Basis:
	var x := Vector3(dir.x, 0.0, dir.z).normalized()
	if x.length() < 0.5:
		x = Vector3.RIGHT
	var z := x.cross(Vector3.UP).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


func _blank_tints(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(Color(1, 1, 1))
	return out


func _gate_leaves(body: StaticBody3D, panels: Array, rails: Array, open_half: float) -> void:
	# Two leaves hinged on the gate posts. They start CLOSED and shut the opening:
	# they used to be modelled swung open into the forest, so the road left through
	# a permanently open gate and the fence had a hole in it from the first frame.
	# The opening is still a real opening - the leaves are the thing that closes it.
	gate_centre = Vector3(FENCE_SIDE, 0.0, 0.0)
	var out := Vector3(1, 0, 0)
	for sgn_f in [-1.0, 1.0]:
		var sgn: float = sgn_f
		var hinge: Vector3 = gate_centre + Vector3(0, 0, sgn * open_half)
		var swing: float = 0.0           # starts CLOSED; see _gate_leaves note
		var yaw: float = swing
		var leaf_w := open_half - 0.1
		var leaf_dir: Vector3 = Vector3(cos(yaw), 0, sin(yaw)) * sgn
		var centre: Vector3 = hinge + leaf_dir * (leaf_w * 0.5)
		var b := _along_basis(leaf_dir)
		var leaf_xf := Transform3D(b, centre + Vector3(0, FENCE_FABRIC_H * 0.5 + 0.04, 0))
		panels.append(leaf_xf)
		boundary_gate_leaves.append(leaf_xf)
		rails.append(Transform3D(b, centre + Vector3(0, FENCE_FABRIC_H + 0.08, 0)))
		var shape := BoxShape3D.new()
		shape.size = Vector3(leaf_w, FENCE_FABRIC_H, 0.1)
		var col := CollisionShape3D.new()
		col.shape = shape
		col.transform = Transform3D(b, centre + Vector3(0, FENCE_FABRIC_H * 0.5 + 0.04, 0))
		body.add_child(col)
		# gate post
		var pshape := CylinderShape3D.new()
		pshape.radius = 0.1
		pshape.height = POST_HEIGHT + 0.7
		var pcol := CollisionShape3D.new()
		pcol.shape = pshape
		pcol.position = hinge + Vector3(0, POST_HEIGHT * 0.5 - 0.35, 0)
		body.add_child(pcol)


# --------------------------------------------------------------------------- #
# landmark placement — fully randomised
# --------------------------------------------------------------------------- #
func _place_landmarks(_quality: int) -> void:
	# 1) Place the procedural stone labyrinth first so it gets clean ground
	#    well clear of both the central spawn clearing and the outer fence.
	var lab_ang := rng.randf() * TAU
	var lab_dist := rng.randf_range(31.5, 39.2)
	var lab_pos := Vector3(cos(lab_ang) * lab_dist, 0.0, sin(lab_ang) * lab_dist)
	var lab_rot := float(rng.randi_range(0, 3)) * (PI * 0.5) + rng.randf_range(-0.04, 0.04)
	_build_landmark("labyrinth", lab_pos, lab_rot, 1.0)
	_occupied.append({"pos": lab_pos, "radius": 17.2})
	_placed_spacing.append(29.0)

	# 2) Scatter the remaining seven set pieces around the forest.
	var types := ["tunnel", "silo", "truck", "shed", "rocks", "bathroom", "tower"]
	_shuffle(types)
	var placed := 0
	var tries := 0
	# progressively relax spacing if the map gets crowded, so all eight always fit
	while placed < types.size() and tries < 8000:
		tries += 1
		var spacing := 29.0 if tries < 1500 else (26.0 if tries < 3600 else 22.8)
		var lab_gap := 28.8 if tries < 3600 else 25.8
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
	# Place the set piece on a locally flattened patch so its foundations and
	# page anchors stay in contact while the surrounding forest rolls.
	base.y = ground_height_at(base)
	var pad_radius := (17.5 if type == "labyrinth" else 14.5) * s
	_add_terrain_pad(base, pad_radius, base.y)
	# all local geometry is rotated by `rot` and uniformly scaled by `s`
	var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3(s, s, s)), base)
	if type == "labyrinth":
		# _labyrinth() builds its own geometry and leaves the page anchor in
		# _attach_hint, so it has to go through the same page-spot path as every
		# other landmark instead of returning early (that early return is why the
		# maze had no pinned page once its hand-rolled one was removed).
		_labyrinth(xf, base, rot)
		_add_page_spot(type, xf)
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
	# The landmark told us where its surface is, so the page is pinned to it:
	# the spot is a point on that surface and the normal points out of it.
	if not _attach_hint.is_empty():
		var hp: Vector3 = xf * (_attach_hint["pos"] as Vector3)
		var hn: Vector3 = (xf.basis * (_attach_hint["n"] as Vector3)).normalized()
		_attach_hint = {}
		page_spots.append({"pos": hp, "normal": hn, "name": type})
		return
	# No surface hint (an older landmark or a new one that has not learned to
	# offer one): fall back to a clear spot near the landmark rather than open
	# air, and give it a normal facing away from the landmark centre.
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
		var out: Vector3 = (world - xf.origin)
		out.y = 0.0
		page_spots.append({"pos": world, "normal": out.normalized(), "name": type})
		return
		return
	var p: Vector3 = xf * (_attach_hint["pos"] as Vector3)
	var n: Vector3 = (xf.basis * (_attach_hint["n"] as Vector3)).normalized()
	_attach_hint = {}
	page_spots.append({"pos": p, "normal": n, "name": type})


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
	mi.mesh = _chamfered_concrete(size, pos) if mat == _mats.get("concrete") else box
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
# procedural stone labyrinth + electric wire network + spatial reverb zone
# --------------------------------------------------------------------------- #
func _lab_grid_coord(g: int) -> float:
	return (float(g) - float(LAB_CELLS) * 0.5) * LAB_CELL


func _lab_cell_coord(c: int) -> float:
	return (float(c) - float(LAB_CELLS) * 0.5 + 0.5) * LAB_CELL


func _labyrinth(xf: Transform3D, base: Vector3, rot: float) -> void:
	_lab_built = true
	_lab_xf = xf
	_lab_inv_xf = xf.affine_inverse()
	_lab_wall_rects.clear()
	_lab_h_wall.clear()
	_lab_v_wall.clear()

	var mid: int = LAB_CELLS / 2  # 5 on a 10x10 grid -> sanctum at (4..5, 4..5)

	# 1) Initialize 10x10 cell wall grids (all closed) + visited table.
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

	# 2) Carve the 2x2 Central Sanctum at (mid-1..mid, mid-1..mid).
	_lab_v_wall[mid - 1][mid] = false
	_lab_v_wall[mid][mid] = false
	_lab_h_wall[mid][mid - 1] = false
	_lab_h_wall[mid][mid] = false
	for sz in [mid - 1, mid]:
		for sx in [mid - 1, mid]:
			visited[int(sz)][int(sx)] = true

	# 3) Open two Sanctum thresholds on distinct faces and seed DFS from them.
	var faces := [0, 1, 2, 3]
	_shuffle(faces)
	var archways: Array[Dictionary] = []
	var stack: Array[Vector2i] = []
	for fi in 2:
		var face: int = faces[fi]
		var k: int = (mid - 1) if rng.randf() < 0.5 else mid
		var ring_cell := Vector2i.ZERO
		match face:
			0:  # North face of sanctum
				_lab_h_wall[mid - 1][k] = false
				ring_cell = Vector2i(k, mid - 2)
				archways.append({"pos": Vector3(_lab_cell_coord(k), 0.0, _lab_grid_coord(mid - 1)), "horiz": true, "outer": false})
			1:  # South face of sanctum
				_lab_h_wall[mid + 1][k] = false
				ring_cell = Vector2i(k, mid + 1)
				archways.append({"pos": Vector3(_lab_cell_coord(k), 0.0, _lab_grid_coord(mid + 1)), "horiz": true, "outer": false})
			2:  # West face of sanctum
				_lab_v_wall[k][mid - 1] = false
				ring_cell = Vector2i(mid - 2, k)
				archways.append({"pos": Vector3(_lab_grid_coord(mid - 1), 0.0, _lab_cell_coord(k)), "horiz": false, "outer": false})
			3:  # East face of sanctum
				_lab_v_wall[k][mid + 1] = false
				ring_cell = Vector2i(mid + 1, k)
				archways.append({"pos": Vector3(_lab_grid_coord(mid + 1), 0.0, _lab_cell_coord(k)), "horiz": false, "outer": false})
		visited[ring_cell.y][ring_cell.x] = true
		stack.append(ring_cell)

	# 4) Iterative randomized DFS backtracker over the 96 outer corridor cells.
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

	# 5) Braid ~40% of dead ends for cat-and-mouse loops while preserving traps.
	var dead_ends: Array[Vector2i] = []
	for cz in LAB_CELLS:
		for cx in LAB_CELLS:
			if _lab_is_sanctum(cx, cz):
				continue
			if _lab_cell_open_degree(cx, cz) == 1:
				dead_ends.append(Vector2i(cx, cz))
	_shuffle(dead_ends)
	var braid_target := int(dead_ends.size() * 0.40)
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

	# 6) Carve 4 outer stone portals (off-axis slots {1,2,3,6,7,8} on N/S/W/E).
	var edge_slots := [1, 2, 3, 6, 7, 8]
	var entrance_cells: Array[Vector2i] = []
	var entrance_world: Array[Vector3] = []

	var kn: int = edge_slots[rng.randi_range(0, edge_slots.size() - 1)]
	_lab_h_wall[0][kn] = false
	entrance_cells.append(Vector2i(kn, 0))
	var gn := Vector3(_lab_cell_coord(kn), 0.0, -LAB_HALF)
	archways.append({"pos": gn, "horiz": true, "outer": true})
	entrance_world.append(xf * gn)

	var ks: int = edge_slots[rng.randi_range(0, edge_slots.size() - 1)]
	_lab_h_wall[LAB_CELLS][ks] = false
	entrance_cells.append(Vector2i(ks, LAB_CELLS - 1))
	var gs := Vector3(_lab_cell_coord(ks), 0.0, LAB_HALF)
	archways.append({"pos": gs, "horiz": true, "outer": true})
	entrance_world.append(xf * gs)

	var kw: int = edge_slots[rng.randi_range(0, edge_slots.size() - 1)]
	_lab_v_wall[kw][0] = false
	entrance_cells.append(Vector2i(0, kw))
	var gw := Vector3(-LAB_HALF, 0.0, _lab_cell_coord(kw))
	archways.append({"pos": gw, "horiz": false, "outer": true})
	entrance_world.append(xf * gw)

	var ke: int = edge_slots[rng.randi_range(0, edge_slots.size() - 1)]
	_lab_v_wall[ke][LAB_CELLS] = false
	entrance_cells.append(Vector2i(LAB_CELLS - 1, ke))
	var ge := Vector3(LAB_HALF, 0.0, _lab_cell_coord(ke))
	archways.append({"pos": ge, "horiz": false, "outer": true})
	entrance_world.append(xf * ge)

	# 6b) Where the page hangs. The maze has no open plaza to pin a sheet to, so
	# pick a corridor cell and one of the walls that is still standing around it,
	# then use the face that looks INTO the cell: the sheet is then on stone, at
	# hand height, with the corridor in front of it rather than a wall.
	var hint_set := false
	for attempt in 60:
		var sc := Vector2i(rng.randi_range(0, LAB_CELLS - 1), rng.randi_range(0, LAB_CELLS - 1))
		var faces_open: Array[String] = []
		if _lab_h_wall[sc.y][sc.x]:
			faces_open.append("north")
		if _lab_h_wall[sc.y + 1][sc.x]:
			faces_open.append("south")
		if _lab_v_wall[sc.y][sc.x]:
			faces_open.append("west")
		if _lab_v_wall[sc.y][sc.x + 1]:
			faces_open.append("east")
		if faces_open.is_empty():
			continue
		var face: String = faces_open[rng.randi_range(0, faces_open.size() - 1)]
		var cx := _lab_cell_coord(sc.x)
		var cz := _lab_cell_coord(sc.y)
		var half_t := LAB_WALL_THICK * 0.5
		match face:
			"north":
				_attach_hint = {"pos": Vector3(cx, 1.45, -LAB_HALF + sc.y * LAB_CELL + half_t), "n": Vector3(0, 0, 1)}
			"south":
				_attach_hint = {"pos": Vector3(cx, 1.45, -LAB_HALF + (sc.y + 1) * LAB_CELL - half_t), "n": Vector3(0, 0, -1)}
			"west":
				_attach_hint = {"pos": Vector3(-LAB_HALF + sc.x * LAB_CELL + half_t, 1.45, cz), "n": Vector3(1, 0, 0)}
			_:
				_attach_hint = {"pos": Vector3(-LAB_HALF + (sc.x + 1) * LAB_CELL - half_t, 1.45, cz), "n": Vector3(-1, 0, 0)}
		hint_set = true
		break
	if not hint_set:
		push_warning("labyrinth: no standing corridor wall found for the page")

	# 7) Batched mesh builders: Floor, Stonework, Industrial Metal, Electric Wires.
	var body := StaticBody3D.new()
	body.name = "LabyrinthBody"
	body.transform = xf
	add_child(body)

	var st_floor := SurfaceTool.new()
	st_floor.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_wall := SurfaceTool.new()
	st_wall.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_metal := SurfaceTool.new()
	st_metal.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_wires := SurfaceTool.new()
	st_wires.begin(Mesh.PRIMITIVE_TRIANGLES)

	var metal_dark := Color(0.18, 0.19, 0.21)
	var metal_rust := Color(0.31, 0.19, 0.12)
	var ceramic_col := Color(0.75, 0.74, 0.69)
	var wire_black := Color(0.065, 0.068, 0.078)
	var wire_braid := Color(0.115, 0.095, 0.080)
	var wire_copper := Color(0.76, 0.45, 0.20)

	# --- 7a) Jointed flagstone pavement + intersection iron drain grates ------
	_st_add_box(st_floor, Vector3(0.0, -0.03, 0.0),
		Vector3(LAB_HALF * 2.0 + 0.95, 0.12, LAB_HALF * 2.0 + 0.95),
		Color(0.34, 0.35, 0.37), Vector3.ZERO, false, 1.85)
	var slab_w := LAB_CELL * 0.455
	var slab_step := LAB_CELL * 0.25
	for cz in LAB_CELLS:
		var cell_z := _lab_cell_coord(cz)
		for cx in LAB_CELLS:
			var cell_x := _lab_cell_coord(cx)
			var in_sanc := _lab_is_sanctum(cx, cz)
			for sz_i in 2:
				for sx_i in 2:
					var ox := (-slab_step if sx_i == 0 else slab_step)
					var oz := (-slab_step if sz_i == 0 else slab_step)
					var sh_f := rng.randf_range(0.50, 0.72) if not in_sanc else rng.randf_range(0.58, 0.78)
					var h_j := rng.randf_range(0.036, 0.048)
					_st_add_box(st_floor, Vector3(cell_x + ox, h_j * 0.5, cell_z + oz),
						Vector3(slab_w, h_j, slab_w),
						Color(sh_f * 0.93, sh_f * 0.97, sh_f), Vector3.ZERO, false, 1.45)
			if not in_sanc and _lab_cell_open_degree(cx, cz) >= 3 and rng.randf() < 0.7:
				# recessed iron storm grate at corridor junctions
				_st_add_box(st_metal, Vector3(cell_x, 0.050, cell_z),
					Vector3(0.72, 0.018, 0.72), metal_dark, Vector3.ZERO, false, 1.0)
				for gi in 5:
					var goff := (float(gi) - 2.0) * 0.13
					_st_add_box(st_metal, Vector3(cell_x + goff, 0.062, cell_z),
						Vector3(0.035, 0.014, 0.66), metal_rust, Vector3.ZERO, false, 1.0)

	# --- 7b) Walls, plinths, cornices, barred windows, conduits & boxes -------
	var wall_count := 0
	var window_walls := 0
	var conduit_count := 0
	var wall_anchors: Array[Vector3] = []

	# Horizontal walls (parallel to local X)
	for cz in LAB_CELLS + 1:
		var is_outer := (cz == 0 or cz == LAB_CELLS)
		var z := _lab_grid_coord(cz)
		for cx in LAB_CELLS:
			if not _lab_h_wall[cz][cx]:
				continue
			var x := _lab_cell_coord(cx)
			var h := rng.randf_range(3.62, 3.96) if is_outer else rng.randf_range(3.30, 3.66)
			var shade := rng.randf_range(0.58, 0.88)
			var col := Color(shade * 0.93, shade * 0.97, shade)
			wall_count += 1
			# full-height physics collider for every closed wall
			_lab_add_collider(body, Vector3(x, h * 0.5, z), Vector3(LAB_CELL + 0.04, h, LAB_WALL_THICK), true)
			# heavy chamfered stone base plinth
			_st_add_box(st_wall, Vector3(x, 0.18, z),
				Vector3(LAB_CELL + 0.04, 0.36, LAB_WALL_THICK + 0.10), col.darkened(0.18))

			var make_window := (not is_outer) and (not _lab_touches_sanctum_h(cz, cx)) and rng.randf() < 0.19
			if make_window:
				window_walls += 1
				# breast wall + sill + side masonry jambs + upper lintel + 5 iron grille bars
				_st_add_box(st_wall, Vector3(x, 0.60, z), Vector3(LAB_CELL + 0.04, 1.20, LAB_WALL_THICK), col)
				_st_add_box(st_wall, Vector3(x, 1.23, z), Vector3(LAB_CELL - 0.10, 0.08, LAB_WALL_THICK + 0.08), col.lightened(0.06))
				var jamb_w := 0.42
				for side_i in [-1.0, 1.0]:
					var jx := x + float(side_i) * (LAB_CELL * 0.5 - jamb_w * 0.5)
					_st_add_box(st_wall, Vector3(jx, 1.80, z), Vector3(jamb_w, 1.18, LAB_WALL_THICK), col.darkened(0.06))
				var top_h := h - 2.36
				_st_add_box(st_wall, Vector3(x, 2.36 + top_h * 0.5, z),
					Vector3(LAB_CELL + 0.04, top_h, LAB_WALL_THICK), col, Vector3.ZERO, true)
				_st_add_box(st_wall, Vector3(x, h + 0.07, z),
					Vector3(LAB_CELL + 0.06, 0.14, LAB_WALL_THICK + 0.08), col.darkened(0.12), Vector3.ZERO, true)
				var open_w := LAB_CELL - jamb_w * 2.0
				_st_add_box(st_metal, Vector3(x, 1.80, z), Vector3(open_w, 0.045, 0.055), metal_rust, Vector3.ZERO, true)
				for bi in 5:
					var bx := x + (float(bi) - 2.0) * (open_w / 5.4)
					_st_add_tube(st_metal, [Vector3(bx, 1.24, z), Vector3(bx, 2.37, z)], 0.022, 5, metal_rust)
			else:
				_st_add_box(st_wall, Vector3(x, h * 0.5, z), Vector3(LAB_CELL + 0.04, h, LAB_WALL_THICK), col)
				# mid string-course ledge + overhanging top cornice
				_st_add_box(st_wall, Vector3(x, 1.94, z),
					Vector3(LAB_CELL + 0.02, 0.10, LAB_WALL_THICK + 0.06), col.darkened(0.10), Vector3.ZERO, true)
				_st_add_box(st_wall, Vector3(x, h + 0.07, z),
					Vector3(LAB_CELL + 0.04, 0.14, LAB_WALL_THICK + 0.09), col.darkened(0.14), Vector3.ZERO, true)
				if rng.randf() < 0.46:
					var cw := rng.randf_range(0.65, 1.35)
					var ch := rng.randf_range(0.18, 0.38)
					var cx_off := rng.randf_range(-0.42, 0.42)
					_st_add_box(st_wall, Vector3(x + cx_off, h + 0.14 + ch * 0.5, z),
						Vector3(cw, ch, LAB_WALL_THICK * 1.05), col.darkened(0.16))
					# exposed bent steel rebar protruding from broken masonry top
					if rng.randf() < 0.55:
						var rx := x + cx_off + rng.randf_range(-0.22, 0.22)
						var rb_top := h + 0.14 + ch
						_st_add_tube(st_metal, [
							Vector3(rx, rb_top - 0.05, z),
							Vector3(rx + rng.randf_range(-0.06, 0.06), rb_top + 0.24, z),
							Vector3(rx + rng.randf_range(-0.18, 0.18), rb_top + 0.40, z + rng.randf_range(-0.10, 0.10))
						], 0.014, 4, metal_rust)

				# wall-mounted twin electrical conduits + clamps + junction boxes
				var face_sign := 1.0 if (cz == 0 or (cz < LAB_CELLS and rng.randf() < 0.5)) else -1.0
				if cz == LAB_CELLS:
					face_sign = -1.0
				var z_pipe := z + face_sign * (LAB_WALL_THICK * 0.5 + 0.045)
				if rng.randf() < 0.58:
					conduit_count += 1
					for py in [2.56, 2.72]:
						_st_add_tube(st_metal, [
							Vector3(x - LAB_CELL * 0.5, float(py), z_pipe),
							Vector3(x + LAB_CELL * 0.5, float(py), z_pipe)
						], 0.021, 5, metal_dark)
					for cl_x in [-0.78, 0.0, 0.78]:
						_st_add_box(st_metal, Vector3(x + float(cl_x), 2.64, z + face_sign * (LAB_WALL_THICK * 0.5 + 0.03)),
							Vector3(0.05, 0.28, 0.06), metal_rust, Vector3.ZERO, true)
				if rng.randf() < 0.24:
					var bx_pos := x + rng.randf_range(-0.45, 0.45)
					var bz_pos := z + face_sign * (LAB_WALL_THICK * 0.5 + 0.065)
					_st_add_box(st_metal, Vector3(bx_pos, 1.86, bz_pos), Vector3(0.28, 0.36, 0.13), metal_dark, Vector3.ZERO, true)
					_st_add_box(st_metal, Vector3(bx_pos, 1.86, bz_pos + face_sign * 0.07), Vector3(0.22, 0.28, 0.02), metal_rust, Vector3.ZERO, true)
					_st_add_tube(st_metal, [Vector3(bx_pos, 2.04, bz_pos), Vector3(bx_pos, 2.94, bz_pos)], 0.018, 5, metal_dark)
					var ins_tip := Vector3(bx_pos, 2.96, z + face_sign * (LAB_WALL_THICK * 0.5 + 0.20))
					_st_add_box(st_metal, Vector3(bx_pos, 2.94, z + face_sign * (LAB_WALL_THICK * 0.5 + 0.11)),
						Vector3(0.05, 0.05, 0.22), metal_dark, Vector3.ZERO, true)
					_st_add_tube(st_metal, [ins_tip - Vector3(0, 0.05, 0), ins_tip + Vector3(0, 0.05, 0)], 0.036, 6, ceramic_col)
					wall_anchors.append(ins_tip)

	# Vertical walls (parallel to local Z)
	for cz in LAB_CELLS:
		var z := _lab_cell_coord(cz)
		for cx in LAB_CELLS + 1:
			if not _lab_v_wall[cz][cx]:
				continue
			var is_outer := (cx == 0 or cx == LAB_CELLS)
			var x := _lab_grid_coord(cx)
			var h := rng.randf_range(3.62, 3.96) if is_outer else rng.randf_range(3.30, 3.66)
			var shade := rng.randf_range(0.58, 0.88)
			var col := Color(shade * 0.93, shade * 0.97, shade)
			wall_count += 1
			_lab_add_collider(body, Vector3(x, h * 0.5, z), Vector3(LAB_WALL_THICK, h, LAB_CELL + 0.04), true)
			_st_add_box(st_wall, Vector3(x, 0.18, z),
				Vector3(LAB_WALL_THICK + 0.10, 0.36, LAB_CELL + 0.04), col.darkened(0.18))

			var make_window := (not is_outer) and (not _lab_touches_sanctum_v(cz, cx)) and rng.randf() < 0.19
			if make_window:
				window_walls += 1
				_st_add_box(st_wall, Vector3(x, 0.60, z), Vector3(LAB_WALL_THICK, 1.20, LAB_CELL + 0.04), col)
				_st_add_box(st_wall, Vector3(x, 1.23, z), Vector3(LAB_WALL_THICK + 0.08, 0.08, LAB_CELL - 0.10), col.lightened(0.06))
				var jamb_w := 0.42
				for side_i in [-1.0, 1.0]:
					var jz := z + float(side_i) * (LAB_CELL * 0.5 - jamb_w * 0.5)
					_st_add_box(st_wall, Vector3(x, 1.80, jz), Vector3(LAB_WALL_THICK, 1.18, jamb_w), col.darkened(0.06))
				var top_h := h - 2.36
				_st_add_box(st_wall, Vector3(x, 2.36 + top_h * 0.5, z),
					Vector3(LAB_WALL_THICK, top_h, LAB_CELL + 0.04), col, Vector3.ZERO, true)
				_st_add_box(st_wall, Vector3(x, h + 0.07, z),
					Vector3(LAB_WALL_THICK + 0.08, 0.14, LAB_CELL + 0.06), col.darkened(0.12), Vector3.ZERO, true)
				var open_w := LAB_CELL - jamb_w * 2.0
				_st_add_box(st_metal, Vector3(x, 1.80, z), Vector3(0.055, 0.045, open_w), metal_rust, Vector3.ZERO, true)
				for bi in 5:
					var bz := z + (float(bi) - 2.0) * (open_w / 5.4)
					_st_add_tube(st_metal, [Vector3(x, 1.24, bz), Vector3(x, 2.37, bz)], 0.022, 5, metal_rust)
			else:
				_st_add_box(st_wall, Vector3(x, h * 0.5, z), Vector3(LAB_WALL_THICK, h, LAB_CELL + 0.04), col)
				_st_add_box(st_wall, Vector3(x, 1.94, z),
					Vector3(LAB_WALL_THICK + 0.06, 0.10, LAB_CELL + 0.02), col.darkened(0.10), Vector3.ZERO, true)
				_st_add_box(st_wall, Vector3(x, h + 0.07, z),
					Vector3(LAB_WALL_THICK + 0.09, 0.14, LAB_CELL + 0.04), col.darkened(0.14), Vector3.ZERO, true)
				if rng.randf() < 0.46:
					var cl := rng.randf_range(0.65, 1.35)
					var ch := rng.randf_range(0.18, 0.38)
					var cz_off := rng.randf_range(-0.42, 0.42)
					_st_add_box(st_wall, Vector3(x, h + 0.14 + ch * 0.5, z + cz_off),
						Vector3(LAB_WALL_THICK * 1.05, ch, cl), col.darkened(0.16))
					if rng.randf() < 0.55:
						var rz := z + cz_off + rng.randf_range(-0.22, 0.22)
						var rb_top := h + 0.14 + ch
						_st_add_tube(st_metal, [
							Vector3(x, rb_top - 0.05, rz),
							Vector3(x, rb_top + 0.24, rz + rng.randf_range(-0.06, 0.06)),
							Vector3(x + rng.randf_range(-0.10, 0.10), rb_top + 0.40, rz + rng.randf_range(-0.18, 0.18))
						], 0.014, 4, metal_rust)

				var face_sign := 1.0 if (cx == 0 or (cx < LAB_CELLS and rng.randf() < 0.5)) else -1.0
				if cx == LAB_CELLS:
					face_sign = -1.0
				var x_pipe := x + face_sign * (LAB_WALL_THICK * 0.5 + 0.045)
				if rng.randf() < 0.58:
					conduit_count += 1
					for py in [2.56, 2.72]:
						_st_add_tube(st_metal, [
							Vector3(x_pipe, float(py), z - LAB_CELL * 0.5),
							Vector3(x_pipe, float(py), z + LAB_CELL * 0.5)
						], 0.021, 5, metal_dark)
					for cl_z in [-0.78, 0.0, 0.78]:
						_st_add_box(st_metal, Vector3(x + face_sign * (LAB_WALL_THICK * 0.5 + 0.03), 2.64, z + float(cl_z)),
							Vector3(0.06, 0.28, 0.05), metal_rust, Vector3.ZERO, true)
				if rng.randf() < 0.24:
					var bz_pos := z + rng.randf_range(-0.45, 0.45)
					var bx_pos := x + face_sign * (LAB_WALL_THICK * 0.5 + 0.065)
					_st_add_box(st_metal, Vector3(bx_pos, 1.86, bz_pos), Vector3(0.13, 0.36, 0.28), metal_dark, Vector3.ZERO, true)
					_st_add_box(st_metal, Vector3(bx_pos + face_sign * 0.07, 1.86, bz_pos), Vector3(0.02, 0.28, 0.22), metal_rust, Vector3.ZERO, true)
					_st_add_tube(st_metal, [Vector3(bx_pos, 2.04, bz_pos), Vector3(bx_pos, 2.94, bz_pos)], 0.018, 5, metal_dark)
					var ins_tip := Vector3(x + face_sign * (LAB_WALL_THICK * 0.5 + 0.20), 2.96, bz_pos)
					_st_add_box(st_metal, Vector3(x + face_sign * (LAB_WALL_THICK * 0.5 + 0.11), 2.94, bz_pos),
						Vector3(0.22, 0.05, 0.05), metal_dark, Vector3.ZERO, true)
					_st_add_tube(st_metal, [ins_tip - Vector3(0, 0.05, 0), ins_tip + Vector3(0, 0.05, 0)], 0.036, 6, ceramic_col)
					wall_anchors.append(ins_tip)

	# --- 7c) Buttressed grid piers & weathered corner rubble ------------------
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
			if deg == 0 or (deg == 2 and (
					(gx > 0 and gx < LAB_CELLS and _lab_h_wall[gz][gx] and _lab_h_wall[gz][gx - 1]) or
					(gz > 0 and gz < LAB_CELLS and _lab_v_wall[gz][gx] and _lab_v_wall[gz - 1][gx]))):
				continue
			var px := _lab_grid_coord(gx)
			var pz := _lab_grid_coord(gz)
			var ph := rng.randf_range(3.75, 4.12)
			var pcol := Color(0.66, 0.69, 0.73).darkened(rng.randf_range(0.0, 0.24))
			_st_add_box(st_wall, Vector3(px, 0.22, pz), Vector3(0.58, 0.44, 0.58), pcol.darkened(0.16))
			var psz := Vector3(0.48, ph, 0.48)
			_st_add_box(st_wall, Vector3(px, ph * 0.5, pz), psz, pcol)
			_st_add_box(st_wall, Vector3(px, ph + 0.09, pz), Vector3(0.56, 0.18, 0.56), pcol.lightened(0.05), Vector3.ZERO, true)
			_lab_add_collider(body, Vector3(px, ph * 0.5, pz), psz, true)

	# --- 7d) Grand portals (4 outer gates + 2 Sanctum thresholds) -------------
	for arch in archways:
		var ap: Vector3 = arch["pos"]
		var horiz: bool = arch["horiz"]
		var outer: bool = arch["outer"]
		var post_h := 4.30 if outer else 4.02
		var span := LAB_CELL
		var pcol := Color(0.74, 0.75, 0.79) if outer else Color(0.66, 0.68, 0.73)
		var off := Vector3(span * 0.5, 0.0, 0.0) if horiz else Vector3(0.0, 0.0, span * 0.5)
		var post_sz := Vector3(0.52, post_h, 0.62) if horiz else Vector3(0.62, post_h, 0.52)
		var base_sz := Vector3(0.64, 0.46, 0.74) if horiz else Vector3(0.74, 0.46, 0.64)
		for side in [-1.0, 1.0]:
			var s_f := float(side)
			var jp: Vector3 = ap + off * s_f + Vector3(0.0, post_h * 0.5, 0.0)
			_st_add_box(st_wall, ap + off * s_f + Vector3(0.0, 0.23, 0.0), base_sz, pcol.darkened(0.18))
			_st_add_box(st_wall, jp, post_sz, pcol)
			_lab_add_collider(body, jp, post_sz, true)
			# stone corbel bracket supporting the lintel
			var corb_off := off * (s_f * 0.72) + Vector3(0.0, 2.94, 0.0)
			var corb_sz := Vector3(0.34, 0.26, 0.54) if horiz else Vector3(0.54, 0.26, 0.34)
			_st_add_box(st_wall, ap + corb_off, corb_sz, pcol.darkened(0.10), Vector3.ZERO, true)
		var lintel_sz := Vector3(span + 0.70, 0.52, 0.66) if horiz else Vector3(0.66, 0.52, span + 0.70)
		var crown_sz := Vector3(span + 0.84, 0.18, 0.78) if horiz else Vector3(0.78, 0.18, span + 0.84)
		var lp_pos := ap + Vector3(0.0, 3.30, 0.0)
		_st_add_box(st_wall, lp_pos, lintel_sz, pcol.darkened(0.08), Vector3.ZERO, true)
		_st_add_box(st_wall, ap + Vector3(0.0, 3.65, 0.0), crown_sz, pcol, Vector3.ZERO, true)
		# iron tie-beam strapped across the lintel
		var strap_sz := Vector3(span + 0.72, 0.10, 0.70) if horiz else Vector3(0.70, 0.10, span + 0.72)
		_st_add_box(st_metal, ap + Vector3(0.0, 3.12, 0.0), strap_sz, metal_rust, Vector3.ZERO, true)
		_lab_add_collider(body, lp_pos, lintel_sz, false)

	# --- 7e) Central Sanctum: stepped dais, 4 corner obelisks, collector hub --
	_st_add_box(st_wall, Vector3(0.0, 0.045, 0.0), Vector3(2.25, 0.09, 2.25), Color(0.52, 0.54, 0.58))
	_st_add_box(st_wall, Vector3(0.0, 0.105, 0.0), Vector3(1.52, 0.09, 1.52), Color(0.62, 0.64, 0.68))

	var sanctum_hub := Vector3(0.0, 3.42, 0.0)
	_st_add_box(st_metal, sanctum_hub, Vector3(4.50, 0.10, 0.12), metal_dark, Vector3.ZERO, true)
	_st_add_box(st_metal, sanctum_hub, Vector3(0.12, 0.10, 4.50), metal_dark, Vector3.ZERO, true)
	_st_add_box(st_metal, sanctum_hub + Vector3(0.0, -0.08, 0.0), Vector3(0.68, 0.16, 0.68), metal_rust, Vector3.ZERO, true)

	var sanctum_pins: Array[Vector3] = []
	for sx in [-1.72, 1.72]:
		for sz_c in [-1.72, 1.72]:
			var sx_f := float(sx)
			var sz_f := float(sz_c)
			var sh := rng.randf_range(2.90, 3.22)
			_st_add_box(st_wall, Vector3(sx_f, 0.20, sz_f), Vector3(0.60, 0.40, 0.60), Color(0.54, 0.56, 0.60))
			var st_sz := Vector3(0.46, sh, 0.46)
			var spos := Vector3(sx_f, sh * 0.5, sz_f)
			_st_add_box(st_wall, spos, st_sz, Color(0.68, 0.70, 0.75))
			_st_add_box(st_wall, Vector3(sx_f, sh + 0.08, sz_f), Vector3(0.54, 0.16, 0.54), Color(0.74, 0.76, 0.80), Vector3.ZERO, true)
			_lab_add_collider(body, spos, st_sz, true)
			# steel insulator bracket atop each sanctum obelisk
			var pin_top := Vector3(sx_f, sh + 0.28, sz_f)
			_st_add_tube(st_metal, [Vector3(sx_f, sh + 0.16, sz_f), pin_top], 0.042, 6, ceramic_col)
			sanctum_pins.append(pin_top)

	# --- 7f) Overhead corridor steel gantries & ceramic insulators ------------
	var gantry_pins := {}  # Vector2i(cx, cz) -> Array[Vector3] (3 insulator tips)
	for cz in LAB_CELLS:
		for cx in LAB_CELLS:
			if _lab_is_sanctum(cx, cz):
				continue
			var deg := _lab_cell_open_degree(cx, cz)
			var is_ent := Vector2i(cx, cz) in entrance_cells
			if not is_ent and deg < 3 and (cx + cz) % 2 != 0 and rng.randf() > 0.35:
				continue
			var cell_x := _lab_cell_coord(cx)
			var cell_z := _lab_cell_coord(cz)
			# orient crossbar between whichever opposing walls are closed (prefer N-S vs E-W)
			var ew_walls: bool = bool(_lab_v_wall[cz][cx]) and bool(_lab_v_wall[cz][cx + 1])
			var beam_y := 3.22
			var pins: Array[Vector3] = []
			if ew_walls or (not (_lab_h_wall[cz][cx] and _lab_h_wall[cz + 1][cx]) and rng.randf() < 0.5):
				_st_add_box(st_metal, Vector3(cell_x, beam_y, cell_z),
					Vector3(LAB_CELL - 0.18, 0.085, 0.085), metal_dark, Vector3.ZERO, true)
				for off_x in [-0.52, 0.0, 0.52]:
					var p_ins := Vector3(cell_x + float(off_x), beam_y - 0.11, cell_z)
					_st_add_tube(st_metal, [Vector3(p_ins.x, beam_y - 0.03, p_ins.z), p_ins], 0.038, 6, ceramic_col)
					pins.append(p_ins)
			else:
				_st_add_box(st_metal, Vector3(cell_x, beam_y, cell_z),
					Vector3(0.085, 0.085, LAB_CELL - 0.18), metal_dark, Vector3.ZERO, true)
				for off_z in [-0.52, 0.0, 0.52]:
					var p_ins2 := Vector3(cell_x, beam_y - 0.11, cell_z + float(off_z))
					_st_add_tube(st_metal, [Vector3(p_ins2.x, beam_y - 0.03, p_ins2.z), p_ins2], 0.038, 6, ceramic_col)
					pins.append(p_ins2)
			gantry_pins[Vector2i(cx, cz)] = pins

	# --- 7g) Two Substation Transformer Cabinets + flickering lights + 3D hum -
	var substation_lights: Array[OmniLight3D] = []
	var substations_built := 0
	var sub_bands := [[0, 4], [5, 9]]
	for sb in sub_bands:
		var z_lo: int = sb[0]
		var z_hi: int = sb[1]
		var dead_cands: Array[Vector2i] = []
		var fallback_cands: Array[Vector2i] = []
		for cz in range(z_lo, z_hi + 1):
			for cx in LAB_CELLS:
				if _lab_is_sanctum(cx, cz) or (Vector2i(cx, cz) in entrance_cells):
					continue
				if _lab_cell_open_degree(cx, cz) == 1:
					dead_cands.append(Vector2i(cx, cz))
				elif _lab_h_wall[cz][cx] or _lab_h_wall[cz + 1][cx] or _lab_v_wall[cz][cx] or _lab_v_wall[cz][cx + 1]:
					fallback_cands.append(Vector2i(cx, cz))
		_shuffle(dead_cands)
		_shuffle(fallback_cands)
		var candidates_sub: Array[Vector2i] = dead_cands if not dead_cands.is_empty() else fallback_cands
		if candidates_sub.is_empty():
			continue
		var sc: Vector2i = candidates_sub[0]
		var sc_x := _lab_cell_coord(sc.x)
		var sc_z := _lab_cell_coord(sc.y)
		# Mount cabinet against the back wall opposite an open doorway when possible
		var cab_pos := Vector3(sc_x, 0.94, sc_z)
		var cab_sz := Vector3(0.84, 1.88, 0.34)
		var front_n := Vector3(0, 0, 1)
		if _lab_h_wall[sc.y][sc.x] and (sc.y < LAB_CELLS - 1 and not _lab_h_wall[sc.y + 1][sc.x]):
			cab_pos = Vector3(sc_x, 0.94, _lab_grid_coord(sc.y) + LAB_WALL_THICK * 0.5 + 0.18)
			cab_sz = Vector3(0.84, 1.88, 0.34)
			front_n = Vector3(0, 0, 1)
		elif _lab_h_wall[sc.y + 1][sc.x] and (sc.y > 0 and not _lab_h_wall[sc.y][sc.x]):
			cab_pos = Vector3(sc_x, 0.94, _lab_grid_coord(sc.y + 1) - LAB_WALL_THICK * 0.5 - 0.18)
			cab_sz = Vector3(0.84, 1.88, 0.34)
			front_n = Vector3(0, 0, -1)
		elif _lab_v_wall[sc.y][sc.x] and (sc.x < LAB_CELLS - 1 and not _lab_v_wall[sc.y][sc.x + 1]):
			cab_pos = Vector3(_lab_grid_coord(sc.x) + LAB_WALL_THICK * 0.5 + 0.18, 0.94, sc_z)
			cab_sz = Vector3(0.34, 1.88, 0.84)
			front_n = Vector3(1, 0, 0)
		elif _lab_v_wall[sc.y][sc.x + 1] and (sc.x > 0 and not _lab_v_wall[sc.y][sc.x]):
			cab_pos = Vector3(_lab_grid_coord(sc.x + 1) - LAB_WALL_THICK * 0.5 - 0.18, 0.94, sc_z)
			cab_sz = Vector3(0.34, 1.88, 0.84)
			front_n = Vector3(-1, 0, 0)
		elif _lab_h_wall[sc.y][sc.x]:
			cab_pos = Vector3(sc_x, 0.94, _lab_grid_coord(sc.y) + LAB_WALL_THICK * 0.5 + 0.18)
			cab_sz = Vector3(0.84, 1.88, 0.34)
			front_n = Vector3(0, 0, 1)
		elif _lab_h_wall[sc.y + 1][sc.x]:
			cab_pos = Vector3(sc_x, 0.94, _lab_grid_coord(sc.y + 1) - LAB_WALL_THICK * 0.5 - 0.18)
			cab_sz = Vector3(0.84, 1.88, 0.34)
			front_n = Vector3(0, 0, -1)
		elif _lab_v_wall[sc.y][sc.x]:
			cab_pos = Vector3(_lab_grid_coord(sc.x) + LAB_WALL_THICK * 0.5 + 0.18, 0.94, sc_z)
			cab_sz = Vector3(0.34, 1.88, 0.84)
			front_n = Vector3(1, 0, 0)
		else:
			cab_pos = Vector3(_lab_grid_coord(sc.x + 1) - LAB_WALL_THICK * 0.5 - 0.18, 0.94, sc_z)
			cab_sz = Vector3(0.34, 1.88, 0.84)
			front_n = Vector3(-1, 0, 0)

		_st_add_box(st_metal, cab_pos, cab_sz, metal_dark, Vector3.ZERO, true)
		_lab_add_collider(body, cab_pos, cab_sz, true)
		# radiator cooling fins + recessed breaker door panel
		var door_sz := Vector3(cab_sz.x * 0.78, 1.42, 0.03) if absf(front_n.z) > 0.5 else Vector3(0.03, 1.42, cab_sz.z * 0.78)
		_st_add_box(st_metal, cab_pos + front_n * 0.18, door_sz, metal_rust, Vector3.ZERO, true)
		var tang := Vector3(front_n.z, 0.0, -front_n.x)
		var bushings: Array[Vector3] = []
		for bi in [-1, 0, 1]:
			var b_base := cab_pos + Vector3(0.0, 0.94, 0.0) + tang * (float(bi) * 0.24)
			var b_top := b_base + Vector3(0.0, 0.32, 0.0)
			_st_add_tube(st_metal, [b_base, b_top], 0.048, 6, ceramic_col)
			bushings.append(b_top)

		# Feeders from transformer bushings up to an overhead gantry above this cell
		if not gantry_pins.has(sc):
			var gp_pos := Vector3(sc_x, 3.11, sc_z)
			_st_add_box(st_metal, Vector3(sc_x, 3.22, sc_z), Vector3(0.95, 0.085, 0.085), metal_dark, Vector3.ZERO, true)
			gantry_pins[sc] = [gp_pos + Vector3(-0.30, 0, 0), gp_pos, gp_pos + Vector3(0.30, 0, 0)]
		var cell_pins: Array = gantry_pins[sc]
		for bi2 in mini(bushings.size(), cell_pins.size()):
			var p_from: Vector3 = bushings[bi2]
			var p_to: Vector3 = cell_pins[bi2]
			var mid_bow := (p_from + p_to) * 0.5 + front_n * 0.22
			_st_add_tube(st_wires, [p_from, mid_bow, p_to], 0.024, 5, wire_black)

		# Caged bulkhead lamp + flickering OmniLight3D + 3D spatial wire_hum_loop.ogg
		var lamp_local := cab_pos + Vector3(0.0, 1.52, 0.0) + front_n * 0.16
		_st_add_box(st_metal, lamp_local, Vector3(0.16, 0.20, 0.16), metal_rust, Vector3.ZERO, true)
		var lamp := OmniLight3D.new()
		lamp.name = "SubstationLamp_%d" % substations_built
		lamp.position = xf * (lamp_local + front_n * 0.14)
		lamp.light_color = Color(1.0, 0.68, 0.34) if substations_built == 0 else Color(0.58, 0.80, 1.0)
		lamp.light_energy = 0.36
		lamp.omni_range = 4.4
		lamp.omni_attenuation = 1.65
		lamp.shadow_enabled = false
		add_child(lamp)
		substation_lights.append(lamp)

		var hum_stream: AudioStream = Sfx.stream("wire_hum_loop")
		if hum_stream != null:
			var hum3d := AudioStreamPlayer3D.new()
			hum3d.name = "SubstationHum_%d" % substations_built
			hum3d.stream = hum_stream
			hum3d.position = xf * cab_pos
			hum3d.unit_size = 2.4
			hum3d.max_distance = 13.5
			hum3d.volume_db = -13.5
			hum3d.bus = "Master"  # Area3D LabyrinthReverbZone applies 3D stone reverb
			add_child(hum3d)
			hum3d.play()
		substations_built += 1

	# --- 7h) Electric Wire Network: overhead trunks, sanctum web, jumpers, drops
	var wire_count := 0

	# Connect adjacent or 2-cell straight open gantry runs with 2-3 sagging cables
	for k_var in gantry_pins.keys():
		var c_a: Vector2i = k_var
		var pins_a: Array = gantry_pins[c_a]
		# search East (+X) and South (+Z) up to 2 open corridor cells for next gantry
		for step_dir in [Vector2i(1, 0), Vector2i(0, 1)]:
			var d_vec: Vector2i = step_dir
			var cur_c := c_a
			for dist_step in range(1, 3):
				var nxt_c := cur_c + d_vec
				if nxt_c.x < 0 or nxt_c.x >= LAB_CELLS or nxt_c.y < 0 or nxt_c.y >= LAB_CELLS:
					break
				if not _lab_open_between(cur_c, nxt_c):
					break
				if _lab_is_sanctum(nxt_c.x, nxt_c.y):
					# feed into the Central Sanctum collector hub!
					for wi in 2:
						var pa_s: Vector3 = pins_a[wi % pins_a.size()]
						var pb_s := sanctum_hub + Vector3(
							clampf(pa_s.x, -0.32, 0.32), -0.10, clampf(pa_s.z, -0.32, 0.32))
						_st_add_cable(st_wires, pa_s, pb_s, rng.randf_range(0.20, 0.42),
							0.019, 7, wire_black if wi == 0 else wire_braid, rng.randf_range(-0.05, 0.05))
						wire_count += 1
					break
				if gantry_pins.has(nxt_c):
					var pins_b: Array = gantry_pins[nxt_c]
					var strands := 3 if rng.randf() < 0.45 else 2
					for wi2 in strands:
						var pa: Vector3 = pins_a[wi2 % pins_a.size()]
						var pb: Vector3 = pins_b[wi2 % pins_b.size()]
						var sag := rng.randf_range(0.16, 0.38) * (1.0 + 0.25 * float(dist_step - 1))
						var rad := 0.020 if wi2 == 0 else 0.015
						var wcol := wire_black if wi2 % 2 == 0 else wire_braid
						_st_add_cable(st_wires, pa, pb, sag, rad, 7, wcol, rng.randf_range(-0.04, 0.04))
						wire_count += 1
					break
				cur_c = nxt_c

	# Sanctum corner obelisks -> central collector hub + perimeter ring cables
	for i in sanctum_pins.size():
		var sp_a: Vector3 = sanctum_pins[i]
		var hub_pt := sanctum_hub + sp_a.normalized() * 0.32 + Vector3(0, -0.10, 0)
		_st_add_cable(st_wires, sp_a, hub_pt, rng.randf_range(0.22, 0.36), 0.021, 7, wire_black, 0.03)
		wire_count += 1
	var ring_order := [0, 1, 3, 2]
	for ri in 4:
		var ra: Vector3 = sanctum_pins[ring_order[ri]]
		var rb: Vector3 = sanctum_pins[ring_order[(ri + 1) % 4]]
		_st_add_cable(st_wires, ra, rb, rng.randf_range(0.24, 0.40), 0.016, 7, wire_braid, 0.0)
		wire_count += 1

	# Wall-box to nearest gantry / adjacent wall-box jumpers (high corridor webs)
	_shuffle(wall_anchors)
	var max_jumpers := mini(wall_anchors.size(), 26)
	for wi3 in max_jumpers:
		var wa: Vector3 = wall_anchors[wi3]
		var wc := Vector2i(
			clampi(int(floor((wa.x + LAB_HALF) / LAB_CELL)), 0, LAB_CELLS - 1),
			clampi(int(floor((wa.z + LAB_HALF) / LAB_CELL)), 0, LAB_CELLS - 1))
		if gantry_pins.has(wc):
			var gp_arr: Array = gantry_pins[wc]
			var gp_t: Vector3 = gp_arr[wi3 % gp_arr.size()]
			if wa.distance_to(gp_t) > 0.35:
				_st_add_cable(st_wires, wa, gp_t, rng.randf_range(0.14, 0.28), 0.015, 6, wire_black, 0.02)
				wire_count += 1
		# cross-corridor jumper to another anchor in the same cell or adjacent open cell
		for wj in range(wi3 + 1, wall_anchors.size()):
			var wb: Vector3 = wall_anchors[wj]
			var d_ab := wa.distance_to(wb)
			if d_ab < 1.5 or d_ab > 3.6:
				continue
			var wc_b := Vector2i(
				clampi(int(floor((wb.x + LAB_HALF) / LAB_CELL)), 0, LAB_CELLS - 1),
				clampi(int(floor((wb.z + LAB_HALF) / LAB_CELL)), 0, LAB_CELLS - 1))
			if wc == wc_b or _lab_open_between(wc, wc_b):
				_st_add_cable(st_wires, wa, wb, rng.randf_range(0.18, 0.36), 0.014, 6, wire_braid, rng.randf_range(-0.04, 0.04))
				wire_count += 1
				break

	# Snapped / dangling severed wires near walls & dead ends (with bare copper tips)
	var dangle_count := mini(10, wall_anchors.size())
	for di in dangle_count:
		var anchor: Vector3 = wall_anchors[(wall_anchors.size() - 1) - di]
		var drop_len := rng.randf_range(0.95, 1.42)
		var drift_x := rng.randf_range(-0.14, 0.14)
		var drift_z := rng.randf_range(-0.14, 0.14)
		var p_mid1 := anchor + Vector3(drift_x * 0.4, -drop_len * 0.42, drift_z * 0.4)
		var p_mid2 := anchor + Vector3(drift_x, -drop_len * 0.86, drift_z)
		var p_end := p_mid2 + Vector3(rng.randf_range(-0.08, 0.08), -drop_len * 0.14, rng.randf_range(-0.08, 0.08))
		var p_tip := p_end + Vector3(rng.randf_range(-0.05, 0.05), -0.08, rng.randf_range(-0.05, 0.05))
		_st_add_tube(st_wires, [anchor, p_mid1, p_mid2, p_end], 0.015, 5, wire_black)
		_st_add_tube(st_wires, [p_end, p_tip], 0.009, 4, wire_copper)
		wire_count += 1

	# Commit all 4 batched labyrinth meshes
	st_floor.index()
	st_floor.generate_tangents()
	var floor_mi := MeshInstance3D.new()
	floor_mi.name = "LabyrinthFloor"
	floor_mi.transform = xf
	floor_mi.mesh = st_floor.commit()
	floor_mi.material_override = _mats["lab_floor"]
	floor_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_mi)

	st_wall.index()
	st_wall.generate_tangents()
	var lab_mi := MeshInstance3D.new()
	lab_mi.name = "LabyrinthMesh"
	lab_mi.transform = xf
	lab_mi.mesh = st_wall.commit()
	lab_mi.material_override = _mats["lab_wall"]
	lab_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Game.quality >= 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lab_mi)

	st_metal.index()
	st_metal.generate_tangents()
	var metal_mi := MeshInstance3D.new()
	metal_mi.name = "LabyrinthMetal"
	metal_mi.transform = xf
	metal_mi.mesh = st_metal.commit()
	metal_mi.material_override = _mats["lab_metal"]
	metal_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(metal_mi)

	st_wires.index()
	st_wires.generate_tangents()
	var wires_mi := MeshInstance3D.new()
	wires_mi.name = "LabyrinthWires"
	wires_mi.transform = xf
	wires_mi.mesh = st_wires.commit()
	wires_mi.material_override = _mats["lab_wire"]
	wires_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(wires_mi)

	# 8) Spatial ReverbZone covering the stone labyrinth interior.
	var rzone: Area3D = load("res://scripts/reverb_zone.gd").new()
	rzone.name = "LabyrinthReverbZone"
	rzone.transform = Transform3D(xf.basis, base + Vector3(0.0, 2.2, 0.0))
	rzone.setup(Vector3(LAB_HALF + 0.45, 2.6, LAB_HALF + 0.45), 2.4)
	rzone.substation_lights = substation_lights
	add_child(rzone)

	# 9) Verify BFS path from every entrance to the Sanctum and record metadata.
	var sanctum_goals: Array[Vector2i] = [
		Vector2i(mid - 1, mid - 1), Vector2i(mid, mid - 1),
		Vector2i(mid - 1, mid), Vector2i(mid, mid),
	]
	var min_path := 999
	var max_path := 0
	for ec in entrance_cells:
		var d := _lab_bfs_distance(ec, sanctum_goals)
		min_path = mini(min_path, d)
		max_path = maxi(max_path, d)

	# The page for this landmark is appended by _add_page_spot() from the hint set
	# in 6b, pinned to a corridor wall at hand height. The old code appended a
	# second spot at the maze centre with no normal and no height, which produced a
	# ninth page lying on the ground in the middle of the sanctum.
	landmarks.append({"name": "labyrinth", "pos": base, "radius": 16.4, "rot": rot, "scale": 1.0})

	labyrinth = {
		"pos": base,
		"rot": rot,
		"half": LAB_HALF,
		"cells": LAB_CELLS,
		"cell_size": LAB_CELL,
		"wall_count": wall_count,
		"window_walls": window_walls,
		"conduit_count": conduit_count,
		"junction_boxes": wall_anchors.size(),
		"substations": substations_built,
		"wire_count": wire_count,
		"dead_ends": dead_ends.size(),
		"entrances": entrance_world,
		"entrance_cells": entrance_cells,
		"sanctum_pos": xf * Vector3.ZERO,   # maze centre, world space
		"shortest_path": min_path,
		"longest_path": max_path,
		"signature": _lab_signature(),
		"reverb_zone": rzone,
	}


func _lab_is_sanctum(cx: int, cz: int) -> bool:
	var mid: int = LAB_CELLS / 2
	return cx >= mid - 1 and cx <= mid and cz >= mid - 1 and cz <= mid


func _lab_touches_sanctum_h(cz: int, cx: int) -> bool:
	var mid: int = LAB_CELLS / 2
	return (cz == mid - 1 or cz == mid + 1) and (cx == mid - 1 or cx == mid)


func _lab_touches_sanctum_v(cz: int, cx: int) -> bool:
	var mid: int = LAB_CELLS / 2
	return (cx == mid - 1 or cx == mid + 1) and (cz == mid - 1 or cz == mid)


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


## Appends a sagging catenary cable between `a` and `b` with outward normals.
func _st_add_cable(st: SurfaceTool, a: Vector3, b: Vector3, sag: float,
		radius: float, segs: int, color: Color, sway := 0.0) -> void:
	var chord := b - a
	var horiz := Vector3(chord.x, 0.0, chord.z)
	var side := Vector3(-horiz.z, 0.0, horiz.x)
	if side.length() > 1e-4:
		side = side.normalized()
	else:
		side = Vector3.RIGHT
	var pts: Array[Vector3] = []
	var n_segs := maxi(segs, 3)
	for i in n_segs + 1:
		var t := float(i) / float(n_segs)
		var env := 4.0 * t * (1.0 - t)
		var p := a.lerp(b, t)
		p.y -= sag * env
		p += side * (sway * env)
		pts.append(p)
	_st_add_tube(st, pts, radius, 5, color)


## Appends a parallel-transported cylindrical tube along `pts` with outward normals & end-caps.
func _st_add_tube(st: SurfaceTool, pts: Array, radius: float, radial: int, color: Color) -> void:
	if pts.size() < 2:
		return
	var rad_n := maxi(radial, 4)
	var p0_init: Vector3 = pts[0]
	var p1_init: Vector3 = pts[1]
	var t0 := (p1_init - p0_init)
	if t0.length() < 1e-5:
		return
	t0 = t0.normalized()
	var ref := Vector3.UP if absf(t0.y) < 0.90 else Vector3.RIGHT
	var r_vec := ref.cross(t0).normalized()
	var u_vec := t0.cross(r_vec).normalized()

	var rings_p: Array = []
	var rings_n: Array = []
	var tangents: Array[Vector3] = []
	var cum_len := 0.0
	var arc_u: Array[float] = []

	for i in pts.size():
		var pi: Vector3 = pts[i]
		if i > 0:
			var prev_p: Vector3 = pts[i - 1]
			cum_len += pi.distance_to(prev_p)
		arc_u.append(cum_len)
		var ti: Vector3
		if i == 0:
			ti = t0
		elif i == pts.size() - 1:
			var prev_last: Vector3 = pts[i - 1]
			var d_last := pi - prev_last
			ti = d_last.normalized() if d_last.length() > 1e-5 else tangents[i - 1]
		else:
			var next_p: Vector3 = pts[i + 1]
			var prev_mid: Vector3 = pts[i - 1]
			var d_mid := next_p - prev_mid
			ti = d_mid.normalized() if d_mid.length() > 1e-5 else tangents[i - 1]
		tangents.append(ti)
		# Parallel transport r_vec orthogonal to ti
		r_vec = r_vec - ti * r_vec.dot(ti)
		if r_vec.length() < 1e-4:
			var ref2 := Vector3.UP if absf(ti.y) < 0.90 else Vector3.RIGHT
			r_vec = ref2.cross(ti)
		r_vec = r_vec.normalized()
		u_vec = ti.cross(r_vec).normalized()

		var rp: Array[Vector3] = []
		var rn: Array[Vector3] = []
		for k in rad_n:
			var ang := TAU * float(k) / float(rad_n)
			var nd := (r_vec * cos(ang) + u_vec * sin(ang)).normalized()
			rn.append(nd)
			rp.append(pi + nd * radius)
		rings_p.append(rp)
		rings_n.append(rn)

	st.set_color(color)
	for i in pts.size() - 1:
		var rp_a: Array = rings_p[i]
		var rn_a: Array = rings_n[i]
		var rp_b: Array = rings_p[i + 1]
		var rn_b: Array = rings_n[i + 1]
		var u_a: float = arc_u[i]
		var u_b: float = arc_u[i + 1]
		for k in rad_n:
			var kn := (k + 1) % rad_n
			var v0: Vector3 = rp_a[k]
			var v1: Vector3 = rp_a[kn]
			var v2: Vector3 = rp_b[kn]
			var v3: Vector3 = rp_b[k]
			var n0: Vector3 = rn_a[k]
			var n1: Vector3 = rn_a[kn]
			var n2: Vector3 = rn_b[kn]
			var n3: Vector3 = rn_b[k]
			var va := float(k) / float(rad_n)
			var vb := float(k + 1) / float(rad_n)
			st.set_normal(n0); st.set_uv(Vector2(u_a, va)); st.add_vertex(v0)
			st.set_normal(n1); st.set_uv(Vector2(u_a, vb)); st.add_vertex(v1)
			st.set_normal(n2); st.set_uv(Vector2(u_b, vb)); st.add_vertex(v2)
			st.set_normal(n0); st.set_uv(Vector2(u_a, va)); st.add_vertex(v0)
			st.set_normal(n2); st.set_uv(Vector2(u_b, vb)); st.add_vertex(v2)
			st.set_normal(n3); st.set_uv(Vector2(u_b, va)); st.add_vertex(v3)

	# Outward-wound end-caps at start (-tangents[0]) and end (+tangents[-1])
	var start_c: Vector3 = pts[0]
	var start_n: Vector3 = -tangents[0]
	var rp_first: Array = rings_p[0]
	for k in rad_n:
		var kn := (k + 1) % rad_n
		var pk: Vector3 = rp_first[k]
		var pkn: Vector3 = rp_first[kn]
		st.set_normal(start_n); st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(start_c)
		st.set_normal(start_n); st.set_uv(Vector2(1.0, 0.5)); st.add_vertex(pkn)
		st.set_normal(start_n); st.set_uv(Vector2(0.5, 1.0)); st.add_vertex(pk)

	var last_idx := pts.size() - 1
	var end_c: Vector3 = pts[last_idx]
	var end_n: Vector3 = tangents[last_idx]
	var rp_last: Array = rings_p[last_idx]
	for k in rad_n:
		var kn := (k + 1) % rad_n
		var pk2: Vector3 = rp_last[k]
		var pkn2: Vector3 = rp_last[kn]
		st.set_normal(end_n); st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(end_c)
		st.set_normal(end_n); st.set_uv(Vector2(1.0, 0.5)); st.add_vertex(pk2)
		st.set_normal(end_n); st.set_uv(Vector2(0.5, 1.0)); st.add_vertex(pkn2)


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
	# the near face of the long wall, at chest height
	_attach_hint = {"pos": Vector3(gap - span * 0.75, 1.45, -3.0 + 0.16), "n": Vector3(0, 0, 1)}


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
	_attach_hint = {"pos": Vector3(-2.2 + 0.225, 1.45, 0.0), "n": Vector3(1, 0, 0)}
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
	# on the shell, away from the ladder and the hatch
	var sa := 0.85
	_attach_hint = {"pos": Vector3(cos(sa) * r, 1.45, sin(sa) * r), "n": Vector3(cos(sa), 0.0, sin(sa))}


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
			# detailed wheel + hub from the model pass (rotated so the axle is X)
			var wheel := _cyl(xf, Vector3(wx, 0.53, wz), 0.53, 0.32, dark, -1.0, false)
			wheel.transform.basis = xf.basis * Basis(Vector3.FORWARD, PI * 0.5)
			var hub := _cyl(xf, Vector3(wx + signf(wx) * 0.18, 0.53, wz), 0.27, 0.045, rust, -1.0, false)
			hub.transform.basis = wheel.transform.basis
	_box(xf, Vector3(0, 0.88, cab_z + 1.4), Vector3(2.35, 0.18, 0.18), rust, Vector3.ZERO, false)
	_box(xf, Vector3(0, 1.3, cab_z + 1.39), Vector3(1.12, 0.35, 0.025), dark, Vector3.ZERO, false)
	for side in [-1.0, 1.0]:
		_box(xf, Vector3(side * 0.81, 1.4, cab_z + 1.4), Vector3(0.30, 0.24, 0.03), _mats["lamp"], Vector3.ZERO, false)
	# page on the driver's door panel; keeps the truck's pinned-page surface
	_attach_hint = {"pos": Vector3(1.125, 1.55, 0.0), "n": Vector3(1, 0, 0)}

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
	_attach_hint = {"pos": Vector3(0.0, 1.45, -d * 0.5 - 0.12), "n": Vector3(0, 0, -1)}


func _rock_circle(xf: Transform3D) -> void:
	var n := rng.randi_range(7, 11)
	var radius := rng.randf_range(2.8, 4.0)
	var stone_hint := {}
	for i in n:
		var a := TAU * float(i) / n + rng.randf_range(-0.15, 0.15)
		var rr := radius * rng.randf_range(0.9, 1.12)
		var p := Vector3(cos(a) * rr, 0, sin(a) * rr)
		var hh := rng.randf_range(1.0, 2.2)
		var rad := rng.randf_range(0.45, 0.75)
		var body := _cyl(xf, p + Vector3(0, hh * 0.5, 0), rad, hh, _mats["stone"], rad * 0.55)
		# The weathered stone is deliberately not cylindrical. Replacing the
		# placeholder cylinder collider with the rendered mesh's static trimesh is
		# what lets a page nail land on the visible rock instead of hovering over
		# an empty corner of the approximation.
		var rock_mesh: Mesh = _weathered_rock(rad, hh, i)
		(body.get_child(0) as MeshInstance3D).mesh = rock_mesh
		var rock_col := body.get_child(1) as CollisionShape3D
		rock_col.shape = rock_mesh.create_trimesh_shape()
		body.rotation = xf.basis.get_rotation_quaternion().get_euler() + Vector3(rng.randf_range(-0.08, 0.08), rng.randf() * 0.6, rng.randf_range(-0.08, 0.08))
		if stone_hint.is_empty() and hh >= 1.7 and rad >= 0.55:
			var dir := Vector3(cos(a), 0.0, sin(a))
			stone_hint = {"pos": p + dir * rad * 0.96 + Vector3(0, 1.45, 0), "n": dir}
	# toppled stone in the middle
	_box(xf, Vector3(rng.randf_range(-0.8, 0.8), 0.4, rng.randf_range(-0.8, 0.8)), Vector3(1.5, 0.8, 0.9), _mats["stone"], Vector3(0.3, rng.randf() * TAU, 0.2))
	if not stone_hint.is_empty():
		_attach_hint = stone_hint


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
	# The back wall is sealed off by the stall dividers (they span w-0.7, wider
	# than the gap either side), so a page there cannot be reached. Hang it on the
	# side wall in the open floor between the stalls and the door.
	_attach_hint = {"pos": Vector3(-w * 0.5 + 0.14, 1.45, d * 0.5 - 1.7), "n": Vector3(1, 0, 0)}


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
	# a scrap board nailed across the legs, so the page here has something to hang on
	_box(xf, Vector3(0, 1.45, half_w + 0.02), Vector3(half_w * 1.7, 0.46, 0.05), _mats["wood"], Vector3.ZERO, true)
	_attach_hint = {"pos": Vector3(0.0, 1.45, half_w + 0.065), "n": Vector3(0, 0, 1)}


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
	tree_positions.clear()
	tree_collision_instances.clear()
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
		p.y = ground_height_at(p)
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
		var tree_xf := Transform3D(basis, p + Vector3(0, -0.12, 0))
		if is_snag and snag_buckets.size() > 0:
			var bi := rng.randi_range(0, snag_buckets.size() - 1)
			snag_buckets[bi]["xf"].append(tree_xf)
			snag_buckets[bi]["col"].append(tint)
			tree_collision_instances.append({"snag": true, "mesh_index": bi, "transform": tree_xf})
		else:
			var bi2 := rng.randi_range(0, buckets.size() - 1)
			buckets[bi2]["xf"].append(tree_xf)
			buckets[bi2]["col"].append(tint)
			tree_collision_instances.append({"snag": false, "mesh_index": bi2, "transform": tree_xf})
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
	# A null override deliberately preserves per-surface materials (stump bark
	# and the end-grain cut face); all other batches use a shared override.
	if mat != null:
		mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Game.quality >= 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


func _tree_collisions() -> void:
	var body := StaticBody3D.new()
	body.name = "TreeCollision"
	add_child(body)
	var shape_cache := {}
	var collider_i := 0
	for instance in tree_collision_instances:
		var snag: bool = bool(instance["snag"])
		var mesh_index: int = int(instance["mesh_index"])
		var key := ("snag_%d" % mesh_index) if snag else ("tree_%d" % mesh_index)
		if not shape_cache.has(key):
			var mesh: Mesh = _snag_meshes[mesh_index] if snag else _tree_meshes[mesh_index]
			shape_cache[key] = TreeCollisionMesh.from_visible_mesh(mesh)
		var shape: Shape3D = shape_cache[key]
		if shape == null:
			continue
		var col := CollisionShape3D.new()
		col.name = "TreeMesh_%d" % collider_i
		col.shape = shape
		col.transform = instance["transform"]
		body.add_child(col)
		collider_i += 1


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
		var stump_override: Material = null if stump_mesh.get_surface_count() >= 2 else _mats["bark"]
		_add_multimesh(stump_mesh, stump_override, xf, col, "Stumps")

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
				p.y = ground_height_at(p)
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
		for spot in spots:
			var p: Vector3 = spot
			p.y = ground_height_at(p)
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
			p.y = ground_height_at(p)
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
		p.y = ground_height_at(p)
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
		var p := Vector3(cos(a) * r, 0.0, sin(a) * r)
		p.y = ground_height_at(p) + 0.02
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
		p.y = ground_height_at(p)
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
	return _lab_xf * Vector3(_lab_cell_coord(c.x), 0.0, _lab_cell_coord(c.y))


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
	if src == dst or (_lab_is_sanctum(src.x, src.y) and _lab_is_sanctum(dst.x, dst.y)):
		var direct := to_pos - from_pos
		direct.y = 0.0
		return direct.normalized() if direct.length() > 0.25 else Vector3.ZERO

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
	# Centerline-aware steering so 90-degree corridor turns never clip corner piers.
	var lp_from: Vector3 = _lab_inv_xf * from_pos
	var src_local := Vector3(_lab_cell_coord(src.x), 0.0, _lab_cell_coord(src.y))
	var nxt_local := Vector3(_lab_cell_coord(next_cell.x), 0.0, _lab_cell_coord(next_cell.y))
	var step_d := next_cell - src
	var target_local := nxt_local
	if step_d.x != 0 and absf(lp_from.z - src_local.z) > 0.32:
		target_local = src_local
	elif step_d.y != 0 and absf(lp_from.x - src_local.x) > 0.32:
		target_local = src_local
	var wp := _lab_xf * target_local
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
