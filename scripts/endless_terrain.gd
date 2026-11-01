extends Node3D
## Endless procedurally generated forest OUTSIDE the fenced arena.
##
## A danger-of-falling-off-the-map is not a feature, so the world keeps going:
## ground, trees and undergrowth are streamed in chunks around the player. The
## arena itself (landmarks, fence, pages) is a fixed 122 m square handled by
## map_builder; this node fills in everything beyond it.
##
## It also owns the dirt road that leads out through the gate and wanders off to
## the horizon, so an escaped player always has somewhere to go.

const CHUNK := 32.0          # metres per chunk
const VIEW := 3              # chunks in each direction around the player
const GROUND_STEP := 4.0     # metres between ground vertices inside a chunk
const TreeCollisionMesh = preload("res://scripts/tree_collision.gd")

var map_builder: Node = null
var quality: int = 1
var gate_centre := Vector3(61, 0, 0)
var focus: Node3D = null

var _chunks := {}            # Vector2i -> Node3D
var _road: MeshInstance3D = null
var _road_pts := PackedVector3Array()
var _road_body: StaticBody3D = null
var _trees: Array[Mesh] = []
var _tree_collision_shapes: Array[ConcavePolygonShape3D] = []
var _mats := {}

var ground_mat: StandardMaterial3D
var tree_mat: StandardMaterial3D
var road_mat: StandardMaterial3D


func setup(mb: Node, focus_node: Node3D, q: int) -> void:
	map_builder = mb
	focus = focus_node
	quality = q
	gate_centre = mb.gate_centre if mb != null else Vector3(61, 0, 0)
	_view = VIEW if quality >= 1 else 2
	_load_assets()
	_build_floor()
	_build_road()
	_update_chunks(true)


func _load_assets() -> void:
	_trees.clear()
	_tree_collision_shapes.clear()
	for i in 6:
		var m: Mesh = load("res://assets/models/tree_%d.res" % i)
		if m != null:
			_trees.append(m)
			_tree_collision_shapes.append(TreeCollisionMesh.from_visible_mesh(m))
	if _trees.is_empty():
		var fallback: Mesh = load("res://assets/models/tree_0.res")
		if fallback != null:
			_trees.append(fallback)
			_tree_collision_shapes.append(TreeCollisionMesh.from_visible_mesh(fallback))

	ground_mat = StandardMaterial3D.new()
	ground_mat.albedo_texture = load("res://assets/textures/ground_albedo.png")
	ground_mat.normal_enabled = true
	ground_mat.normal_texture = load("res://assets/textures/ground_normal.png")
	ground_mat.roughness_texture = load("res://assets/textures/ground_rough.png")
	ground_mat.uv1_triplanar = true           # no stretching on a flat plane at any scale
	ground_mat.uv1_scale = Vector3(0.32, 0.32, 0.32)
	ground_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	var builder_mats: Dictionary = map_builder.get("_mats") if map_builder != null else {}
	var shared_bark: Material = builder_mats.get("bark")
	if shared_bark is StandardMaterial3D:
		tree_mat = shared_bark as StandardMaterial3D
	else:
		# Match MapBuilder._make_materials exactly if this node is previewed alone.
		tree_mat = StandardMaterial3D.new()
		tree_mat.albedo_texture = load("res://assets/textures/bark_albedo.png")
		tree_mat.normal_enabled = true
		tree_mat.normal_texture = load("res://assets/textures/bark_normal.png")
		tree_mat.normal_scale = 0.75
		tree_mat.roughness_texture = load("res://assets/textures/bark_rough.png")
		tree_mat.roughness = 1.0
		tree_mat.uv1_triplanar = true
		tree_mat.uv1_world_triplanar = false
		tree_mat.uv1_triplanar_sharpness = 4.0
		tree_mat.uv1_scale = Vector3.ONE * 0.62
		tree_mat.albedo_color = Color(1.55, 1.50, 1.42)
		tree_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
		tree_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		tree_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	road_mat = StandardMaterial3D.new()
	road_mat.albedo_texture = load("res://assets/textures/ground_albedo.png")
	road_mat.albedo_color = Color(0.62, 0.52, 0.40)
	road_mat.normal_enabled = true
	road_mat.normal_texture = load("res://assets/textures/ground_normal.png")
	road_mat.roughness_texture = load("res://assets/textures/ground_rough.png")
	road_mat.uv1_scale = Vector3(1.0, 1.0, 1.0)   # ribbon UVs are already in metres
	road_mat.roughness = 1.0


