extends Node
## Automated play-through used by the sway test harness.
##   --autotest        : collects pages, then lets Slender catch the player
##   --autotest=win    : collects all eight pages and reaches the win screen
##   --autotest=shots  : poses the camera at landmarks and takes screenshots
##
## Screenshots are written to $EIGHT_PAGES_SHOTS (default /tmp/eight_shots).

var world: Node = null
var mode := "lose"
var shots_dir := "/tmp/eight_shots"
var _log := ""
var _shot_index := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--autotest="):
			mode = a.get_slice("=", 1)
	var env_dir := OS.get_environment("EIGHT_PAGES_SHOTS")
	if env_dir != "":
		shots_dir = env_dir
	DirAccess.make_dir_recursive_absolute(shots_dir)
	_log_line("autotest start mode=%s quality=%d touch=%s seed=%d" % [mode, Game.quality, str(Game.touch_mode), world.world_seed])
	if mode == "shots":
		_run_shots()
	elif mode == "endings":
		_run_endings()
	elif mode == "winscreen":
		_run_winscreen()
	elif mode == "flow":
		_run_flow()
	elif mode == "demo":
		_run_demo()
	elif mode == "perf":
		_run_perf()
	elif mode == "page_preview":
		_run_page_preview()
	else:
		_run_play()


func _run_flow() -> void:
	# title screen -> BEGIN -> world, verifying the scene transition works
	var title := get_tree().current_scene
	_log_line("scene at start: " + str(title.name))
	if title != null and title.has_method("_start_game"):
		await _shot("title")
		title._start_game()
		await _wait(4.0)
		var now := get_tree().current_scene
		_log_line("scene after begin: " + str(now.name if now else "<null>"))
		await _shot("flow_world")
		var ok := now != null and now.name == "World"
		_log_line("flow %s" % ("OK" if ok else "FAILED"))
		get_tree().quit(0 if ok else 1)
	else:
		_log_line("flow FAILED: no title scene")
		get_tree().quit(1)


func _run_demo() -> void:
	# short scripted walk used to render a gameplay GIF from real frames
	await _wait(1.5)
	var p: Node3D = world.player
	p.global_position = Vector3(0, 0.15, 6)
	p.rotation.y = 0.0
	p.head.rotation.x = -0.05
	var frames := 0
	# walk toward the first page
	var target: Vector3 = (world.pages[0]["node"] as Node3D).global_position
	var dir := (target - p.global_position)
	dir.y = 0
	p.rotation.y = atan2(dir.x, dir.z) + PI
	for i in 10:
		p.set_touch_move(Vector2(0, -1))
		if i > 5:
			p.set_touch_sprint(true)
		await _wait(0.7)
		await _shot("walk_%02d" % frames)
		frames += 1
	p.set_touch_move(Vector2.ZERO)
	p.set_touch_sprint(false)
	# apparition reveal — place him straight ahead in the camera's forward axis
	var sl: Node3D = world.slender
	var fwd: Vector3 = -p.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	sl.global_position = p.global_position + fwd * 11.0
	sl.visible = true
	sl.set_process(false)
	await _wait(0.2)
	p.look_at_point(sl.head_position())
	world.hud.set_static(0.35)
	for i in 5:
		await _wait(0.6)
		await _shot("reveal_%02d" % frames)
		frames += 1
	# static rises as you stare
	for i in 5:
		world.hud.set_static(0.35 + i * 0.13)
		await _wait(0.5)
		await _shot("stare_%02d" % frames)
		frames += 1
	_log_line("demo frames=%d" % frames)
	get_tree().quit(0)


func _run_winscreen() -> void:
	await _wait(1.8)
	var p: CharacterBody3D = world.player
	for i in world.pages.size():
		var page: Dictionary = world.pages[i]
		var node: Node3D = page["node"]
		var t: Vector3 = node.global_position
		var normal: Vector3 = page["normal"]
		p.global_position = Vector3(t.x + normal.x * 1.2, 0.15, t.z + normal.z * 1.2)
		p.velocity = Vector3.ZERO
		await _wait(0.4)
		var sheet: Node3D = page["cloth"]
		if sheet.is_pinned():
			world.try_pickup(p) # first E pulls the physical nail
			await _wait(0.15)
		world.try_pickup(p) # second E takes the loose sheet
		await _wait(0.12)
	_log_line("winscreen collected=%d" % Game.pages_collected)
	await _wait(2.0)
	await _shot("win_static")
	await _wait(3.0)
	await _shot("win_screen")
	_log_line("win screen visible=%s" % str(world.hud.end_root.visible))
	get_tree().quit(0)


