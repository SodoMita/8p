extends SceneTree
## Reproducible GL model inspection. -- --label=before|after --view=front|back
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var label := "after"
	var view := "front"
	var animate := false
	for arg in OS.get_cmdline_user_args():
		if arg == "--animate": animate = true
		if arg.begins_with("--label="): label = arg.get_slice("=", 1)
		if arg.begins_with("--view="): view = arg.get_slice("=", 1)
	var stage := Node3D.new()
	root.add_child(stage)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.055, 0.068, 0.083)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.64, 0.8)
	e.ambient_light_energy = 0.65
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	stage.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, -30, 0)
	light.light_energy = 1.8
	stage.add_child(light)
	var rim := OmniLight3D.new()
	rim.position = Vector3(-2, 3, -2)
	rim.light_color = Color(0.4, 0.6, 0.85)
	rim.light_energy = 3.0
	rim.omni_range = 8
	stage.add_child(rim)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.04, 0.05, 0.06)
	ground.material_override = gm
	stage.add_child(ground)
	var sl: Node3D = load("res://scripts/slender.gd").new()
	stage.add_child(sl)
	sl.visible = true
	var cam := Camera3D.new()
	stage.add_child(cam)
	cam.position = Vector3(1.6, 2.1, 7.0) if view == "front" else Vector3(-2.6, 2.2, -6.8)
	cam.look_at(Vector3(0, 1.9, 0))
	cam.fov = 38
	cam.current = true
	if animate:
		DirAccess.make_dir_recursive_absolute("res://screenshots/animation_frames")
		for i in 144:
			var chasing := i >= 72
			var watched := i >= 36 and i < 72
			sl._animation.advance(1.0 / 24.0, chasing, watched, chasing)
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://screenshots/animation_frames/%03d.png" % i)
		print("[preview] captured 144 animation frames")
	for i in 12: await process_frame
	await RenderingServer.frame_post_draw
	var path := "res://screenshots/slender_%s_%s.png" % [label, view]
	root.get_texture().get_image().save_png(path)
	print("[preview] saved ", path)
	quit()
