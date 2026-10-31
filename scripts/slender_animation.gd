extends RefCounted
## Five GPU material batches, no Skeleton3D CPU skinning or per-frame mesh rebuild.
## Animation is visual-only: never writes a gameplay node transform or clock.

var materials: Array[ShaderMaterial] = []
var clock := 0.0
var phase := 0.0
var chase_blend := 0.0
var freedom := 1.0

func bind_meshes(meshes: Array[MeshInstance3D]) -> void:
	materials.clear()
	var shader := preload("res://shaders/slender_motion.gdshader")
	for mesh in meshes:
		var source := mesh.material_override as StandardMaterial3D
		assert(source != null, "Bind the undeformed model materials exactly once")
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("base_color", source.albedo_color)
		mat.set_shader_parameter("surface_roughness", source.roughness)
		mat.set_shader_parameter("glow", source.emission_energy_multiplier)
		mesh.material_override = mat
		# Vertex motion must not be clipped by the rest-pose AABB at screen edges.
		mesh.extra_cull_margin = 0.75
		materials.append(mat)
	reset_pose()

func reset_pose() -> void:
	clock = 0.0
	phase = 0.0
	chase_blend = 0.0
	freedom = 1.0
	_upload()

func advance(delta: float, chasing: bool, watched: bool, enraged: bool) -> void:
	if delta <= 0.0:
		return
	# Exponential damping is frame-rate independent; avoids a pop on state changes.
	var blend := 1.0 - exp(-delta * 5.0)
	chase_blend = lerpf(chase_blend, 1.0 if chasing else 0.0, blend)
	freedom = lerpf(freedom, 0.0 if watched and not chasing else 1.0, blend)
	# Watched apparitions almost freeze; chase keeps moving even under observation.
	clock += delta * lerpf(0.045, 1.0, freedom)
	phase = fmod(phase + delta * (9.0 if enraged else 7.2) * chase_blend, TAU)
	_upload()

func _upload() -> void:
	for mat in materials:
		mat.set_shader_parameter("motion_time", clock)
		mat.set_shader_parameter("gait_phase", phase)
		mat.set_shader_parameter("chase_amount", chase_blend)
		mat.set_shader_parameter("freedom", freedom)
