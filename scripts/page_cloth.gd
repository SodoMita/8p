extends Node3D
## One page, nailed to a surface and hanging off the nail.
##
## The sheet is a verlet grid pinned along its top edge, integrated at a fixed
## 60 Hz. It sags under its own weight, stirs in the draft, cannot pass through
## the wall it hangs on, and carries the note text itself - the message is drawn
## into a texture at build time (tools/gen_notes.py) and used as the albedo, so
## the page in the world is the message you get when you pick it up.
##
## No light of its own: no emission, no OmniLight. In the dark a page is dark
## until the flashlight finds it.

const COLS := 7
const ROWS := 9
const ITERATIONS := 3
const DAMPING := 0.985
const GRAVITY := Vector3(0, -9.8, 0)
const FIXED_STEP := 1.0 / 60.0
const NOTE_TEX := Vector2i(512, 672)

var size := Vector2(0.44, 0.58)
var hang_phase := 0.0
var wind_strength := 0.22
var note_index := 1

var _pos: PackedVector3Array = PackedVector3Array()
var _prev: PackedVector3Array = PackedVector3Array()
var _pinned: PackedInt32Array = PackedInt32Array()
var _is_pinned: PackedByteArray = PackedByteArray()
var _links: Array[Vector3i] = []
var _mesh := ArrayMesh.new()
var _mat: StandardMaterial3D
var _normals := PackedVector3Array()
var _acc := 0.0
var _t := 0.0
var _mi: MeshInstance3D


func _ready() -> void:
	_mat = StandardMaterial3D.new()
	var paper: Texture2D = _note_texture()
	_mat.albedo_texture = paper if paper != null else load("res://assets/textures/page_blank.png")
	_mat.roughness = 0.94
	_mat.metallic = 0.0
	_mat.metallic_specular = 0.2
	# deliberately no emission: a page is only visible where a light reaches it
	_mat.emission_enabled = false
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	_mi = MeshInstance3D.new()
	_mi.mesh = _mesh
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mi)
	_add_nails()
	_build()


## The message is baked into assets/textures/note_N.png at build time (see
## tools/gen_notes.py). Runtime viewport capture was tried first and proved
## fragile - with eight live SubViewports the sampled texture was sometimes the
## viewport's clear colour instead of the drawn page.
func _note_texture() -> Texture2D:
	var idx := clampi(note_index, 1, 8)
	return load("res://assets/textures/note_%d.png" % idx)


func _add_nails() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.24, 0.22, 0.20)
	mat.metallic = 0.7
	mat.roughness = 0.45
	for sx in [-0.17, 0.17]:
		var nail := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.007
		cyl.bottom_radius = 0.007
		cyl.height = 0.022
		cyl.radial_segments = 6
		cyl.rings = 1
		nail.mesh = cyl
		nail.material_override = mat
		nail.rotation = Vector3(PI * 0.5, 0, 0)
		nail.position = Vector3(sx, -0.004, 0.011)
		nail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(nail)


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
			# the nail is the origin: the top row sits at y = 0 and the sheet
			# hangs down from there, so the page hangs off the nail, not near it
			var p := Vector3((u - 0.5) * size.x, -v * size.y, 0.0)
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
	if stepped:
		_rebuild()


func _simulate(dt: float) -> void:
	# the draft blows out of the wall, never into it
	var wind := Vector3(
		sin(_t * 1.7 + hang_phase) * 0.55 + sin(_t * 3.9 + hang_phase * 2.0) * 0.22,
		sin(_t * 2.3 + hang_phase * 0.7) * 0.18,
		(0.35 + absf(cos(_t * 1.3 + hang_phase)) * 0.65) * 0.55
	) * wind_strength
	var acc := (GRAVITY + wind) * dt * dt
	for i in _pos.size():
		if _is_pinned[i] == 1:
			continue
		var cur := _pos[i]
		var next := cur + (cur - _prev[i]) * DAMPING + acc
		_prev[i] = cur
		_pos[i] = next
	for _it in ITERATIONS:
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
	# the wall is at local z = 0: the sheet can flap away from it, never through
	for i in _pos.size():
		var zc := clampf(_pos[i].z, 0.006, 0.16)
		if zc != _pos[i].z:
			_prev[i].z += zc - _pos[i].z
			_pos[i].z = zc


func _rebuild() -> void:
	var normals := PackedVector3Array()
	normals.resize(_pos.size())
	normals.fill(Vector3.BACK)
	for r in ROWS - 1:
		for c in COLS - 1:
			var i := r * COLS + c
			var a := _pos[i]
			# outward: for a flat sheet this is +Z, i.e. out of the wall
			var n := ((_pos[i + COLS] - a).cross(_pos[i + 1] - a)).normalized()
			if n.length() < 1e-9:
				continue
			n = n.normalized()
			normals[i] += n
			normals[i + 1] += n
			normals[i + COLS] += n
			normals[i + COLS + 1] += n
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
			# wound so the front face points the same way as the normals; with
			# the other order the visible face is a back face and Godot shades
			# it with a flipped normal, which is what made pages render navy
			indices.append(i)
			indices.append(i + 1)
			indices.append(i + COLS)
			indices.append(i + 1)
			indices.append(i + COLS + 1)
			indices.append(i + COLS)
	_normals = normals
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func surface_normals() -> PackedVector3Array:
	return _normals


func vertex_count() -> int:
	return _pos.size()


func snapshot() -> PackedVector3Array:
	return _pos.duplicate()


func has_light() -> bool:
	for n in get_children():
		if n is Light3D:
			return true
	return false


func is_emissive() -> bool:
	return _mat != null and _mat.emission_enabled


func note_is_visible() -> bool:
	return _mat != null and _mat.albedo_texture != null
