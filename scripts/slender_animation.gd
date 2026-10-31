extends RefCounted
## Movement-driven contact stepping, sagittal two-bone IK, damped body/arms,
## and a constrained particle necktie. No canned gait or gameplay-root writes.
const HIP_Y := 1.13
const LEG := 0.53
const TIE_ROOT := Vector3(0, 2.176, 0.185)
const TIE_LINK := 0.074
var materials: Array[ShaderMaterial] = []
var clock := 0.0
var phase := 0.0 # retained for inspection: accumulated travel, not a walk-cycle clock
var chase_blend := 0.0
var freedom := 1.0
var body := Vector3.ZERO # pitch, vertical weight shift, roll
var body_velocity := Vector3.ZERO
var arm_lag := Vector2.ZERO
var arm_velocity := Vector2.ZERO
var legs: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO] # hip pitch, knee, hip roll
var feet: Array[Vector3] = []
var tie: PackedVector3Array = []
var _tie_h := 1.0 / 120.0
var _tie_old: PackedVector3Array = []
var _velocity := Vector3.ZERO
var _step := -1
var _swing := [false, false]
var _progress := [0.0, 0.0]
var _duration := [0.22, 0.22]
var _starts: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _ends: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _root_valid := false
var _last_root := Transform3D.IDENTITY

func bind_meshes(meshes: Array[MeshInstance3D]) -> void:
	materials.clear()
	var shader := preload("res://shaders/slender_motion.gdshader")
	for mesh in meshes:
		var source := mesh.material_override as StandardMaterial3D
		assert(source != null)
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("base_color", source.albedo_color)
		mat.set_shader_parameter("surface_roughness", source.roughness)
		mat.set_shader_parameter("glow", source.emission_energy_multiplier)
		mesh.material_override = mat
		mesh.extra_cull_margin = 0.8
		materials.append(mat)
	reset_pose()

func reset_pose() -> void:
	clock = 0.0
	phase = 0.0
	chase_blend = 0.0
	freedom = 1.0
	body = Vector3.ZERO
	body_velocity = Vector3.ZERO
	arm_lag = Vector2.ZERO
	arm_velocity = Vector2.ZERO
	_velocity = Vector3.ZERO
	feet = [Vector3(-0.13, 0.07, 0.02), Vector3(0.13, 0.07, 0.02)]
	_step = -1
	_swing = [false, false]
	_progress = [0.0, 0.0]
	_starts = [Vector3.ZERO, Vector3.ZERO]
	_ends = [Vector3.ZERO, Vector3.ZERO]
	_root_valid = false
	tie.clear()
	_tie_old.clear()
	_tie_h = 1.0 / 120.0
	for i in 5:
		tie.append(TIE_ROOT + Vector3(0, -TIE_LINK * i, 0))
		_tie_old.append(tie[i])
	_solve_legs()
	_upload()

func advance_root(delta: float, chasing: bool, watched: bool, enraged: bool, root: Transform3D) -> void:
	if delta <= 0.0: return
	if not _root_valid:
		_last_root = root
		_root_valid = true
	var displacement := root.origin - _last_root.origin
	var yaw := wrapf(root.basis.orthonormalized().get_euler().y - _last_root.basis.orthonormalized().get_euler().y, -PI, PI)
	# Apparitions/teleports/reseats are not physical impacts. Clear contact and
	# particle history instead of injecting explosive acceleration into the tie.
	if displacement.length() > maxf(0.5, 14.0 * delta) or absf(yaw) > 1.2 or delta > 0.2:
		reset_pose()
		_root_valid = true
		_last_root = root
		return
	var local_velocity := root.basis.inverse() * displacement / delta
	local_velocity.y = 0.0
	_last_root = root
	advance(delta, chasing, watched, enraged, local_velocity, yaw / delta)

func advance(delta: float, chasing: bool, watched: bool, _enraged: bool, local_velocity := Vector3.ZERO, turn_rate := 0.0) -> void:
	if delta <= 0.0 or not is_finite(delta): return
	var dt := minf(delta, 0.1)
	var velocity := local_velocity.limit_length(12.0)
	velocity.y = 0.0
	var turn := clampf(turn_rate, -4.0, 4.0)
	var acceleration := ((velocity - _velocity) / dt).limit_length(20.0)
	acceleration.x += clampf(turn * velocity.z, -10.0, 10.0)
	_velocity = velocity
	# Substeps keep the springs and distance-joint solver stable at low FPS.
	var count := maxi(1, ceili(dt / (1.0 / 120.0)))
	var h := dt / count
	for j in count:
		var blend := 1.0 - exp(-h * 6.0)
		chase_blend = lerpf(chase_blend, 1.0 if chasing else 0.0, blend)
		freedom = lerpf(freedom, 0.0 if watched and not chasing else 1.0, blend)
		clock += h * lerpf(0.045, 1.0, freedom)
		var speed := velocity.length()
		phase += speed * h
		_contacts(h, velocity, turn)
		var drop := -minf(0.17, speed * 0.024)
		var support := -0.008 if _step >= 0 else 0.0
		var target := Vector3(clampf(velocity.z * 0.008 + acceleration.z * 0.001, -0.035, 0.075), drop + support, clampf(-acceleration.x * 0.002, -0.025, 0.025))
		var previous_body_velocity := body_velocity
		body_velocity += ((target - body) * 100.0 - body_velocity * 19.0) * h
		body += body_velocity * h
		body.x = clampf(body.x, -0.05, 0.09)
		body.y = clampf(body.y, -0.19, 0.01)
		body.z = clampf(body.z, -0.035, 0.035)
		var arm_target := Vector2(clampf(velocity.z * 0.006 + acceleration.z * 0.004, -0.08, 0.10), clampf(-turn * 0.022 - acceleration.x * 0.003, -0.09, 0.09))
		arm_velocity += ((arm_target - arm_lag) * 35.0 - arm_velocity * 10.0) * h
		arm_lag += arm_velocity * h
		var body_acceleration := (body_velocity - previous_body_velocity) / h
		var chest_acceleration := Vector3(-body_acceleration.z, body_acceleration.y, body_acceleration.x) * 1.046
		_tie_physics(h, (acceleration + chest_acceleration).limit_length(25.0), turn)
	_solve_legs()
	_upload()

