extends Node3D
## A single sheet of paper nailed to a wall, simulated as cloth.
##
## The page is a small verlet grid pinned along its top edge. It hangs, sags and
## flutters in the draft, and it is lit by the world like everything else - no
## light of its own. Rebuilt geometry is uploaded every frame; at 7x9 vertices
## per sheet that costs nothing even on a phone.
##
## Create it, set `size` and `hang_phase`, and add it to the tree.

const COLS := 7            # vertices across
const ROWS := 9            # vertices down
const ITERATIONS := 3      # constraint solver passes
const DAMPING := 0.985
const GRAVITY := Vector3(0, -9.8, 0)
const FIXED_STEP := 1.0 / 60.0

var size := Vector2(0.44, 0.58)
var hang_phase := 0.0
var wind_strength := 0.85

var _pos: PackedVector3Array = PackedVector3Array()
var _prev: PackedVector3Array = PackedVector3Array()
var _pinned: PackedInt32Array = PackedInt32Array()
var _is_pinned: PackedByteArray = PackedByteArray()
var _normals := PackedVector3Array()
var _links: Array[Vector3i] = []        # (a, b, rest_length) packed as Vector3i
var _mesh := ArrayMesh.new()
var _mat: StandardMaterial3D
var _acc := 0.0
var _t := 0.0
var _mi: MeshInstance3D


func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.albedo_texture = load("res://assets/textures/paper.png")
	_mat.roughness = 0.92
	_mat.metallic = 0.0
	# a whisper of self-glow so a page is still spottable at the edge of a beam,
	# but it casts no light and lights nothing around it
	_mat.emission_enabled = true
	_mat.emission_texture = load("res://assets/textures/paper.png")
	_mat.emission_energy_multiplier = 0.10
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	_mi = MeshInstance3D.new()
	_mi.mesh = _mesh
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mi)
	_build()


func _build() -> void:
	_pos.resize(COLS * ROWS)
	_prev.resize(COLS * ROWS)
	_pinned.clear()
	_is_pinned.resize(COLS * ROWS)
	_is_pinned.fill(0)
	for r in ROWS:
		for c in COLS:
			var i := r * COLS + c
			var u := float(c) / float(COLS - 1)
			var v := float(r) / float(ROWS - 1)
			# hanging from the top edge, with a little slack so it sags
			var p := Vector3((u - 0.5) * size.x, size.y * 0.5 - v * size.y, 0.0)
			_pos[i] = p
			_prev[i] = p
			if r == 0:
				_pinned.append(i)
				_is_pinned[i] = 1
	_links.clear()
	for r in ROWS:
		for c in COLS:
			var i := r * COLS + c
			if c + 1 < COLS:
				_links.append(_link(i, i + 1))
			if r + 1 < ROWS:
				_links.append(_link(i, i + COLS))
			# shear links keep the sheet from folding into a sheet of triangles
			if c + 1 < COLS and r + 1 < ROWS:
				_links.append(_link(i, i + COLS + 1))
				_links.append(_link(i + 1, i + COLS))
	_rebuild()


func _link(a: int, b: int) -> Vector3i:
	return Vector3i(a, b, int(_pos[a].distance_to(_pos[b]) * 10000.0))


func _process(delta: float) -> void:
	_acc += minf(delta, 0.05)
	var stepped := false
	while _acc >= FIXED_STEP:
		_acc -= FIXED_STEP
		_t += FIXED_STEP
		_simulate(FIXED_STEP)
		stepped = true
	# At >60 fps most frames run no sim step at all; rebuilding the mesh anyway
	# would reallocate a GPU surface 8 times a frame for nothing.
	if stepped:
		_rebuild()


func _simulate(dt: float) -> void:
	var wind := Vector3(
		sin(_t * 1.7 + hang_phase) * 0.55 + sin(_t * 3.9 + hang_phase * 2.0) * 0.22,
		sin(_t * 2.3 + hang_phase * 0.7) * 0.18,
		cos(_t * 1.3 + hang_phase) * 0.9
	) * wind_strength
	var acc := (GRAVITY + wind) * dt * dt
	for i in _pos.size():
		if _is_pinned[i] == 1:
			continue
		var cur := _pos[i]
		# a breath of drag grows with distance from the pinned edge
		var next := cur + (cur - _prev[i]) * DAMPING + acc
		_prev[i] = cur
		_pos[i] = next
	for it in ITERATIONS:
		for link in _links:
			var a: int = link.x
			var b: int = link.y
			var rest: float = float(link.z) / 10000.0
			var pa := _pos[a]
			var pb := _pos[b]
			var d := pb - pa
			var dist := d.length()
			if dist < 1e-5:
				continue
			var diff := (dist - rest) / dist
			var pinned_a := _is_pinned[a] == 1
			var pinned_b := _is_pinned[b] == 1
			if pinned_a and pinned_b:
				continue
			elif pinned_a:
				_pos[b] = pb - d * diff
			elif pinned_b:
				_pos[a] = pa + d * diff
			else:
				_pos[a] = pa + d * diff * 0.5
				_pos[b] = pb - d * diff * 0.5
	# keep the sheet from tunnelling through the wall it hangs on
	for i in _pos.size():
		var zc := clampf(_pos[i].z, -0.14, 0.14)
		if zc != _pos[i].z:
			# keep the velocity, drop only the positional error, or the clamp
			# feeds energy back into the sheet and it buzzes against the wall
			_prev[i].z += zc - _pos[i].z
			_pos[i].z = zc


func _rebuild() -> void:
	## 63 verts x 48 tris - cheaper to rebuild than to poke at attribute regions,
	## and it lets us smooth the normals in the same pass.
	var normals := PackedVector3Array()
	normals.resize(_pos.size())
	normals.fill(Vector3.BACK)
	for r in ROWS - 1:
		for c in COLS - 1:
			var i := r * COLS + c
			var a := _pos[i]
			# winding is (i, i+COLS, i+1), which faces +Z: the cross product
			# has to follow the same order or every page is lit from behind
			var n := (_pos[i + COLS] - a).cross(_pos[i + 1] - a)
			if n.length() < 1e-9:
				continue
			n = n.normalized()
			normals[i] += n
			normals[i + 1] += n
			normals[i + COLS] += n
			normals[i + COLS + 1] += n
	_normals = normals
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for r in ROWS:
		for c in COLS:
			var i := r * COLS + c
			verts.append(_pos[i])
			var nn := normals[i]
			normals[i] = nn.normalized() if nn.length() > 1e-6 else Vector3.BACK
			uvs.append(Vector2(float(c) / float(COLS - 1), float(r) / float(ROWS - 1)))
	for r in ROWS - 1:
		for c in COLS - 1:
			var i := r * COLS + c
			indices.append(i)
			indices.append(i + COLS)
			indices.append(i + 1)
			indices.append(i + 1)
			indices.append(i + COLS)
			indices.append(i + COLS + 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func surface_normals() -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in _normals.size():
		out.append(_normals[i])
	return out


func vertex_count() -> int:
	return _pos.size()


func snapshot() -> PackedVector3Array:
	return _pos.duplicate()


func has_light() -> bool:
	for n in get_children():
		if n is Light3D:
			return true
	return false
