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
	cam.position = Vector3(2.0, 3.0, 10.0) if view == "front" else Vector3(-3.0, 3.0, -10.0)
	cam.look_at(Vector3(0, 2.65, 0))
	if view == "side":
		cam.position = Vector3(10.0, 3.0, 3.5)
		cam.look_at(Vector3(0, 2.65, 0))
	if view == "tie":
		cam.position = Vector3(0.65, 4.47, 2.3)
		cam.look_at(Vector3(0, 4.31, 0))
	if view == "hands":
		cam.position = Vector3(.90,2.75,1.0)
		cam.look_at(Vector3(.44,2.65,.08))
	cam.fov = 38
	cam.current = true
	if animate:
		DirAccess.make_dir_recursive_absolute("res://screenshots/animation_frames")
		for i in 216:
			var chasing := i >= 36 and i < 156
			var speed := 0.0
			if i >= 36 and i < 60: speed = float(i - 36) / 24.0 * 3.0
			elif i >= 60 and i < 132: speed = 3.0
			elif i >= 132 and i < 156: speed = float(156 - i) / 24.0 * 3.0
			var turn := 1.4 if i >= 84 and i < 108 else 0.0
			sl._animation.advance(1.0 / 24.0, chasing, false, chasing, Vector3(0, 0, speed), turn)
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://screenshots/animation_frames/%03d.png" % i)
		print("[preview] captured 216 procedural animation frames")
	for i in 12: await process_frame
	await RenderingServer.frame_post_draw
	var path := "res://screenshots/slender_%s_%s.png" % [label, view]
	root.get_texture().get_image().save_png(path)
	print("[preview] saved ", path)
	quit()