## Frame-time budget for the camcorder pass and the camera rig.
## Reports average frame time with each feature on and off, on this machine.
func _run_perf() -> void:
	await _wait(2.0)
	await _set_camera(Vector3(0, 0, 2), Vector3(0, 1.4, -14))
	await _wait(1.0)
	var cam = world.hud.camcorder
	var handle = world.player.handle

	var on := await _measure(90)
	cam.set_enabled(false)
	var off := await _measure(90)
	cam.set_enabled(true)
	handle.set_physics_mode(false)
	var proc := await _measure(90)
	handle.set_physics_mode(true)
	var back := await _measure(90)
	_log_line("perf camcorder_on=%.2fms off=%.2fms (%.1f%%)" % [on, off, (on / off - 1.0) * 100.0])
	_log_line("perf rig_physics=%.2fms rig_procedural=%.2fms" % [back, proc])
	_log_line("perf draw_calls=%d objects=%d" % [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)])
	_log_line("perf done")
	get_tree().quit(0)


func _measure(frames: int) -> float:
	# discard a few frames so shader/pipeline warm-up is not in the average
	for i in 10:
		await RenderingServer.frame_post_draw
	var t0 := Time.get_ticks_usec()
	for i in frames:
		await RenderingServer.frame_post_draw
	var dt := float(Time.get_ticks_usec() - t0) / float(frames) / 1000.0
	return dt


func _run_endings() -> void:
	await _wait(2.0)
	# screenshots must never plant a fake "best escape" record in the save file
	Settings.best_time = -1.0
	Settings.best_pages = 0
	Settings.save_settings()
	# pause menu
	world._toggle_pause()
	await _wait(0.6)
	await _shot("pause_menu")
	world._resume()
	await _wait(0.4)
	# death screen
	var pl: Node3D = world.player
	world.slender.visible = true
	world.slender.global_position = pl.global_position + Vector3(0, 0, -2.0)
	world.slender.force_chase()
	await _wait(1.1)
	await _shot("jumpscare")
	await _wait(3.2)
	await _shot("death_screen")
	_log_line("endings shots done")
	get_tree().quit(0)


func _log_line(s: String) -> void:
	s += "  [t=%.1fs fps=%d]" % [Time.get_ticks_msec() / 1000.0, Engine.get_frames_per_second()]
	print("[autotest] " + s)
	_log += s + "\n"
	var f := FileAccess.open(shots_dir + "/autotest.log", FileAccess.WRITE)
	if f != null:
		f.store_string(_log)
		f.close()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func _shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		_log_line("(headless: skipping shot " + name + ")")
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%02d_%s.png" % [shots_dir, _shot_index, name]
	img.save_png(path)
	_shot_index += 1
	_log_line("shot " + path)


func _touch_down(id: int, pos: Vector2) -> void:
	var e := InputEventScreenTouch.new()
	e.index = id
	e.position = pos
	e.pressed = true
	Input.parse_input_event(e)