func _build_floor() -> void:
	# One enormous, flat collision slab under everything. The playable ground is
	# flat, so this is all the collision the outside world needs - you can never
	# fall out of the map no matter how far you walk.
	var body := StaticBody3D.new()
	body.name = "WorldFloor"
	var shape := BoxShape3D.new()
	shape.size = Vector3(4000.0, 2.0, 4000.0)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# top at -0.02, tucked under the arena floor (top at 0) so the two
	# StaticBody slabs never fight over the same contact plane
	cs.position = Vector3(0, -1.02, 0)
	body.add_child(cs)
	add_child(body)


# --------------------------------------------------------------------------- #
# road out of the gate, wandering to the horizon in both directions
# --------------------------------------------------------------------------- #
func _build_road() -> void:
	if _road != null:
		return
	var pts := PackedVector3Array()
	# start well inside the gate so the ribbon meets the arena floor cleanly
	pts.append(gate_centre + Vector3(-8.0, 0, 0))
	pts.append(gate_centre)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261031
	var p := gate_centre
	var heading := 0.0            # radians, +X
	var z := 0.0
	for i in 26:
		heading += rng.randf_range(-0.20, 0.20)
		var step := rng.randf_range(16.0, 30.0)
		p += Vector3(cos(heading), 0, sin(heading)) * step
		# keep the road roughly heading away from the arena
		if p.x < gate_centre.x + 12.0:
			p.x = gate_centre.x + 12.0
		pts.append(p)
	_road_pts = pts
	var mesh: ArrayMesh = RoadRibbon.build(pts, 4.6, 3.0, 0.07, 4242, 3)
	if mesh == null or mesh.get_surface_count() == 0:
		return
	_road = MeshInstance3D.new()
	_road.name = "GateRoad"
	_road.mesh = mesh
	_road.material_override = road_mat
	_road.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_road)


# --------------------------------------------------------------------------- #
# chunk streaming
# --------------------------------------------------------------------------- #
func _process(_delta: float) -> void:
	if focus == null:
		return
	var key := _chunk_of(focus.global_position)
	if key != _last_key:
		_last_key = key
		_update_chunks(false)
	elif _want.size() > _chunks.size():
		_build_missing()


var _last_key := Vector2i(999999, 999999)
var _view := VIEW
var _want := {}
const BUILD_BUDGET := 4          # desktop chunks per frame, including mesh colliders
const BUILD_BUDGET_MOBILE := 2    # keep collision registration smooth on phones


func _chunk_of(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / CHUNK)), int(floor(p.z / CHUNK)))


func _update_chunks(_initial: bool) -> void:
	if focus == null:
		return
	var centre := _chunk_of(focus.global_position)
	var want := {}
	for dz in range(-_view, _view + 1):
		for dx in range(-_view, _view + 1):
			want[centre + Vector2i(dx, dz)] = true
	for key in _chunks.keys():
		if not want.has(key):
			var node: Node = _chunks[key]
			node.queue_free()
			_chunks.erase(key)
	_want = want
	_build_missing()


## Spreads chunk creation over frames: walking fast used to build 49 chunks in a
## single frame, which is a visible hitch on a phone.
func _build_missing() -> void:
	var made := 0
	var budget := BUILD_BUDGET if quality >= 1 else BUILD_BUDGET_MOBILE
	for key in _want.keys():
		if made >= budget:
			return
		if not _chunks.has(key):
			_chunks[key] = _build_chunk(key)
			made += 1


