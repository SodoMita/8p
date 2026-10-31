extends SceneTree
## Controlled main-vs-revision render and material-only performance comparison.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1280,720)
	var stage := Node3D.new()
	root.add_child(stage)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.08,0.09,0.1)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.7,0.75,0.8)
	environment.environment.ambient_light_energy = 0.65
	stage.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35,-35,0)
	stage.add_child(light)
	var camera := Camera3D.new()
	camera.fov = 55
	camera.current = true
	stage.add_child(camera)
	var map = load("res://scripts/map_builder.gd").new()
	stage.add_child(map)
	map._make_materials()
	var wall := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(14,3.6,0.45)
	wall.mesh = mesh
	wall.position.y = 1.8
	stage.add_child(wall)
	var baseline := StandardMaterial3D.new()
	baseline.albedo_texture = load("res://assets/textures/stone_albedo.png")
	baseline.normal_enabled = true
	baseline.normal_texture = load("res://assets/textures/stone_normal.png")
	baseline.normal_scale = 0.85
	baseline.roughness_texture = load("res://assets/textures/stone_rough.png")
	baseline.uv1_triplanar = true
	baseline.uv1_world_triplanar = true
	baseline.uv1_scale = Vector3.ONE / 1.2
	baseline.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	baseline.cull_mode = BaseMaterial3D.CULL_DISABLED
	DirAccess.make_dir_recursive_absolute("res://screenshots/concrete_revision")
	for version in ["main","revised"]:
		wall.material_override = baseline if version == "main" else map._mats["concrete"]
		for shot in ["close","20m"]:
			camera.position = Vector3(0.8,2.0,3.0) if shot == "close" else Vector3(5.0,4.5,20.0)
			camera.look_at(Vector3(0,1.8,0))
			for i in 3:
				await process_frame
				await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://screenshots/concrete_revision/%s_%s.png" % [version,shot])
		# Same near-fullscreen wall, no forest/camera stack: material-only cost.
		camera.position = Vector3(0.8,2.0,3.0)
		camera.look_at(Vector3(0,1.8,0))
		for i in 10:
			await process_frame
			await RenderingServer.frame_post_draw
		var t0 := Time.get_ticks_usec()
		for i in 40:
			await process_frame
			await RenderingServer.frame_post_draw
		var ms := (Time.get_ticks_usec() - t0) / 40000.0
		print("[material_perf] %s %.2f ms/frame %.2f FPS (isolated fullscreen wall, llvmpipe)" % [version,ms,1000.0/ms])
	stage.free()
	quit()
