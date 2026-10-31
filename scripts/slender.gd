extends Node3D
## "The Tall One" — appears in the tree line, gets closer when you look away,
## and charges if you stare at him.

signal caught_player
signal slender_seen(is_visible: bool)
signal apparition_started

enum Mode { HIDDEN, APPARITION, CHASE }

const MAP_HALF := 58.0
const TALL := 2.55

var player: Node3D
var world: Node
var map_builder: Node
var mode: int = Mode.HIDDEN
var active := false
var dead := false
var visible_now := false
var seen_time := 0.0
var apparition_time := 0.0
var cooldown := 14.0
var lose_time := 0.0
var enraged := false
var _was_visible := false
var _sway := 0.0

var _meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	add_to_group("slender")
	_build_model()
	scale = Vector3(1.08, 1.36, 1.08)
	visible = false


# --------------------------------------------------------------------------- #
# model
# --------------------------------------------------------------------------- #
func _make_material(color: Color, emission := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.95
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	return m


func _add_part(mesh: Mesh, mat: Material, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_meshes.append(mi)
	return mi


func _build_model() -> void:
	# faint self-illumination keeps the silhouette readable against the fog
	var suit := _make_material(Color(0.075, 0.072, 0.08), 0.05)
	var pale := _make_material(Color(0.88, 0.87, 0.82), 0.5)

	var torso := CapsuleMesh.new()
	torso.radius = 0.23
	torso.height = 1.45
	_add_part(torso, suit, Vector3(0, 1.62, 0))

	for side in [-1.0, 1.0]:
		var leg := CylinderMesh.new()
		leg.bottom_radius = 0.075
		leg.top_radius = 0.1
		leg.height = 1.15
		leg.radial_segments = 6
		_add_part(leg, suit, Vector3(0.13 * side, 0.58, 0.0))
		var arm := CylinderMesh.new()
		arm.bottom_radius = 0.055
		arm.top_radius = 0.08
		arm.height = 1.5
		arm.radial_segments = 6
		_add_part(arm, suit, Vector3(0.3 * side, 1.72, 0.02), Vector3(0.0, 0.0, 0.12 * side))

	var tie := BoxMesh.new()
	tie.size = Vector3(0.05, 0.34, 0.02)
	_add_part(tie, _make_material(Color(0.32, 0.32, 0.34), 0.02), Vector3(0, 2.02, 0.19))

	var neck := CylinderMesh.new()
	neck.bottom_radius = 0.06
	neck.top_radius = 0.06
	neck.height = 0.16
	neck.radial_segments = 6
	_add_part(neck, pale, Vector3(0, 2.36, 0))

	var head := SphereMesh.new()
	head.radius = 0.19
	head.height = 0.42
	head.radial_segments = 12
	head.rings = 8
	_add_part(head, pale, Vector3(0, 2.56, 0.01))

	# the tendrils
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	for i in 7:
		var t := CylinderMesh.new()
		t.bottom_radius = 0.012
		t.top_radius = 0.045
		t.height = rng.randf_range(0.9, 1.7)
		t.radial_segments = 4
		var ang := rng.randf_range(-1.0, 1.0)
		_add_part(t, suit,
			Vector3(rng.randf_range(-0.18, 0.18), rng.randf_range(1.2, 1.9), -0.2),
			Vector3(rng.randf_range(-0.5, 0.5), 0, ang))
	_meshes[0].position = Vector3(0, 1.62, 0)


# --------------------------------------------------------------------------- #
# life cycle
# --------------------------------------------------------------------------- #
func setup(p: Node3D, w: Node, mb: Node) -> void:
	player = p
	world = w
	map_builder = mb


func activate() -> void:
	active = true
	mode = Mode.HIDDEN
	cooldown = maxf(6.0, 16.0 - 8.0 * Game.difficulty())
	seen_time = 0.0
	enraged = false


func reset() -> void:
	active = false
	dead = false
	visible = false
	mode = Mode.HIDDEN
	seen_time = 0.0


func deactivate() -> void:
	active = false
	visible = false


func head_position() -> Vector3:
	return global_position + Vector3(0, 2.55 * scale.y, 0)


func _process(delta: float) -> void:
	if not active or dead or player == null:
		return
	var diff := Game.difficulty()
	var to_player := player.global_position - global_position
	to_player.y = 0.0
	var dist := to_player.length()
	_sway += delta
	rotation.y = atan2(to_player.x, to_player.z)

	_update_visibility()

	match mode:
		Mode.HIDDEN:
			cooldown -= delta
			if cooldown <= 0.0:
				_begin_apparition()
		Mode.APPARITION:
			apparition_time += delta
			if visible_now:
				seen_time += delta
				var tolerance := lerpf(2.8, 1.25, diff)
				if seen_time > tolerance:
					_begin_chase()
			else:
				seen_time = maxf(0.0, seen_time - delta * 0.55)
			# gets closer every time you lose sight of him
			if _was_visible and not visible_now and dist > 6.0:
				_step_closer(0.78)
			if apparition_time > lerpf(9.5, 5.5, diff) and not visible_now:
				_vanish(lerpf(11.0, 6.0, diff))
		Mode.CHASE:
			var speed := lerpf(5.2, 8.6, diff) + (2.0 if enraged else 0.0)
			_move_toward_player(speed, delta)
			if visible_now:
				lose_time = 0.0
				enraged = true
			else:
				lose_time += delta
				if lose_time > 5.0:
					_vanish(6.0)
			if dist < 2.0:
				_kill()

	# idle animation
	position.y = sin(_sway * 1.4) * 0.02
	_was_visible = visible_now


func _update_visibility() -> void:
	var vis := _is_seen_by_player()
	if vis != visible_now:
		visible_now = vis
		slender_seen.emit(vis)


func _is_seen_by_player() -> bool:
	if not visible:
		return false
	var cam: Camera3D = player.get("camera")
	if cam == null:
		return false
	var target := global_position + Vector3(0, 2.2, 0)
	var to := target - cam.global_position
	if to.length() > 46.0:
		return false
	if not cam.is_position_in_frustum(target):
		return false
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, target, 1)
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	return hit.is_empty()


# --------------------------------------------------------------------------- #
# behaviour
# --------------------------------------------------------------------------- #
func _begin_apparition() -> void:
	var spot := _find_spot(17.0, 30.0)
	if spot == Vector3.INF:
		cooldown = 3.0
		return
	global_position = spot
	visible = true
	mode = Mode.APPARITION
	apparition_time = 0.0
	seen_time = 0.0
	enraged = false
	apparition_started.emit()
	Sfx.play("appear", -12.0, randf_range(0.92, 1.08))
	if world != null:
		world.on_apparition()


func _begin_chase() -> void:
	mode = Mode.CHASE
	enraged = true
	lose_time = 0.0
	Sfx.play("appear", -4.0, 0.7)
	if world != null:
		world.on_chase_start()


func _vanish(cd: float) -> void:
	visible = false
	mode = Mode.HIDDEN
	cooldown = cd
	seen_time = 0.0
	enraged = false
	# move him away while unseen
	var spot := _find_spot(30.0, 48.0)
	if spot != Vector3.INF:
		global_position = spot


func _step_closer(factor: float) -> void:
	var target := player.global_position
	var dir := (target - global_position)
	dir.y = 0.0
	if dir.length() < 0.1:
		return
	var new_dist := maxf(5.5, dir.length() * factor)
	global_position = target - dir.normalized() * new_dist
	global_position.y = 0.0


func _move_toward_player(speed: float, delta: float) -> void:
	var target := player.global_position
	var dir := target - global_position
	dir.y = 0.0
	if dir.length() < 0.05:
		return
	dir = dir.normalized()
	# steer around anything solid (trunks, walls, silo, truck, shed...)
	var space := get_world_3d().direct_space_state
	if space != null:
		var hit := _probe_hit(space, dir)
		if hit:
			var side := Vector3(-dir.z, 0, dir.x)
			var left_free := not _probe_hit(space, (dir * 0.4 + side).normalized())
			var right_free := not _probe_hit(space, (dir * 0.4 - side).normalized())
			if left_free or right_free:
				if left_free and not right_free:
					dir = (dir * 0.35 + side * 0.65).normalized()
				elif right_free and not left_free:
					dir = (dir * 0.35 - side * 0.65).normalized()
				else:
					var pick := 1.0 if (Time.get_ticks_msec() / 1000) % 2 == 0 else -1.0
					dir = (dir * 0.35 + side * 0.65 * pick).normalized()
			else:
				# boxed in: retreat along the clearest axis
				dir = (dir * -0.6 + side).normalized()
	var step := dir * speed * delta
	global_position += step
	global_position.y = 0.0


func _probe_hit(space: PhysicsDirectSpaceState3D, dir: Vector3) -> bool:
	var from := global_position + Vector3(0, 1.1, 0)
	var to := from + dir * 1.9
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1 | 4
	q.collide_with_areas = false
	var res := space.intersect_ray(q)
	return not res.is_empty()


func _find_spot(min_d: float, max_d: float) -> Vector3:
	var rng := Game.rng()
	var ppos := player.global_position
	var fwd := -player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	for i in 28:
		var ang := rng.randf() * TAU
		var d := rng.randf_range(min_d, max_d)
		var p := ppos + Vector3(cos(ang), 0, sin(ang)) * d
		if Vector2(p.x, p.z).length() > MAP_HALF:
			continue
		var dir := (p - ppos)
		dir.y = 0.0
		dir = dir.normalized()
		# prefer to appear outside of the view cone
		if fwd.dot(dir) > 0.45 and i < 20:
			continue
		if map_builder != null and map_builder.nearest_tree_distance(p, 300) < 1.0:
			continue
		return Vector3(p.x, 0.0, p.z)
	return Vector3.INF


func on_noise(_pos: Vector3, _radius: float) -> void:
	if not active or dead:
		return
	if mode == Mode.HIDDEN and cooldown > 5.0:
		cooldown -= 0.9


func _kill() -> void:
	if dead:
		return
	dead = true
	caught_player.emit()


func force_apparition_in_front(distance := 18.0) -> void:
	var fwd := -player.global_transform.basis.z
	fwd.y = 0.0
	var p := player.global_position + fwd.normalized() * distance
	global_position = Vector3(p.x, 0, p.z)
	visible = true
	mode = Mode.APPARITION
	apparition_time = 0.0
	seen_time = 0.0
	apparition_started.emit()
	if world != null:
		world.on_apparition()


func force_chase() -> void:
	visible = true
	_begin_chase()
