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
var terrain: Node3D = null
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
	_setup_terrain()
	_spawn_pages()
	player.global_position = Vector3(0, 0.15, 2.0)
	player.rotation.y = 0.0
	# the camera rig was built during scene load, before the player was placed:
	# re-seat it so the tether's frame matches where we actually stand
	if player.handle != null:
		player.handle.snap()

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
		# the cursor stays free for the on-screen stick, but the mouse still
		# looks around while a button is held (see player._unhandled_input)
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
			var script_path := "res://scripts/autotest.gd"
			if mode == "selftest":
				script_path = "res://scripts/selftest.gd"
			elif mode == "camtest":
				script_path = "res://scripts/camera_test.gd"
			elif mode == "mouselive":
				script_path = "res://scripts/mouse_live.gd"
			elif mode == "controls":
				script_path = "res://scripts/controls_test.gd"
			_autotest = load(script_path).new()
			_autotest.world = self
			add_child(_autotest)


func _connect_hud() -> void:
	hud.resume_pressed.connect(_resume)
	hud.pause_toggled.connect(_toggle_pause)
	hud.restart_pressed.connect(_restart)
	hud.menu_pressed.connect(_to_title)
	hud.touch_toggle_pressed.connect(_toggle_touch_mode)
	hud.camcorder_toggled.connect(_toggle_camcorder_fx)
	hud.handheld_toggled.connect(_toggle_handheld_camera)


# --------------------------------------------------------------------------- #
# scenery
# --------------------------------------------------------------------------- #
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.015, 0.021)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.17, 0.22, 0.33)
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.02
	env.fog_enabled = true
	env.fog_light_color = Color(0.014, 0.018, 0.026)
	env.fog_light_energy = 0.38
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


func _setup_terrain() -> void:
	terrain = load("res://scripts/endless_terrain.gd").new()
	terrain.name = "Terrain"
	add_child(terrain)
	terrain.setup(map_builder, player, Game.quality)


func _setup_moon() -> void:
	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.52, 0.62, 0.92)
	moon.light_energy = 0.24
	moon.rotation = Vector3(deg_to_rad(-58), deg_to_rad(28), 0)
	moon.shadow_enabled = Game.quality >= 2
	moon.directional_shadow_max_distance = 60.0
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	add_child(moon)


func _spawn_pages() -> void:
	var spots: Array = map_builder.page_spots
	var note_order := range(spots.size())
	var nrng := Game.rng()
	for i in range(note_order.size() - 1, 0, -1):
		var j := nrng.randi_range(0, i)
		var tmp: int = note_order[i]
		note_order[i] = note_order[j]
		note_order[j] = tmp
	var cloth_script: Script = load("res://scripts/page_cloth.gd")
	for i in spots.size():
		var spot: Dictionary = spots[i]
		var note_index: int = note_order[i] if i < note_order.size() else 0
		var note: String = PAGE_NOTES[note_index % PAGE_NOTES.size()]
		var root := Node3D.new()
		root.name = "Page_%d" % i
		# Pin it to the surface the landmark reported: the spot is a point on
		# that surface and `normal` points out of it. The sheet hangs off the
		# nail from its top edge, so the node sits at nail height.
		var pos: Vector3 = spot["pos"]
		var n: Vector3 = spot.get("normal", Vector3(0, 0, 1))
		n = n.normalized()
		var basis := Basis(Vector3.UP, atan2(n.x, n.z))
		root.transform = Transform3D(basis, pos + n * 0.035)
		var sheet: Node3D = cloth_script.new()
		sheet.name = "Sheet"
		sheet.set("hang_phase", randf() * TAU)
		sheet.set("note_index", (note_index % PAGE_NOTES.size()) + 1)
		root.add_child(sheet)
		add_child(root)
		pages.append({
			"node": root,
			"cloth": sheet,
			"note": note,
			"normal": n,
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
		var d := player.global_position.distance_to(node.global_position + Vector3(0, -0.29, 0))
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
	intensity = clampf(intensity, 0.0, 0.85)
	hud.set_static(intensity)

	# the camcorder reacts to the same danger: tape damage, tearing, signal
	# loss, a zoom creep and the IR lamp when the torch is off
	var dread := clampf((intensity - 0.06) / 0.72, 0.0, 1.0)
	if slender.mode == slender.Mode.CHASE:
		dread = maxf(dread, 0.85)
	hud.set_dread(dread)
	hud.set_camcorder_ir(not player.flashlight_on)

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
	hud.camcorder_glitch(0.75)
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
	hud.camcorder_glitch(0.55)
	player.shake_amount = 0.008


func _on_slender_visibility(is_visible: bool) -> void:
	if is_visible and slender.mode == slender.Mode.APPARITION:
		hud.static_burst(0.25)
		hud.camcorder_glitch(0.3)
		Sfx.play("appear_near", -20.0, randf_range(0.96, 1.04))


func on_apparition() -> void:
	_on_slender_apparition()


func on_chase_start() -> void:
	_on_chase_start()


func _on_chase_start() -> void:
	hud.static_burst(0.7)
	hud.camcorder_glitch(0.95)
	hud.camcorder_punch(0.35)
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
	hud.camcorder_glitch(1.0)
	hud.camcorder_punch(0.8)
	hud.set_dread(1.0)
	hud.flash(0.5, 0.14)
	player.flicker = 1.0
	# open the mix right before he hits: the forest falls away, only him left
	Sfx.fade_loop("wind_loop", -34.0, 0.20)
	Sfx.fade_loop("drone_loop", -34.0, 0.20)
	Sfx.play("jumpscare", -4.0)
	Sfx.set_loop_volume("heartbeat_loop", -6.0)
	Sfx.set_loop_volume("static_loop", -12.0)

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
	Sfx.play("win", -9.0)
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


func _toggle_camcorder_fx() -> void:
	Settings.camcorder = not Settings.camcorder
	Settings.save_settings()
	hud.refresh_camcorder()
	_update_touch_toggle_label()


func _toggle_handheld_camera() -> void:
	Settings.camcorder_physics = not Settings.camcorder_physics
	Settings.save_settings()
	if player != null and player.handle != null:
		player.handle.set_physics_mode(Settings.camcorder_physics and Game.quality >= 1)
	_update_touch_toggle_label()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if Game.run_active and not _paused and not _ended and not Game.autotest:
			_toggle_pause()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		# clicking back into the window must give the mouse back to the game,
		# otherwise the camera feels dead until pause/resume
		if Game.run_active and not _paused and not _ended and not Game.touch_mode:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


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