func _build_chunk(key: Vector2i) -> Node3D:
	var root := Node3D.new()
	root.name = "Chunk_%d_%d" % [key.x, key.y]
	add_child(root)
	var origin := Vector3(key.x * CHUNK, 0.0, key.y * CHUNK)

	# nothing is generated underneath the arena: it has its own floor, trees,
	# props and collisions
	if _chunk_inside_arena(key):
		root.set_meta("arena", true)
		return root

	# --- ground ---------------------------------------------------------
	var plane := PlaneMesh.new()
	# exact chunk size: overlapping strips every seam z-fight badly
	plane.size = Vector2(CHUNK, CHUNK)
	plane.subdivide_width = int(CHUNK / GROUND_STEP)
	plane.subdivide_depth = int(CHUNK / GROUND_STEP)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = ground_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = origin + Vector3(CHUNK * 0.5, -0.02, CHUNK * 0.5)
	root.add_child(mi)

	# --- trees ----------------------------------------------------------
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key) * 31 + 7
	var count := 46 if quality >= 1 else 30
	var buckets := {}
	for m in _trees.size():
		buckets[m] = {"xf": [], "col": []}
	var placed := 0
	var guard := 0
	while placed < count and guard < count * 12:
		guard += 1
		var p := origin + Vector3(rng.randf() * CHUNK, 0, rng.randf() * CHUNK)
		# chunks straddling the fence line would otherwise drop trees inside the
		# arena; the fence sits at +-61, so reject anything within it
		if absf(p.x) <= 62.0 and absf(p.z) <= 62.0:
			continue
		# keep the real road clear (the centreline is a seeded random walk)
		if p.x > gate_centre.x - 14.0 and road_distance(p) < 3.6:
			continue
		var idx := rng.randi_range(0, _trees.size() - 1)
		# Use the same silhouettes, uniform scale, slight lean and buried root as
		# the arena forest; only their seeded positions differ beyond the fence.
		var s := rng.randf_range(0.78, 1.35)
		var tilt := Vector3(rng.randf_range(-0.045, 0.045), rng.randf() * TAU, rng.randf_range(-0.045, 0.045))
		var b := Basis.from_euler(tilt).scaled(Vector3.ONE * s)
		buckets[idx]["xf"].append(Transform3D(b, p + Vector3(0, -0.12, 0)))
		var t := rng.randf_range(0.65, 1.05)
		buckets[idx]["col"].append(Color(t, t, t))
		placed += 1
	for m in _trees.size():
		if buckets[m]["xf"].is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _trees[m]
		mm.instance_count = buckets[m]["xf"].size()
		for i in mm.instance_count:
			mm.set_instance_transform(i, buckets[m]["xf"][i])
			mm.set_instance_color(i, buckets[m]["col"][i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Trees_%d" % m
		mmi.multimesh = mm
		mmi.material_override = tree_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if quality >= 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)

	# One static body per chunk, with one reusable concave mesh shape per tree.
	# The shape is built from that exact variant's visible lower-trunk triangles,
	# so a tree that appears outside the fence is a physical barrier too.
	var collision_body := StaticBody3D.new()
	collision_body.name = "TreeCollision"
	var collider_count := 0
	for m in _trees.size():
		if m >= _tree_collision_shapes.size() or _tree_collision_shapes[m] == null:
			continue
		for xf in buckets[m]["xf"]:
			var col := CollisionShape3D.new()
			col.name = "TreeMesh_%d" % collider_count
			col.shape = _tree_collision_shapes[m]
			col.transform = xf
			collision_body.add_child(col)
			collider_count += 1
	if collider_count > 0:
		root.add_child(collision_body)
	return root


func _chunk_inside_arena(key: Vector2i) -> bool:
	# the arena spans +-61 m; a chunk is skipped only if it is entirely inside it
	var x0 := key.x * CHUNK
	var z0 := key.y * CHUNK
	return x0 > -60.0 and x0 + CHUNK < 60.0 and z0 > -60.0 and z0 + CHUNK < 60.0


func _road_z_at(x: float) -> float:
	# cheap approximation of the road centre for tree rejection: the road runs
	# roughly down +X from the gate, wandering +-10 m
	if x < gate_centre.x - 12.0:
		return 9999.0
	return sin((x - gate_centre.x) * 0.012) * 9.0


## Distance from a point on the ground to the real road centreline. The old
## version guessed the road with a sine and left trees standing in the middle
## of the track.
func road_distance(p: Vector3) -> float:
	var best := 1e9
	for i in _road_pts.size() - 1:
		var a := _road_pts[i]
		var ab := Vector2(_road_pts[i + 1].x - a.x, _road_pts[i + 1].z - a.z)
		var ap := Vector2(p.x - a.x, p.z - a.z)
		var t := clampf(ap.dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		best = minf(best, ap.distance_to(ab * t))
	return best


func stats() -> Dictionary:
	var trees := 0
	var tree_colliders := 0
	for n in _chunks.values():
		for c in n.get_children():
			if c is MultiMeshInstance3D:
				trees += c.multimesh.instance_count
			elif c is StaticBody3D and c.name == "TreeCollision":
				for shape_node in c.get_children():
					if shape_node is CollisionShape3D and shape_node.shape is ConcavePolygonShape3D:
						tree_colliders += 1
	return {
		"chunks": _chunks.size(),
		"trees": trees,
		"tree_colliders": tree_colliders,
		"road": _road != null,
		"road_points": 0,
	}


func clear_chunks() -> void:
	for n in _chunks.values():
		n.queue_free()
	_chunks.clear()
	_want.clear()
	_last_key = Vector2i(999999, 999999)
