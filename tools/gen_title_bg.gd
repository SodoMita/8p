extends SceneTree
## Renders the title-screen backdrop from the real bare-tree meshes, so the
## menu matches the in-game look (no painted triangles).
## usage: godot --path . --display-driver wayland --rendering-driver opengl3 \
##          --resolution 1280x720 --script tools/gen_title_bg.gd

const TREE_FILES := ["tree_0", "tree_1", "tree_2", "tree_3", "tree_4", "tree_5",
	"snag_0", "snag_1"]

var _root: Node3D
var _cam: Camera3D
var _frames := 0
var _saved := false


func _initialize() -> void:
	_root = Node3D.new()
	root.add_child(_root)
	# ---------------------------------------------------------------- sky
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.016, 0.024)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.17, 0.22, 0.33)
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.15
	env.fog_enabled = true
	env.fog_light_color = Color(0.030, 0.038, 0.050)
	env.fog_light_energy = 0.7
	env.fog_density = 0.045
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.15
	var we := WorldEnvironment.new()
	we.environment = env
	_root.add_child(we)

	var moon := DirectionalLight3D.new()
	moon.rotation_degrees = Vector3(-38, 148, 0)
	moon.light_color = Color(0.66, 0.75, 1.0)
	moon.light_energy = 0.35
	moon.shadow_enabled = true
	_root.add_child(moon)

	# ------------------------------------------------------------- ground
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(90, 90)
	plane.subdivide_width = 40
	plane.subdivide_depth = 40
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_texture = load("res://assets/textures/ground_albedo.png")
	gm.normal_enabled = true
	gm.normal_texture = load("res://assets/textures/ground_normal.png")
	gm.roughness_texture = load("res://assets/textures/ground_rough.png")
	gm.uv1_scale = Vector3(30, 30, 1)
	gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	ground.material_override = gm
	_root.add_child(ground)

	# --------------------------------------------------------------- trees
	var rng := RandomNumberGenerator.new()
	rng.seed = 7319
	var bark := StandardMaterial3D.new()
	bark.albedo_texture = load("res://assets/textures/bark_albedo.png")
	bark.normal_enabled = true
	bark.normal_texture = load("res://assets/textures/bark_normal.png")
	bark.roughness_texture = load("res://assets/textures/bark_rough.png")
	bark.roughness = 1.0
	bark.metallic = 0.0
	bark.cull_mode = BaseMaterial3D.CULL_DISABLED

	var meshes: Array[ArrayMesh] = []
	for n in TREE_FILES:
		var m: ArrayMesh = load("res://assets/models/%s.res" % n)
		if m != null:
			meshes.append(m)

	var placed := 0
	var guard := 0
	var positions: Array[Vector3] = []
	while placed < 110 and guard < 4000:
		guard += 1
		var p := Vector3(rng.randf_range(-34, 34), 0.0, rng.randf_range(-46, 8))
		# keep a clear window around the camera / title area
		if absf(p.x) < 7.0 and p.z > -16.0:
			continue
		var close := false
		for q in positions:
			if Vector2(p.x - q.x, p.z - q.z).length() < 2.6:
				close = true
				break
		if close:
			continue
		positions.append(p)
		var mi := MeshInstance3D.new()
		mi.mesh = meshes[rng.randi_range(0, meshes.size() - 1)]
		mi.material_override = bark
		var s := rng.randf_range(0.85, 1.35)
		mi.scale = Vector3(s, rng.randf_range(0.9, 1.3), s)
		mi.position = p
		mi.rotation.y = rng.randf() * TAU
		_root.add_child(mi)
		placed += 1

	# a faint warm spill from off-frame gives the dirt some colour
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(7.5, 1.6, 2.0)
	lamp.light_color = Color(1.0, 0.72, 0.46)
	lamp.light_energy = 2.0
	lamp.omni_range = 17.0
	lamp.shadow_enabled = false
	_root.add_child(lamp)

	# ------------------------------------------------------------- camera
	_cam = Camera3D.new()
	_cam.fov = 62.0
	_root.add_child(_cam)
	_cam.position = Vector3(0.4, 1.7, 9.0)
	_cam.look_at_from_position(Vector3(0.4, 1.7, 9.0), Vector3(0, 2.6, -24), Vector3.UP)
	_cam.current = true


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 6 or _saved:
		return false
	_saved = true
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("res://assets/textures/title_bg.png")
	print("[title_bg] saved %dx%d" % [img.get_width(), img.get_height()])
	return true