func _touch_drag(id: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = id
	e.position = pos
	e.relative = rel
	Input.parse_input_event(e)


func _touch_up(id: int, pos: Vector2) -> void:
	var e := InputEventScreenTouch.new()
	e.index = id
	e.position = pos
	e.pressed = false
	Input.parse_input_event(e)


func _set_camera(pos: Vector3, look_at: Vector3) -> void:
	var p: Node3D = world.player
	p.global_position = Vector3(pos.x, 0.12, pos.z)
	p.freeze()
	await _wait(0.15)
	var target: Vector3 = look_at - (p.head.global_position)
	var flat: Vector2 = Vector2(target.x, target.z)
	if flat.length() > 0.001:
		p.rotation.y = atan2(target.x, target.z) + PI
	var horiz: float = flat.length()
	p.head.rotation.x = atan2(target.y, horiz)
	p.pitch = p.head.rotation.x


# --------------------------------------------------------------------------- #
# pure screenshot tour
# --------------------------------------------------------------------------- #
func _run_shots() -> void:
	await _wait(1.6)
	world.hud.set_objective("FIND THE EIGHT PAGES")

	# 1) spawn clearing
	await _set_camera(Vector3(0, 0, 2), Vector3(0, 1.4, -14))
	await _wait(0.6)
	await _shot("spawn")

	# 2) each landmark viewed from a few metres outside of it
	var landmarks: Array = world.map_builder.landmarks
	var spots: Array = world.map_builder.page_spots
	for i in landmarks.size():
		var lm: Dictionary = landmarks[i]
		var center: Vector3 = lm["pos"]
		var page_pos: Vector3 = spots[i]["pos"]
		# stand on the line page -> outward, so both the prop and the page are in frame
		var outward: Vector3 = (page_pos - center)
		outward.y = 0.0
		if outward.length() < 0.5:
			outward = Vector3(center.z, 0, -center.x)
		outward = outward.normalized()
		var target: Vector3 = center + Vector3(0, 1.5, 0)
		var cam_pos: Vector3 = center + outward * (float(lm["radius"]) + 4.5)
		# the forest is grown procedurally, so pick a heading whose sight line
		# is free of trunks and whose lens is not buried in one
		var base_ang := atan2(outward.z, outward.x)
		var found := false
		for pass_i in 2:
			if found:
				break
			var cam_dist: float = float(lm["radius"]) + (4.5 if pass_i == 0 else 7.5)
			for k in 20:
				var a := base_ang + TAU * float(k) / 20.0
				var cand: Vector3 = center + Vector3(cos(a), 0, sin(a)) * cam_dist
				if world.map_builder.nearest_tree_distance(cand, 900) < 3.0:
					continue
				var blocked := false
				for t in [0.18, 0.36, 0.55, 0.74]:
					var sample: Vector3 = cand.lerp(center, t)
					if world.map_builder.nearest_tree_distance(sample, 900) < 1.15:
						blocked = true
						break
				if blocked:
					continue
				cam_pos = cand
				found = true
				break
		await _set_camera(cam_pos, target)
		await _wait(0.45)
		await _shot("page_%d_%s" % [i + 1, lm["name"]])

	# 2b) pumpkin patch + dead bushes, framed with the flashlight
	var patch: Node3D = world.map_builder.get_node_or_null("Pumpkins_0")
	if patch != null and patch.multimesh.instance_count > 0:
		var xf: Transform3D = patch.multimesh.get_instance_transform(0)
		var centre: Vector3 = xf.origin
		var view_dir := Vector3(0.7, 0, 0.7).normalized()
		var cam_p: Vector3 = centre - view_dir * 4.2
		# find a heading whose sight line is clear, same as the landmark shots
		var space2: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
		for k in 16:
			var a := TAU * float(k) / 16.0
			var cand := centre + Vector3(cos(a), 0, sin(a)) * 4.2
			if world.map_builder.nearest_tree_distance(cand, 900) < 1.4:
				continue
			var blocked := false
			for t in [0.3, 0.55, 0.8]:
				if world.map_builder.nearest_tree_distance(cand.lerp(centre, t), 900) < 0.8:
					blocked = true
					break
			if blocked:
				continue
			cam_p = cand
			break
		await _set_camera(cam_p, centre + Vector3(0, 0.35, 0))
		await _wait(0.5)
		await _shot("pumpkins")
		_log_line("pumpkins=%d bushes=%d" % [world.map_builder.pumpkin_count(), world.map_builder.bush_count()])

	# 2b2) bark close up, torch on a trunk at a steep angle of incidence
	var trees_at: Node3D = world.map_builder.get_node_or_null("Trees_0")
	if trees_at != null and trees_at.multimesh.instance_count > 0:
		var tx: Transform3D = trees_at.multimesh.get_instance_transform(0)
		var tp: Vector3 = tx.origin
		var side := Vector3(1, 0, 0.35).normalized()
		await _set_camera(tp + side * 2.6 + Vector3(0, 0.0, 0), tp + Vector3(0, 1.35, 0))
		await _wait(0.6)
		await _shot("bark_detail")

	# 2c) a page close up: the sheet is a live cloth grid with no light of its own
	if world.pages.size() > 0:
		var pnode: Node3D = world.pages[0]["node"]
		var pp: Vector3 = pnode.global_position
		# stand along the sheet's own +Z normal, or the shot is a paper edge
		var face: Vector3 = (world.pages[0]["normal"] as Vector3).normalized()
		await _set_camera(pp + face * 0.62 + Vector3(0.0, -0.28, 0.0), pp + Vector3(0.0, -0.32, 0.0))
		await _wait(1.4)
		print("[dbg] page shot cam=", world.player.camera.global_position,
			" page=", pp, " torch=", world.player.flashlight_on,
			" flash_energy=", world.player.flashlight.light_energy,
			" visible=", world.player.flashlight.visible,
			" spot_angle=", world.player.flashlight.spot_angle)
		await _shot("page_cloth")
		# same frame with the torch off: the page must be as black as the wall
		world.player.flashlight_on = false
		await _wait(0.7)
		await _shot("page_in_the_dark")
		world.player.flashlight_on = true

	# 2d) concrete close up: texel density / stretching check
	var cw: Dictionary = {}
	for lm in world.map_builder.landmarks:
		if lm["name"] == "walls" or lm["name"] == "tower":
			cw = lm
			break
	if not cw.is_empty():
		var base: Vector3 = cw["pos"]
		await _set_camera(base + Vector3(9.5, 1.7, 9.5), base + Vector3(0.0, 1.2, 0.0))
		await _wait(0.6)
		await _shot("concrete_detail")

	# 3) Slender in the treeline, lit by the flashlight
	var pl: Node3D = world.player
	await _set_camera(Vector3(0, 0, 6), Vector3(0, 1.4, -20))
	var sl: Node3D = world.slender
	sl.global_position = Vector3(0, 0, -3)
	sl.visible = true
	sl.set_process(false)
	world.hud.set_static(0.55)
	await _wait(0.8)
	await _shot("slender_apparition")

	# 4) close up stare -> static
	sl.global_position = Vector3(0, 0, 2.0)
	await _set_camera(Vector3(0, 0, 8), Vector3(0, 2.0, 2.0))
	world.hud.set_static(1.0)
	world.hud.static_burst(0.8)
	await _wait(0.35)
	await _shot("slender_close")

	# 4b) the camcorder's own night-vision lamp: torch off, IR on
	world.player.toggle_flashlight()   # torch -> IR lamp
	world.hud.set_static(0.12)
	world.hud.set_dread(0.35)
	await _set_camera(Vector3(0, 0, 8), Vector3(0, 1.6, -12))
	await _wait(1.2)
	await _shot("night_vision")
	# and the same spot with the tape tearing itself apart
	world.hud.camcorder_glitch(1.0)
	world.hud.set_dread(1.0)
	await _wait(0.25)
	await _shot("signal_loss")
	world.hud.set_dread(0.0)
	world.player.toggle_flashlight()   # back to the torch

	# 5) HUD with some pages collected, framed on the spawn clearing
	sl.visible = false
	world.hud.set_static(0.06)
	await _set_camera(Vector3(0, 0, 7), Vector3(-14, 1.4, -20))
	for i in 3:
		world.hud.set_pages(i + 1, 8)
	await _wait(6.0)  # let the intro toast fade out of frame
	await _shot("hud")

	# 6) note overlay
	world.hud.show_note("3\n\nIt only moves when you look away.\n\nKeep your eyes on the path.", 9.0)
	await _wait(1.0)
	await _shot("note")

	# 7) touch UI preview + a simulated thumb on the stick
	world.hud.note_root.modulate.a = 0.0
	world.enable_touch_preview()
	var vp := get_viewport().get_visible_rect().size
	var stick := Vector2(vp.x * 0.16, vp.y * 0.74)
	_touch_down(0, stick)
	await _wait(0.15)
	_touch_drag(0, stick + Vector2(10, -70), Vector2(0, -70))
	await _wait(0.1)
	var move_vec: Vector2 = world.player.touch_move
	_touch_down(1, Vector2(vp.x * 0.8, vp.y * 0.5))
	_touch_drag(1, Vector2(vp.x * 0.8 + 120, vp.y * 0.5), Vector2(120, 0))
	await _wait(0.4)
	var yaw: float = world.player.rotation.y
	await _shot("touch_ui")
	_touch_up(0, stick)
	_touch_up(1, Vector2(vp.x * 0.8, vp.y * 0.5))
	_log_line("touch stick vector=%s yaw=%.3f" % [str(move_vec), yaw])

	# 5) the gate, the road leaving through it, and the fence running away
	world.hud.note_root.modulate.a = 0.0
	world.hud.show_prompt("")
	var gate: Vector3 = world.map_builder.gate_centre
	await _set_camera(gate + Vector3(-2.2, 0.05, 2.6), gate + Vector3(26.0, -1.2, -1.0))
	await _wait(0.8)
	await _shot("gate_road")
	await _set_camera(gate + Vector3(14.0, 0.05, 1.2), gate + Vector3(-24.0, -1.4, -0.6))
	await _wait(0.8)
	await _shot("gate_from_outside")
	await _set_camera(gate + Vector3(-9.0, 0.05, -3.0), gate + Vector3(30.0, -1.4, 14.0))
	await _wait(0.8)
	# the corner of the fence, where two runs have to meet
	var corner := Vector3(world.map_builder.FENCE_SIDE, 0, world.map_builder.FENCE_SIDE)
	await _set_camera(corner + Vector3(-7.0, 2.2, -7.0), corner + Vector3(0, 1.2, 0))
	await _wait(0.6)
	await _shot("fence_corner")
	await _set_camera(corner + Vector3(-2.5, 2.0, -16.0), corner + Vector3(0, 1.0, 0))
	await _wait(0.6)
	await _shot("fence_corner_low")

	await _shot("fence_line")
	_log_line("autotest shots done")
	get_tree().quit(0)


# --------------------------------------------------------------------------- #
# physical page pin/unpin preview: one close shot of the real nail, then one of
# the same cloth moving freely after the nail is pulled.
# --------------------------------------------------------------------------- #
func _run_page_preview() -> void:
	await _wait(1.5)
	var page: Dictionary = world.pages[0]
	var sheet: Node3D = page["cloth"]
	var target: Vector3 = sheet.world_center()
	var normal: Vector3 = page["normal"]
	var cam_pos: Vector3 = page["anchor_pos"] + normal * 0.72 + Vector3(0, -0.18, 0)
	await _set_camera(cam_pos, target)
	await _wait(0.5)
	await _shot("page_pin")
	_log_line("page pinned=%s anchor=%s" % [str(sheet.is_pinned()), str(page["anchor_pos"])])
	world.try_pickup(world.player)
	await _wait(0.8)
	await _shot("page_unpinned")
	_log_line("page unpinned=%s center=%s" % [str(not sheet.is_pinned()), str(sheet.world_center())])
	get_tree().quit(0)


# --------------------------------------------------------------------------- #
# scripted full play-through
# --------------------------------------------------------------------------- #
func _run_play() -> void:
	await _wait(1.8)
	var p: CharacterBody3D = world.player
	var total: int = world.pages.size()
	var target_count: int = total if mode == "win" else 3
	_log_line("pages=%d collect_target=%d" % [total, target_count])
	for i in target_count:
		var page: Dictionary = world.pages[i]
		var node: Node3D = page["node"]
		var target: Vector3 = node.global_position
		var normal: Vector3 = page["normal"]
		p.global_position = Vector3(target.x + normal.x * 1.2, 0.12, target.z + normal.z * 1.2)
		await _wait(0.45)
		_log_line("walked to page %d at %s" % [i + 1, str(target)])
		var sheet: Node3D = page["cloth"]
		if sheet.is_pinned():
			world.try_pickup(p) # pull the physical nail
			await _wait(0.20)
		world.try_pickup(p) # take the now-loose paper
		await _wait(0.10)
		if Game.pages_collected != i + 1:
			_log_line("ERROR: page %d not collected (have %d)" % [i + 1, Game.pages_collected])
		if i == 2:
			await _shot("mid_run")

	_log_line("collected=%d/%d" % [Game.pages_collected, total])
	if mode == "win":
		await _wait(5.0)
		_log_line("win screen visible=%s" % str(world.hud.end_root.visible))
		await _shot("win")
		get_tree().quit(0 if Game.pages_collected == total else 1)
		return

	# --- death path -------------------------------------------------------
	world.unfreeze_player_after_pickups()
	# The three-page run may end beside a landmark wall. Put the deterministic
	# chase check in the clear spawn area so the Slender path is not trapped by
	# whichever procedural prop happened to be behind page three.
	p.global_position = Vector3(0, 0.15, 2.0)
	p.velocity = Vector3.ZERO
	p.rotation.y = 0.0
	await _wait(0.2)
	var sl: Node3D = world.slender
	sl.visible = true
	sl.global_position = p.global_position + Vector3(0, 0, -1.6)
	sl.force_chase()
	p.look_at_point(sl.head_position())
	await _wait(0.8)
	await _shot("chase")
	await _wait(4.0)
	_log_line("dead=%s end_visible=%s" % [str(sl.dead), str(world.hud.end_root.visible)])
	await _shot("death")
	await _wait(1.0)
	var ok: bool = world.hud.end_root.visible
	_log_line("autotest lose path %s" % ("OK" if ok else "FAILED"))
	get_tree().quit(0 if ok else 1)
