extends Node3D
## The run: builds the forest, spawns the eight pages, drives Slender,
## static/heartbeat feedback and the win/lose flow.

const PICKUP_RADIUS := 1.9
const INTERACT_RADIUS := 2.8

const PAGE_NOTES := [
	"1\n\nHELP ME.\n\nI cannot find the way out. The trees keep moving.",
	"2\n\nHe is tall. Taller than the trees.\n\nDo not look at his face.",
	"3\n\nIt only moves when you look away.\n\nKeep your eyes on the path.",
	"4\n\nI counted eight. There were eight.\n\nNow there are seven.",
	"5\n\nDon't run. He hears running.\n\nWalk. Breathe. Count.",
	"6\n\nThe static in your ears is his voice.\n\nWhen it gets loud, close your eyes.",
	"7\n\nIt is always behind you.\n\nAlways.",
	"8\n\nI found them all. Eight pages.\n\nWhy is he still here?",
]

@onready var map_builder: Node3D = $MapBuilder
@onready var player: CharacterBody3D = $Player
@onready var slender: Node3D = $Slender
@onready var hud: CanvasLayer = $HUD

var pages: Array[Dictionary] = []
var near_page := -1
var world_seed := 0
var touch_ui: Node = null
var autotest_no_pickup := false

var _ended := false
var _paused := false
var _start_grace := 0.0
var _autotest: Node = null
var _toast_shown := false
var _objective_stage := 0


func _ready() -> void:
	Game.begin_run()
	world_seed = randi()
	if Game.autotest:
		world_seed = 20261030
	_setup_environment()
	_setup_moon()
	map_builder.build(world_seed, Game.quality)
	_spawn_pages()
	player.global_position = Vector3(0, 0.15, 2.0)
	player.rotation.y = 0.0

	slender.setup(player, self, map_builder)
	slender.activate()
	slender.caught_player.connect(_on_caught)
	slender.slender_seen.connect(_on_slender_visibility)
	slender.apparition_started.connect(_on_slender_apparition)

	_connect_hud()
	hud.set_pages(0, Game.TOTAL_PAGES)
	hud.set_touch_ui(Game.touch_mode)
	hud.set_objective("FIND THE EIGHT PAGES")
	_update_touch_toggle_label()

	if Game.touch_mode:
		touch_ui = load("res://scripts/touch_controls.gd").new()
		touch_ui.set_player(player)
		touch_ui.hud = hud
		add_child(touch_ui)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	Sfx.resume_ambience()
	Sfx.set_loop_volume("static_loop", -60.0)
	Sfx.set_loop_volume("heartbeat_loop", -60.0)

	if Game.autotest:
		var mode := ""
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--autotest="):
				mode = a.get_slice("=", 1)
		# "flow" is driven by flowtest.gd from the title screen; it must not
		# spawn a second runner inside the world
		var flow := "--flow" in OS.get_cmdline_user_args()
		if mode != "flow" and not flow:
			var script_path := "res://scripts/selftest.gd" if mode == "selftest" else "res://scripts/autotest.gd"
			_autotest = load(script_path).new()
			_autotest.world = self
			add_child(_autotest)


func _connect_hud() -> void:
	hud.resume_pressed.connect(_resume)
	hud.pause_toggled.connect(_toggle_pause)
	hud.restart_pressed.connect(_restart)
	hud.menu_pressed.connect(_to_title)
	hud.touch_toggle_pressed.connect(_toggle_touch_mode)


# --------------------------------------------------------------------------- #
# scenery
# --------------------------------------------------------------------------- #
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.015, 0.021)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.17, 0.22, 0.33)
	env.ambient_light_energy = 0.30
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.02
	env.fog_enabled = true
	env.fog_light_color = Color(0.014, 0.018, 0.026)
	env.fog_light_energy = 0.30
	env.fog_density = 0.062 if Game.quality >= 1 else 0.072
	env.fog_sky_affect = 1.0
	env.fog_aerial_perspective = 0.4
	env.glow_enabled = Game.quality >= 2
	env.glow_intensity = 0.32
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	if player != null and player.camera != null:
		player.camera.far = 70.0 if Game.quality >= 1 else 55.0