func _contacts(h: float, velocity: Vector3, turn: float) -> void:
	# World-planted contacts move opposite the root in model coordinates. Each
	# leg has its own swing state: a fast chase can overlap recovery, rather than
	# forcing the support leg past reach while waiting for the other foot.
	var speed := velocity.length()
	for i in 2:
		feet[i] = (feet[i] - velocity * h).rotated(Vector3.UP, -turn * h)
		_starts[i] = (_starts[i] - velocity * h).rotated(Vector3.UP, -turn * h)
		_ends[i] = (_ends[i] - velocity * h).rotated(Vector3.UP, -turn * h)
	for i in 2:
		var other := 1 - i
		var home := Vector3(-0.13 if i == 0 else 0.13, 0.07, 0.02)
		var error := Vector2(feet[i].x - home.x, feet[i].z - home.z).length()
		var can_release: bool = not _swing[other] or (speed > 2.2 and _progress[other] > (0.22 if speed > 6.0 else 0.35))
		if not _swing[i] and error > 0.19 and can_release:
			_swing[i] = true
			_progress[i] = 0.0
			_duration[i] = clampf(0.28 - speed * 0.012, 0.16, 0.32)
			_starts[i] = feet[i]
			var lead := velocity.normalized() * minf(0.34, speed * 0.075)
			_ends[i] = home + velocity * _duration[i] + lead
		if _swing[i]:
			_progress[i] = minf(1.0, _progress[i] + h / _duration[i])
			var t: float = _progress[i]
			var ease := t * t * (3.0 - 2.0 * t)
			feet[i] = _starts[i].lerp(_ends[i], ease)
			feet[i].y = 0.07 + 16.0 * t*t * (1.0-t)*(1.0-t) * minf(0.075, 0.025 + speed * 0.009)
			if t >= 1.0:
				feet[i].y = 0.07
				_swing[i] = false
	_step = 0 if _swing[0] else (1 if _swing[1] else -1)

func _solve_legs() -> void:
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip := Vector3(side * 0.10, HIP_Y + body.y, 0)
		var v := feet[i] - hip
		var distance := clampf(v.length(), 0.2, LEG * 2.0 - 0.0005)
		var bend := acos(clampf((2.0 * LEG * LEG - distance*distance) / (2.0 * LEG * LEG), -1.0, 1.0))
		var knee := PI - bend
		var pitch := atan2(-v.z, -v.y) - knee * 0.5
		var roll := atan2(v.x, maxf(0.2, -v.y))
		legs[i] = Vector3(pitch, knee, clampf(roll, -0.20, 0.20))

func _tie_physics(h: float, acceleration: Vector3, turn: float) -> void:
	# Five particles joined by four fixed-length distance constraints: a light
	# articulated pendulum, not a decorative sine wave. The first node is pinned.
	var force := Vector3(-acceleration.x * 0.45 - turn * 0.12, -7.2 - acceleration.y, -acceleration.z * 0.65)
	for i in range(1, 5):
		var current := tie[i]
		var inertia := (current - _tie_old[i]) * (h / _tie_h) * exp(-3.5 * h)
		tie[i] += inertia + force * h * h
		_tie_old[i] = current
	for iteration in 12:
		tie[0] = TIE_ROOT
		for i in range(1, 5):
			var d := tie[i] - tie[i - 1]
			var length := maxf(d.length(), 0.00001)
			var correction := d * (1.0 - TIE_LINK / length)
			if i == 1: tie[i] -= correction
			else:
				tie[i - 1] += correction * 0.5
				tie[i] -= correction * 0.5
			# Chest contact and lateral excursion limit. The tie cannot pass into
			# the shirt, invert over the knot, or whip across the face.
			tie[i].z = clampf(tie[i].z, 0.178, 0.42)
			tie[i].x = clampf(tie[i].x, -0.12, 0.12)
			tie[i].y = minf(tie[i].y, TIE_ROOT.y - i * 0.035)
	tie[0] = TIE_ROOT
	_tie_h = h

func _upload() -> void:
	for mat in materials:
		mat.set_shader_parameter("motion_time", clock)
		mat.set_shader_parameter("chase_amount", chase_blend)
		mat.set_shader_parameter("freedom", freedom)
		mat.set_shader_parameter("body_pose", body)
		mat.set_shader_parameter("arm_lag", arm_lag)
		mat.set_shader_parameter("left_leg", legs[0])
		mat.set_shader_parameter("right_leg", legs[1])
		mat.set_shader_parameter("tie_nodes", tie)
