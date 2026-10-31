extends SceneTree
func _initialize() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var parts: Array[MeshInstance3D] = load("res://scripts/slender_model.gd").new().build(host)
	var anim: RefCounted = load("res://scripts/slender_animation.gd").new()
	var original_mesh := parts[0].mesh
	anim.bind_meshes(parts)
	assert(anim.materials.size() == 5)
	var regions := {}
	for mesh in parts:
		assert(mesh.material_override is ShaderMaterial)
		assert(mesh.extra_cull_margin >= 0.3)
		var colors: PackedColorArray = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		assert(not colors.is_empty())
		for j in colors.size():
			var id := roundi(colors[j].r * 8.0)
			assert(id >= 0 and id <= 7)
			regions[id] = true
			assert(roundi(colors[(j / 3) * 3].r * 8.0) == id, "Triangles cannot mix anatomical regions")
		for parameter in ["motion_time", "gait_phase", "chase_amount", "freedom"]:
			assert(mesh.material_override.get_shader_parameter(parameter) != null)
	assert(regions.size() == 8, "All anatomical labels must be present")
	for i in 120: anim.advance(1.0 / 60.0, false, true, false)
	assert(anim.freedom < 0.001 and anim.chase_blend == 0.0)
	var watched_clock: float = anim.clock
	for i in 60: anim.advance(1.0 / 60.0, false, true, false)
	assert(anim.clock - watched_clock < 0.05, "Watched apparition nearly freezes")
	for i in 120: anim.advance(1.0 / 60.0, true, true, true)
	assert(anim.chase_blend > 0.999 and anim.freedom > 0.999)
	assert(anim.phase > 0.0 and anim.phase < TAU)
	assert(parts[0].mesh == original_mesh, "Never rebuild mesh per frame")
	assert(host.position == Vector3.ZERO, "Animation cannot move the gameplay root")
	var other_host := Node3D.new()
	root.add_child(other_host)
	var other_parts: Array[MeshInstance3D] = load("res://scripts/slender_model.gd").new().build(other_host)
	var other_anim: RefCounted = load("res://scripts/slender_animation.gd").new()
	other_anim.bind_meshes(other_parts)
	assert(other_anim.materials[0] != anim.materials[0], "Instances do not share clocks")
	assert(other_anim.clock == 0.0)
	anim.reset_pose()
	assert(anim.clock == 0.0 and anim.phase == 0.0 and anim.chase_blend == 0.0)
	var frozen_clock: float = anim.clock
	anim.advance(-1.0, true, false, true)
	assert(anim.clock == frozen_clock)
	print("[animation-test] PASS: anatomical regions, 5 batches, observation freeze, chase blending, phase, mesh reuse, root isolation, instance isolation, reset")
	host.queue_free()
	other_host.queue_free()
	quit()