func _setup_moon() -> void:
	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.52, 0.62, 0.92)
	moon.light_energy = 0.16
	moon.rotation = Vector3(deg_to_rad(-58), deg_to_rad(28), 0)
	moon.shadow_enabled = Game.quality >= 2
	moon.directional_shadow_max_distance = 60.0
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	add_child(moon)


func _spawn_pages() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://assets/textures/paper.png")
	mat.emission_enabled = true
	mat.emission_texture = load("res://assets/textures/paper.png")
	mat.emission_energy_multiplier = 0.75
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	var spots: Array = map_builder.page_spots
	var note_order := range(spots.size())
	var nrng := Game.rng()
	for i in range(note_order.size() - 1, 0, -1):
		var j := nrng.randi_range(0, i)
		var tmp: int = note_order[i]
		note_order[i] = note_order[j]
		note_order[j] = tmp
	# keep landmark order, notes are handed out in that same order
	for i in spots.size():
		var spot: Dictionary = spots[i]
		var root := Node3D.new()
		root.name = "Page_%d" % i
		var quad := QuadMesh.new()
		quad.size = Vector2(0.44, 0.58)
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
		if Game.quality >= 1:
			var light := OmniLight3D.new()
			light.light_color = Color(1.0, 0.94, 0.78)
			light.light_energy = 1.1
			light.omni_range = 4.2
			light.omni_attenuation = 1.6
			light.shadow_enabled = false
			root.add_child(light)
		var pos: Vector3 = spot["pos"]
		root.position = Vector3(pos.x, 0.62, pos.z)
		root.rotation = Vector3(-0.3, randf() * TAU, 0.0)
		add_child(root)
		var note_index: int = note_order[i] if i < note_order.size() else 0
		pages.append({
			"node": root,
			"note": PAGE_NOTES[note_index % PAGE_NOTES.size()],
			"landmark": spot["name"],
			"taken": false,
			"phase": randf() * TAU,
		})


# --------------------------------------------------------------------------- #
# frame update
# --------------------------------------------------------------------------- #
func _process(delta: float) -> void:
	if _ended:
		return
	_start_grace += delta
	_update_pages(delta)
	_update_feedback(delta)
	_update_hud()

	if _start_grace > 3.0 and not _toast_shown:
		_toast_shown = true
		hud.show_toast("FIND THE EIGHT PAGES  —  DO NOT STARE AT HIM", 5.0)


func _update_pages(delta: float) -> void:
	near_page = -1
	var best := 999.0
	for i in pages.size():
		var p: Dictionary = pages[i]
		if p["taken"]:
			continue
		var node: Node3D = p["node"]
		var phase: float = p["phase"]
		node.position.y = 0.62 + sin(_start_grace * 1.6 + phase) * 0.06
		node.rotation.y += delta * 0.5
		var d := player.global_position.distance_to(node.global_position)
		if d < PICKUP_RADIUS and not autotest_no_pickup:
			_collect(i)
			return
		if d < INTERACT_RADIUS and d < best:
			best = d
			near_page = i
	var prompt := ""
	if near_page >= 0:
		prompt = "TAP  TAKE" if Game.touch_mode else "E  —  TAKE PAGE"
	hud.show_prompt(prompt)
	if touch_ui != null:
		touch_ui.set_pickup_available(near_page >= 0)


