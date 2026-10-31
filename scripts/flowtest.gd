extends Node
## End-to-end scene flow test: Title -> BEGIN -> World -> pause -> restart.
##   godot --path . res://scenes/Title.tscn -- --autotest=flow

var _dir := "/tmp/eight_shots"
var _i := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var env_dir := OS.get_environment("EIGHT_PAGES_SHOTS")
	if env_dir != "":
		_dir = env_dir
	DirAccess.make_dir_recursive_absolute(_dir)
	_run()


func _wait(t: float) -> void:
	await get_tree().create_timer(t, true, false, true).timeout


func _shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%02d_%s.png" % [_dir, _i, name])
	_i += 1


func _run() -> void:
	var title := get_tree().current_scene
	print("[flow] start scene: ", title.name)
	await _wait(3.0)
	await _shot("title")
	title._start_game()
	await _wait(5.0)
	var world := get_tree().current_scene
	var ok := world != null and world.name == "World"
	print("[flow] after BEGIN: ", world.name if world else "<null>", " ok=", ok)
	await _shot("world_after_begin")
	if not ok:
		print("[flow] FAILED")
		get_tree().quit(1)
		return

	# pause + resume through the real input action
	world._toggle_pause()
	await _wait(0.8)
	var paused_ok: bool = get_tree().paused and world.hud.pause_root.visible
	await _shot("pause")
	world._resume()
	await _wait(0.8)
	var resumed_ok: bool = not get_tree().paused
	print("[flow] pause=", paused_ok, " resume=", resumed_ok)

	var p: Node3D = world.player

	# a page must NOT be collectable while the pause menu is open
	var paused_pickup_ok := false
	if world.pages.size() > 0:
		var t0: Vector3 = (world.pages[0]["node"] as Node3D).global_position
		# stand inside interact range but outside the auto-pickup radius
		p.global_position = Vector3(t0.x, 0.15, t0.z + 2.35)
		await _wait(0.5)
		print("[flow] near_page=", world.near_page, " collected=", Game.pages_collected)
		world._toggle_pause()
		await _wait(0.4)
		world.try_pickup(p)
		paused_pickup_ok = Game.pages_collected == 0 and world.near_page >= 0
		world._resume()
		await _wait(0.3)
	print("[flow] pickup blocked while paused=", paused_pickup_ok)

	# walk a few metres with the touch API, then check pages counter updates
	p.global_position = Vector3(0, 0.2, 0)
	p.rotation.y = 0.0
	await _wait(0.3)
	var start: Vector3 = p.global_position
	p.set_touch_move(Vector2(0, -1))
	var deadline := Time.get_ticks_msec() + 9000
	while (p.global_position - start).length() < 2.5 and Time.get_ticks_msec() < deadline:
		await _wait(0.3)
	p.set_touch_move(Vector2.ZERO)
	var moved: float = (p.global_position - start).length()
	print("[flow] moved %.2f m" % moved)

	var page_ok := false
	if world.pages.size() > 0:
		var t: Vector3 = (world.pages[0]["node"] as Node3D).global_position
		p.global_position = Vector3(t.x, 0.15, t.z + 1.0)
		await _wait(0.6)
		page_ok = Game.pages_collected == 1
		await _shot("first_page")
	print("[flow] first page collected=", page_ok)

	var passed := paused_ok and resumed_ok and paused_pickup_ok and moved > 2.0 and page_ok
	print("[flow] RESULT ", "PASS" if passed else "FAIL")
	get_tree().quit(0 if passed else 1)
