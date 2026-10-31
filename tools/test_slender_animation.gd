extends SceneTree
func _new_motion() -> RefCounted:
	var a: RefCounted = load("res://scripts/slender_animation.gd").new()
	a.reset_pose()
	return a

func _initialize() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var parts: Array[MeshInstance3D] = load("res://scripts/slender_model.gd").new().build(host)
	var anim := _new_motion()
	var original_mesh := parts[0].mesh
	anim.bind_meshes(parts)
	assert(anim.materials.size() == 5)
	var regions := {}
	for mesh in parts:
		assert(mesh.material_override is ShaderMaterial)
		assert(mesh.extra_cull_margin >= 0.75)
		var colors: PackedColorArray = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		for j in colors.size():
			var id := roundi(colors[j].r * 8.0)
			assert(id >= 0 and id <= 8)
			regions[id] = true
			assert(roundi(colors[(j / 3) * 3].r * 8.0) == id)
	assert(regions.size() == 9, "Separate segmented tie region required")
	for i in 120: anim.advance(1.0 / 60.0, false, true, false)
	assert(anim.freedom < 0.001)
	var watched_clock: float = anim.clock
	for i in 60: anim.advance(1.0 / 60.0, false, true, false)
	assert(anim.clock - watched_clock < 0.05)
	# No canned gait: chasing in place cannot generate walking or arm pumping.
	for i in 120: anim.advance(1.0 / 60.0, true, false, true)
	assert(anim.phase == 0.0 and anim._step == -1)
	assert(anim.body.length() < 0.001 and anim.arm_lag.length() < 0.001)
	# A planted contact stays in world space until its step is released.
	anim.reset_pose()
	var initial: Vector3 = anim.feet[0]
	for i in 8: anim.advance(1.0 / 60.0, true, false, false, Vector3(0, 0, 1))
	assert((anim.feet[0] + Vector3(0, 0, 8.0 / 60.0)).distance_to(initial) < 0.0001)
	var tie_excursion := 0.0
	for i in 600:
		var v := Vector3(0, 0, 3.0) if i < 240 else Vector3.ZERO
		var turn := 1.2 if i >= 120 and i < 180 else 0.0
		anim.advance(1.0 / 60.0, true, false, true, v, turn)
		tie_excursion = maxf(tie_excursion, absf(anim.tie[4].z - anim.TIE_ROOT.z))
		_check_constraints(anim)
	assert(tie_excursion > 0.001, "Tie must react to inertial forces")
	assert(anim.body.length() < 0.005 and anim.arm_lag.length() < 0.005, "Body springs settle after stopping")
	assert(absf(anim.tie[4].z - anim.TIE_ROOT.z) < 0.015, "Tie settles under gravity")
	# Stress high chase speed, reversal, turns and variable frame intervals.
	for fps in [30.0, 60.0, 144.0]:
		var a := _new_motion()
		for i in int(fps * 3.0):
			var velocity := Vector3(0.4, 0, 9.8 if i < fps * 1.5 else -2.0)
			a.advance(1.0 / fps, true, false, true, velocity, 2.0)
			_check_constraints(a)
	# Teleports reset histories; no accidental impulses across apparitions.
	anim.reset_pose()
	anim.advance_root(1.0 / 60.0, true, false, false, Transform3D.IDENTITY)
	anim.advance_root(1.0 / 60.0, true, false, false, Transform3D(Basis.IDENTITY, Vector3(40, 0, 0)))
	assert(anim.phase == 0.0 and anim._step == -1 and anim.body == Vector3.ZERO)
	assert(parts[0].mesh == original_mesh and host.position == Vector3.ZERO)
	var other_host := Node3D.new()
	root.add_child(other_host)
	var other_parts: Array[MeshInstance3D] = load("res://scripts/slender_model.gd").new().build(other_host)
	var other := _new_motion()
	other.bind_meshes(other_parts)
	assert(anim.materials[0] != other.materials[0] and other.phase == 0.0)
	other_host.queue_free()
	var frozen: float = anim.clock
	anim.advance(-1.0, true, false, true)
	assert(anim.clock == frozen)
	assert(anim.materials[0].get_shader_parameter("tie_nodes").size() == 5)
	print("[animation-test] PASS: 9 regions / 5 batches; velocity-driven contacts, stationary chase, world foot lock, body settling, pinned constrained tie/chest limits, 30/60/144 Hz stress, teleport reset, mesh/root isolation")
	host.queue_free()
	quit()

func _check_constraints(a: RefCounted) -> void:
	assert(a.body.is_finite() and a.body_velocity.is_finite())
	assert(a.arm_lag.is_finite() and a.arm_velocity.is_finite())
	assert(a.tie[0].distance_to(a.TIE_ROOT) < 0.00001)
	for i in range(1, 5):
		assert(a.tie[i].is_finite())
		assert(absf(a.tie[i].distance_to(a.tie[i - 1]) - a.TIE_LINK) < 0.005)
		assert(a.tie[i].z >= 0.1779 and absf(a.tie[i].x) <= 0.1201)
	for i in 2:
		assert(a.legs[i].is_finite() and a.feet[i].is_finite())
		assert(a.feet[i].y >= 0.0699)