func _update_feedback(delta: float) -> void:
	var diff := Game.difficulty()
	var intensity := 0.03 + 0.42 * diff
	var dist := 9999.0
	var seen := false
	if slender.visible:
		dist = player.global_position.distance_to(slender.global_position)
		seen = slender.visible_now
		var proximity := clampf(1.0 - dist / 32.0, 0.0, 1.0)
		intensity += proximity * 0.5
		if seen:
			intensity += 0.32 + clampf(slender.seen_time, 0.0, 3.0) * 0.1
	if slender.mode == slender.Mode.CHASE:
		intensity += 0.28
	hud.set_static(clampf(intensity, 0.0, 0.85))

	# audio: heartbeat + static + drone get louder as he closes in
	var heartbeat := -60.0
	if slender.visible and dist < 34.0:
		heartbeat = lerpf(-40.0, -6.0, clampf(1.0 - dist / 34.0, 0.0, 1.0))
	if slender.mode == slender.Mode.CHASE:
		heartbeat = -4.0
	Sfx.set_loop_volume("heartbeat_loop", heartbeat)
	Sfx.set_loop_volume("static_loop", -60.0 + 52.0 * clampf(intensity, 0.0, 1.0))
	Sfx.set_loop_volume("drone_loop", -18.0 + 9.0 * diff)

	# flashlight dies out when he is close and you can see him
	if slender.visible and seen and dist < 26.0:
		player.flicker = lerpf(player.flicker, clampf(1.0 - dist / 26.0, 0.0, 0.95), delta * 4.0)
	else:
		player.flicker = maxf(0.0, player.flicker - delta * 1.5)


func _update_hud() -> void:
	hud.set_stamina(player.stamina)
	var stage := 0
	if Game.pages_collected >= 2:
		stage = 1
	if Game.pages_collected >= 5:
		stage = 2
	if Game.pages_collected >= 7:
		stage = 3
	if stage != _objective_stage:
		_objective_stage = stage
		match stage:
			1: hud.show_toast("HE KNOWS YOU ARE HERE", 3.0)
			2: hud.show_toast("THE STATIC IS HIS VOICE", 3.0)
			3: hud.show_toast("ONE PAGE LEFT", 3.0)


# --------------------------------------------------------------------------- #
# pages
# --------------------------------------------------------------------------- #
func try_pickup(_p: Node) -> void:
	if _paused or _ended:
		return
	if near_page >= 0:
		_collect(near_page)


func pickup_page(index: int) -> void:
	if index >= 0 and index < pages.size() and not pages[index]["taken"]:
		_collect(index)


func _collect(i: int) -> void:
	var p: Dictionary = pages[i]
	if p["taken"] or _ended or _paused:
		return
	p["taken"] = true
	var node: Node3D = p["node"]
	node.queue_free()
	near_page = -1
	if touch_ui != null:
		touch_ui.set_pickup_available(false)
	hud.show_prompt("")

	Game.register_page(p["note"])
	hud.set_pages(Game.pages_collected, Game.TOTAL_PAGES)
	hud.show_note(p["note"])
	hud.flash(0.35, 0.5)
	hud.static_burst(0.55)
	Sfx.play("page", -2.0, randf_range(0.95, 1.05))
	# picking a page always wakes him up a little
	slender.cooldown = maxf(2.5, slender.cooldown - 2.0)

	if Game.pages_collected >= Game.TOTAL_PAGES:
		_win()


# --------------------------------------------------------------------------- #
# slender events
# --------------------------------------------------------------------------- #
func _on_slender_apparition() -> void:
	hud.static_burst(0.5)
	player.shake_amount = 0.008


func _on_slender_visibility(is_visible: bool) -> void:
	if is_visible and slender.mode == slender.Mode.APPARITION:
		hud.static_burst(0.25)
		Sfx.play("appear", -18.0, 0.8)


func on_apparition() -> void:
	_on_slender_apparition()


func on_chase_start() -> void:
	_on_chase_start()


func _on_chase_start() -> void:
	hud.static_burst(0.7)
	player.shake_amount = 0.02
	hud.show_toast("RUN", 1.4)


