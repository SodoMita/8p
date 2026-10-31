extends SceneTree
## Neutral-light inspection renders of the procedural models.
## xvfb-run -a godot --path . --script tools/model_preview.gd

func _initialize() -> void:
	call_deferred("_render_models")

func _render_models() -> void:
	root.size = Vector2i(1280, 800)
	var stage := Node3D.new()
	root.add_child(stage)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.055, 0.065, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.68, 0.75, 0.9)
	env.ambient_light_energy = 0.85
	env_node.environment = env
	stage.add_child(env_node)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48, -30, 0)
	light.light_color = Color(1.0, 0.87, 0.73)
	light.light_energy = 2.0
	stage.add_child(light)
	var camera := Camera3D.new()
	camera.fov = 48
	stage.add_child(camera)
	camera.current = true
	var map = load("res://scripts/map_builder.gd").new()
	stage.add_child(map)
	map.rng.seed = 2026
	map._make_materials()
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	floor_mesh.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.16, 0.17, 0.18)
	floor_mat.roughness = 1.0
	floor_mesh.material_override = floor_mat
	stage.add_child(floor_mesh)
	map._truck(Transform3D.IDENTITY)
	map._rock_circle(Transform3D(Basis(), Vector3(20, 0, 0)))
	map._silo(Transform3D(Basis(), Vector3(-20, 0, 0)))
	var creature = load("res://scripts/slender.gd").new()
	stage.add_child(creature)
	creature.position = Vector3(40, 0, 0)
	creature.visible = true
	var tree := MeshInstance3D.new()
	tree.mesh = load("res://assets/models/tree_0.res")
	tree.material_override = map._mats["bark"]
	tree.position = Vector3(60, 0, 0)
	stage.add_child(tree)
	var shots := [
		["truck", Vector3(7, 4.5, 9), Vector3(0, 1.25, 0)],
		["stones", Vector3(28, 5, 10), Vector3(20, 1, 0)],
		["silo", Vector3(-10, 7, 13), Vector3(-20, 3.6, 0)],
		["creature", Vector3(42.4, 2.6, 6.4), Vector3(40, 1.9, 0)],
		["tree", Vector3(68, 7, 14), Vector3(60, 6, 0)]
	]
	DirAccess.make_dir_recursive_absolute("res://screenshots/models")
	for shot in shots:
		for child in map.get_children():
			if child is Node3D:
				child.visible = absf(child.position.x - shot[2].x) < 12.0
		creature.visible = shot[0] == "creature"
		tree.visible = shot[0] == "tree"
		camera.position = shot[1]
		camera.look_at(shot[2])
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://screenshots/models/%s.png" % shot[0])
		print("[model_preview] rendered ", shot[0])
	quit()
