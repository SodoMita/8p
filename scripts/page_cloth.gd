extends Node3D
## One page, nailed to a surface and hanging off the nail.
##
## The sheet is a verlet grid integrated at a fixed 60 Hz. A real metal nail is
## embedded through the top centre only when the world found an actual visible
## surface with collision; remove that nail and the whole sheet is free to fall.
## The cloth sags under its own weight, stirs in the draft, and carries the note
## text itself - the message is drawn
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
var pin_at_spawn := true
var floor_height := 0.0
var _released := false
var _released_time := 0.0
var _pin_bodies: Array[RigidBody3D] = []

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
	_build()
	if pin_at_spawn:
		_add_nails()


## The message is baked into assets/textures/note_N.png at build time (see
## tools/gen_notes.py). Runtime viewport capture was tried first and proved
## fragile - with eight live SubViewports the sampled texture was sometimes the
## viewport's clear colour instead of the drawn page.
func _note_texture() -> Texture2D:
	var idx := clampi(note_index, 1, 8)
	return load("res://assets/textures/note_%d.png" % idx)


func _add_nails() -> void:
	# One real nail through the top centre of the paper. The node origin is the
	# ray-verified visual/collision surface. Its shaft points along local -Z into
	# that surface and passes through the paper at z=0.006; the head is outside.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.24, 0.22, 0.20)
	mat.metallic = 0.7
	mat.roughness = 0.45
	var pin := RigidBody3D.new()
	pin.name = "PhysicalPageNail"
	pin.freeze = true
	pin.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	pin.collision_layer = 1
	pin.collision_mask = 1
	pin.mass = 0.008
	pin.position = Vector3.ZERO
	add_child(pin)

	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.0035
	shaft_mesh.bottom_radius = 0.0035
	shaft_mesh.height = 0.030
	shaft_mesh.radial_segments = 6
	var shaft := MeshInstance3D.new()
	shaft.name = "NailShaft"
	shaft.mesh = shaft_mesh
	shaft.material_override = mat
	shaft.rotation.x = PI * 0.5
	shaft.position.z = -0.006
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pin.add_child(shaft)
	var shaft_shape := CollisionShape3D.new()
	var shaft_collider := CylinderShape3D.new()
	shaft_collider.radius = 0.0035
	shaft_collider.height = 0.030
	shaft_shape.shape = shaft_collider
	shaft_shape.rotation.x = PI * 0.5
	shaft_shape.position.z = -0.006
	pin.add_child(shaft_shape)

	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.010
	head_mesh.bottom_radius = 0.010
	head_mesh.height = 0.004
	head_mesh.radial_segments = 8
	var head := MeshInstance3D.new()
	head.name = "NailHead"
	head.mesh = head_mesh
	head.material_override = mat
	head.rotation.x = PI * 0.5
	head.position.z = 0.011
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pin.add_child(head)
	var head_shape := CollisionShape3D.new()
	var head_collider := CylinderShape3D.new()
	head_collider.radius = 0.010
	head_collider.height = 0.004
	head_shape.shape = head_collider
	head_shape.rotation.x = PI * 0.5
	head_shape.position.z = 0.011
	pin.add_child(head_shape)
	_pin_bodies.append(pin)


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
			var p := Vector3((u - 0.5) * size.x, -v * size.y, 0.006 if pin_at_spawn else 0.0)
			_pos[i] = p
			_prev[i] = p
			# Exactly one fixed vertex, at the physical nail through the top centre.
			# Without a nail there are no constraints to the landmark or its surface.
			if pin_at_spawn and r == 0 and c == COLS / 2:
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
	if _released:
		_released_time += delta
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
	# The grid lives in the page's local frame, so express real world gravity in
	# that frame too (important once a tilted page is unpinned).
	var gravity_local: Vector3 = global_transform.basis.inverse() * GRAVITY
	var acc := (gravity_local + wind) * dt * dt
	var free_sheet := _pinned.is_empty()
	for i in _pos.size():
		if _is_pinned[i] == 1:
			continue
		var particle_acc := acc
		if free_sheet:
			# Air does not push every point identically: a small spatially varying
			# gust keeps a released sheet fluttering instead of translating as a
			# rigid, perfectly flat rectangle.
			var c := i % COLS
			var r := i / COLS
			var phase := hang_phase + float(c) * 0.71 + float(r) * 0.43
			particle_acc += Vector3(
				sin(_t * 3.1 + phase) * 0.34,
				sin(_t * 2.3 + phase * 0.7) * 0.16,
				cos(_t * 2.7 + phase * 1.3) * 0.38) * dt * dt
		var cur := _pos[i]
		var next := cur + (cur - _prev[i]) * DAMPING + particle_acc
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
	if not _pinned.is_empty():
		# While nailed, the sheet is a thin plane on the verified real surface. It
		# may flap away from that wall, never through it.
		for i in _pos.size():
			var zc := clampf(_pos[i].z, 0.006, 0.16)
			if zc != _pos[i].z:
				_prev[i].z += zc - _pos[i].z
				_pos[i].z = zc
	else:
		# Once the nail is pulled there is no surface constraint at all. The paper
		# falls and flutters freely until each vertex meets the actual ground plane.
		# Work in world space here because a page may have been nailed to a tilted
		# rock, so local Y is not always world-up.
		var inv_global := global_transform.affine_inverse()
		for i in _pos.size():
			var world_pos: Vector3 = global_transform * _pos[i]
			if world_pos.y < floor_height + 0.006:
				world_pos.y = floor_height + 0.006
				var world_prev: Vector3 = global_transform * _prev[i]
				world_prev.y = floor_height + 0.006
				# bleed horizontal velocity on contact so it settles instead of skating
				world_prev.x = lerpf(world_prev.x, world_pos.x, 0.18)
				world_prev.z = lerpf(world_prev.z, world_pos.z, 0.18)
				_pos[i] = inv_global * world_pos
				_prev[i] = inv_global * world_prev


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