func noise_emitted(_pos: Vector3, radius: float) -> void:
	slender.on_noise(_pos, radius)


# --------------------------------------------------------------------------- #
# endings
# --------------------------------------------------------------------------- #
func _on_caught() -> void:
	if _ended:
		return
	_ended = true
	Game.freeze_clock()
	player.freeze()
	player.touch_move = Vector2.ZERO

	# pull him right in front of the lens
	var cam: Camera3D = player.camera
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.05:
		fwd = -Vector3(cam.global_transform.basis.z.x, 0.0, cam.global_transform.basis.z.z).normalized()
		if fwd.length() < 0.05:
			pass
	fwd = fwd.normalized()
	slender.global_position = cam.global_position + fwd * 1.15 - Vector3(0, 2.2, 0)
	slender.global_position.y = 0.0
	slender.scale = Vector3(1.15, 1.15, 1.15)
	var dir := cam.global_position - slender.global_position
	dir.y = 0.0
	slender.rotation.y = atan2(dir.x, dir.z)
	slender.visible = true
	slender.set_process(false)

	player.look_at_point(slender.head_position())
	player.shake_amount = 0.06
	hud.set_static(0.30)
	hud.static_burst(0.55)
	hud.flash(0.5, 0.14)
	player.flicker = 1.0
	Sfx.play("jumpscare", 0.0)
	Sfx.set_loop_volume("heartbeat_loop", -2.0)
	Sfx.set_loop_volume("static_loop", -8.0)

	await get_tree().create_timer(1.7).timeout
	if Game.touch_mode:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.fade_to_black(0.7)
	await get_tree().create_timer(0.8).timeout
	Game.finish_run(false)
	hud.show_end(false, Game.pages_collected, Game.run_time)


func _win() -> void:
	if _ended:
		return
	_ended = true
	Game.freeze_clock()
	player.freeze()
	slender.deactivate()
	hud.show_toast("EIGHT PAGES", 2.0)
	Sfx.play("win", -6.0)
	Sfx.set_loop_volume("heartbeat_loop", -60.0)
	Sfx.set_loop_volume("static_loop", -6.0)
	hud.set_static(0.8)

	await get_tree().create_timer(2.2).timeout
	hud.fade_to_black(1.6)
	await get_tree().create_timer(1.8).timeout
	Game.finish_run(true)
	hud.show_end(true, Game.pages_collected, Game.run_time)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# --------------------------------------------------------------------------- #
# menus / flow
# --------------------------------------------------------------------------- #
func _toggle_pause() -> void:
	if _ended:
		return
	_paused = not _paused
	get_tree().paused = _paused
	player.touch_move = Vector2.ZERO
	player.touch_sprint = false
	if touch_ui != null:
		touch_ui.clear_input()
	if _paused:
		hud.show_pause()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		hud.hide_pause()
		if not Game.touch_mode:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _resume() -> void:
	if _paused:
		_toggle_pause()


func _restart() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


func _to_title() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Sfx.stop_all_loops()
	get_tree().change_scene_to_file("res://scenes/Title.tscn")


func _toggle_touch_mode() -> void:
	Game.touch_mode = not Game.touch_mode
	Settings.force_touch = Game.touch_mode
	Settings.save_settings()
	_restart()


func _update_touch_toggle_label() -> void:
	hud.update_touch_toggle_label(Game.touch_mode)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if Game.run_active and not _paused and not _ended and not Game.autotest:
			_toggle_pause()


func unfreeze_player_after_pickups() -> void:
	player.frozen = false


func enable_touch_preview() -> void:
	Game.touch_mode = true
	if touch_ui == null:
		touch_ui = load("res://scripts/touch_controls.gd").new()
		touch_ui.set_player(player)
		touch_ui.hud = hud
		add_child(touch_ui)
	hud.set_touch_ui(true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func page_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for p in pages:
		if not p["taken"]:
			out.append((p["node"] as Node3D).global_position)
	return out
