extends SceneTree
## Real GL equivalence test: geometry dimensions vs node / parent / MultiMesh scale.
## xvfb-run -a godot --path . --rendering-method gl_compatibility --script tools/world_material_test.gd
var failed := 0

func _initialize() -> void:
	call_deferred("_run")

func _capture() -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _run() -> void:
	root.size = Vector2i(640, 480)
	var stage := Node3D.new()
	root.add_child(stage)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(3.5, 2.4, 4.5)
	camera.look_at(Vector3.ZERO)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 3.8
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-38, -25, 0)
	stage.add_child(light)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.03, 0.04, 0.05)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.7,0.7,0.7)
	environment.environment.ambient_light_energy = 0.6
	stage.add_child(environment)
	var map = load("res://scripts/map_builder.gd").new()
	stage.add_child(map)
	map._make_materials()
	DirAccess.make_dir_recursive_absolute("res://screenshots/world_materials")
	for key in ["stone", "bark", "wood", "ground", "concrete", "metal", "rust", "pumpkin"]:
		var material: Material = map._mats[key]
		if material is StandardMaterial3D:
			if not material.uv1_triplanar or not material.uv1_world_triplanar or not material.uv1_scale.is_equal_approx(Vector3.ONE * material.uv1_scale.x):
				failed += 1
		var full := BoxMesh.new()
		full.size = Vector3(2.0, 1.6, 0.55)
		var mi := MeshInstance3D.new()
		mi.mesh = full
		mi.material_override = material
		mi.rotation = Vector3(0.13, 0.47, 0.08)
		mi.position = Vector3(0.12, 0.08, -0.1)
		stage.add_child(mi)
		var reference := await _capture()
		reference.save_png("res://screenshots/world_materials/%s_dimensions.png" % key)
		mi.free()
		for mode in ["node", "parent", "multimesh"]:
			var holder := Node3D.new()
			stage.add_child(holder)
			holder.rotation = Vector3(0.13, 0.47, 0.08)
			holder.position = Vector3(0.12, 0.08, -0.1)
			var unit := BoxMesh.new()
			unit.size = Vector3.ONE
			var scale_value := Vector3(2.0, 1.6, 0.55)
			if mode == "multimesh":
				var multi := MultiMeshInstance3D.new()
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = unit
				mm.instance_count = 1
				mm.set_instance_transform(0, Transform3D(Basis.from_scale(scale_value), Vector3.ZERO))
				multi.multimesh = mm
				multi.material_override = material
				holder.add_child(multi)
			else:
				var scaled := MeshInstance3D.new()
				scaled.mesh = unit
				scaled.material_override = material
				holder.add_child(scaled)
				if mode == "parent":
					holder.scale = scale_value
				else:
					scaled.scale = scale_value
			var result := await _capture()
			result.save_png("res://screenshots/world_materials/%s_%s.png" % [key,mode])
			var sum := 0.0
			var count := 0
			for y in range(0, reference.get_height(), 2):
				for x in range(0, reference.get_width(), 2):
					var a := reference.get_pixel(x,y)
					var b := result.get_pixel(x,y)
					sum += absf(a.r-b.r) + absf(a.g-b.g) + absf(a.b-b.b)
					count += 3
			var error := sum / count
			# Allow edge rasterization / filtering round-off, not stretched detail.
			if error > 0.003:
				failed += 1
			print("[world_material_test] %s / %s mean RGB error %.6f %s" % [key,mode,error,"PASS" if error <= 0.003 else "FAIL"])
			holder.free()
	print("[world_material_test] failures: ", failed)
	stage.free()
	quit(0 if failed == 0 else 1)