func is_pinned() -> bool:
	return not _pinned.is_empty()


## Pull the physical nail: free every cloth vertex and let the nail drop away.
func unpin() -> bool:
	if _pinned.is_empty():
		return false
	_is_pinned.fill(0)
	_pinned.clear()
	_released = true
	_released_time = 0.0
	# Pulling the nail imparts a small, varied twist. Without this, identical
	# gravity on every vertex makes a released page fall like a rigid board.
	var center := Vector3.ZERO
	for p in _pos:
		center += p
	center /= float(_pos.size())
	var spin := Vector3(0.22 * sin(hang_phase), 0.28 * cos(hang_phase), 0.36)
	var drift := Vector3(0.12 * cos(hang_phase), 0.0, 0.16 * sin(hang_phase))
	for i in _pos.size():
		var offset: Vector3 = _pos[i] - center
		var velocity: Vector3 = spin.cross(offset) + drift
		_prev[i] = _pos[i] - velocity * FIXED_STEP
	for pin in _pin_bodies:
		if not is_instance_valid(pin):
			continue
		pin.freeze = false
		pin.linear_velocity = global_transform.basis.z * 0.9 + Vector3.UP * 0.65
		pin.angular_velocity = Vector3(2.4, 1.5, 0.8)
	_pin_bodies.clear()
	return true


func release_age() -> float:
	return _released_time


func world_center() -> Vector3:
	if _pos.is_empty():
		return global_position
	var center := Vector3.ZERO
	for p in _pos:
		center += p
	center /= float(_pos.size())
	return global_transform * center


func pin_rids() -> Array[RID]:
	var out: Array[RID] = []
	for pin in _pin_bodies:
		if is_instance_valid(pin):
			out.append(pin.get_rid())
	return out


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
