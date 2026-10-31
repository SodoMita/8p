extends SceneTree
## xvfb-run -a godot --path . --rendering-method gl_compatibility --script tools/pumpkin_material_test.gd
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1000,650)
	var stage := Node3D.new()
	root.add_child(stage)
	var map = load("res://scripts/map_builder.gd").new()
	stage.add_child(map)
	map._make_materials()
	var material: Material = map._mats["pumpkin"]
	if not material is ShaderMaterial or material.shader.resource_path != "res://shaders/pumpkin_skin.gdshader":
		failures += 1
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(1.5,1.05,2.6)
	camera.fov = 42
	camera.look_at(Vector3(0,0.35,0))
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48,-30,0)
	light.light_energy = 2.0
	stage.add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.08,0.09,0.1)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7,0.75,0.85)
	env.environment.ambient_light_energy = 0.65
	stage.add_child(env)
	for i in 3:
		var mesh: ArrayMesh = load("res://assets/models/pumpkin_%d.res" % i)
		var arrays := mesh.surface_get_arrays(0)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var stem := 0
		var rind := 0
		for k in vertices.size():
			if not vertices[k].is_finite() or not normals[k].is_finite() or normals[k].length() < 0.9:
				failures += 1
			if colors[k].a < 0.5:
				stem += 1
			else:
				rind += 1
		if stem == 0 or rind == 0:
			failures += 1
		var multi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D(Basis.from_euler(Vector3(0,i * 0.8,0)),Vector3((i-1)*0.85,0.34,-(i%2)*0.32)))
		mm.set_instance_color(0,Color(0.85,0.85,0.85,1.0))
		multi.multimesh = mm
		multi.material_override = material
		stage.add_child(multi)
		print("[pumpkin_material_test] variant %d: rind %d / stem %d, actual MultiMesh with tint alpha1" % [i,rind,stem])
	for i in 4:
		await process_frame
		await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://screenshots/pumpkin_restore")
	root.get_texture().get_image().save_png("res://screenshots/pumpkin_restore/material.png")
	print("[pumpkin_material_test] failures: ",failures)
	stage.free()
	quit(0 if failures == 0 else 1)
