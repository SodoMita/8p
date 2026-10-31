extends Node
## Controls harness: every input path, measured.
##   godot --path . res://scenes/World.tscn -- --autotest=controls
##
## The point of this file is that "controls feel wrong" is not a bug report we
## can act on. Each check injects a real InputEvent through Input.parse_input_event
## (exactly what an OS or a thumb delivers), then measures what the player did:
## yaw in radians, metres walked, which way pitch went, whether the torch flipped.
## That catches the classic porting bugs — events handled twice, a path that is
## silently dead because some other mode early-returns, sensitivity applied twice.

var world: Node = null
var passed := 0
var failed := 0
var player: CharacterBody3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await get_tree().process_frame
	await _wait(1.2)
	player = world.player
	await _run()
	print("[controls] RESULT %d passed, %d failed" % [passed, failed])
	get_tree().quit(0 if failed == 0 else 1)


## Headless Godot ignores Input.mouse_mode entirely (it stays VISIBLE), so a
## pointer-capture assertion is only meaningful on a real display. Skipping is
## printed, never silently counted as a pass: the same harness is run under sway
## (tools/run_sway.sh ... --autotest=controls) where those checks do run.
func skip(name: String, reason: String) -> void:
	print("[controls] SKIP  %s (%s)" % [name, reason])


func check(name: String, condition: bool, detail := "") -> void:
	if condition:
		passed += 1
		print("[controls] PASS  %s %s" % [name, detail])
	else:
		failed += 1
		print("[controls] FAIL  %s %s" % [name, detail])


func _wait(t: float) -> void:
	await get_tree().create_timer(t, true, false, true).timeout


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _yaw() -> float:
	return player.rotation.y


func _reset_view() -> void:
	player.rotation.y = 0.0
	player.pitch = 0.0
	player.head.rotation.x = 0.0


## A real mouse move, as the OS delivers it.
func _mouse_move(rel: Vector2, held := false) -> void:
	var e := InputEventMouseMotion.new()
	e.relative = rel
	e.velocity = rel * 60.0
	if held:
		e.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(e)


## Yaw of the camera the player is actually looking through, i.e. the direction
## the picture points. The rig lags behind the yaw on purpose, so this is
## measured after letting it settle.
func _cam_yaw() -> float:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		cam = player.camera
	if cam == null:
		return 0.0
	var f := -cam.global_transform.basis.z
	return wrapf(atan2(-f.x, -f.z), -PI, PI)


## Hold an action for a fixed number of physics ticks and report how far the
## player travelled. Physics ticks are 1/60 s of simulated time whatever the
## renderer is doing, so this measures the same thing at 145 fps and at 2 fps.
func _hold(action: String, ticks: int) -> float:
	var start := player.global_position
	Input.action_press(action)
	for i in ticks:
		await get_tree().physics_frame
	Input.action_release(action)
	await get_tree().physics_frame
	return (player.global_position - start).length()


## A real finger: touch down, drag, up (the drag is what carries `relative`).
func _touch_drag(pos: Vector2, rel: Vector2) -> void:
	var down := InputEventScreenTouch.new()
	down.index = 1
	down.position = pos
	down.pressed = true
	Input.parse_input_event(down)
	var drag := InputEventScreenDrag.new()
	drag.index = 1
	drag.position = pos + rel
	drag.relative = rel
	Input.parse_input_event(drag)
	var up := InputEventScreenTouch.new()
	up.index = 1
	up.position = pos + rel
	up.pressed = false
	Input.parse_input_event(up)


func _run() -> void:
	# Input events arrive in screen pixels and Godot maps them through the
	# viewport's stretch transform. In headless the window is 64x64 while the
	# design resolution is 1280x720, so that transform is 0.05 and one injected
	# pixel counts as twenty. Normalise, so the numbers below are about the
	# input logic and nothing else.
	# Headless starts with a 64x64 window, which makes the viewport stretch
	# transform scale injected motion 20x. Size the window to the design
	# resolution first so one injected pixel is one pixel.
	var win := get_window()
	win.size = Vector2i(1280, 720)
	await _frames(4)
	var iscale: float = 1.0 / maxf(get_viewport().get_final_transform().x.x, 0.0001)
	print("[controls] input scale %.2f (window %s, design %s)" % [
		iscale, str(win.size), str(win.content_scale_size)])
	var mouse_sens := 0.0021 * Settings.mouse_sensitivity * iscale
	var invert := Settings.invert_y

	# ------------------------------------------------------------ desktop mouse
	Game.touch_mode = false
	if world.touch_ui != null:
		world.touch_ui.visible = false
	_reset_view()
	_mouse_move(Vector2(60, 0))
	await _frames(2)
	var d_mouse: float = wrapf(_yaw(), -PI, PI)
	check("mouse_look_yaw", absf(d_mouse - (-60.0 * mouse_sens)) < 0.01,
		"%.4f rad, expected %.4f" % [d_mouse, -60.0 * mouse_sens])

	# ... and the view itself must turn: the yaw number is not what the player
	# sees, the camera is, and it hangs off the physics handle now
	_reset_view()
	await _frames(20)
	var cam_before: float = _cam_yaw()
	_mouse_move(Vector2(60, 0))
	# the rig lags on purpose: ~90 frames of 145 fps before the view has caught
	# up with the head (camtest measures the same settle curve)
	await _frames(90)
	var cam_turned: float = wrapf(_cam_yaw() - cam_before, -PI, PI)
	check("camera_actually_turns_with_mouse",
		absf(cam_turned) > absf(60.0 * mouse_sens) * 0.5 and signf(cam_turned) == -1.0,
		"view turned %.4f rad, yaw moved %.4f" % [cam_turned, -60.0 * mouse_sens])

	_reset_view()
	_mouse_move(Vector2(0, 60))
	await _frames(2)
	var d_pitch: float = player.pitch
	var want_pitch: float = (-60.0 * mouse_sens) * (-1.0 if invert else 1.0)
	check("mouse_look_pitch", absf(d_pitch - want_pitch) < 0.02,
		"%.4f rad, expected %.4f (invert=%s)" % [d_pitch, want_pitch, str(invert)])

	# sensitivity must be applied exactly once
	var prev_sens := Settings.mouse_sensitivity
	Settings.mouse_sensitivity = 2.0
	_reset_view()
	_mouse_move(Vector2(60, 0))
	await _frames(2)
	var d_sens: float = wrapf(_yaw(), -PI, PI)
	check("mouse_sensitivity_applied_once",
		absf(d_sens - (-60.0 * 0.0021 * 2.0)) < 0.01,
		"%.4f rad, expected %.4f at sens=2.0" % [d_sens, -60.0 * 0.0021 * 2.0])
	Settings.mouse_sensitivity = prev_sens

	# --------------------------------------------------------------- keyboard
	_reset_view()
	player.frozen = false
	var walked: float = await _hold("move_forward", 30)
	check("keyboard_walk", walked > 0.4, "%.2f m in 30 ticks" % walked)

	# ------------------------------------------------------------------ touch
	# The touch overlay drives look from InputEventScreenDrag. The project has
	# pointing/emulate_mouse_from_touch=true, so the same finger ALSO produces an
	# emulated InputEventMouseMotion — that is the classic double-look bug.
	Game.touch_mode = true
	if world.touch_ui == null:
		world.enable_touch_preview()
	world.touch_ui.visible = true
	_reset_view()
	await _frames(2)
	var touch_sens := 1.45 * clampf(get_viewport().get_visible_rect().size.x / 1280.0, 0.65, 1.9) * Settings.mouse_sensitivity * iscale
	_touch_drag(Vector2(900, 400), Vector2(60, 0))
	await _frames(3)
	var d_touch: float = wrapf(_yaw(), -PI, PI)
	var want_touch: float = -60.0 * touch_sens * 0.0021
	check("touch_look_single_application",
		absf(d_touch - want_touch) < absf(want_touch) * 0.25,
		"%.4f rad, expected %.4f (double-look would be %.4f)" % [d_touch, want_touch, want_touch * 2.0])

	# a finger on the left half must drive the stick, never the camera's pitch
	_reset_view()
	_touch_drag(Vector2(200, 600), Vector2(0, 0))
	await _frames(2)
	check("stick_does_not_move_view", absf(player.pitch) < 1e-6 and absf(_yaw()) < 1e-6,
		"pitch %.6f yaw %.6f" % [player.pitch, _yaw()])

	# --------------------------------------------------- keyboard while touch on
	var start2 := player.global_position
	var walked_touch: float = await _hold("move_forward", 30)
	check("keyboard_walks_in_touch_mode", walked_touch > 0.35,
		"%.2f m in 30 ticks" % walked_touch)

	# THE BUG THE HUMAN REPORTED. _detect_touch() returns true for any machine
	# that reports a touchscreen -- a Windows laptop, a desktop browser where
	# navigator.maxTouchPoints > 0 -- so Game.touch_mode can be on for someone
	# holding a mouse. Plain mouse motion, no button, cursor free, must still turn
	# the camera, and by exactly one sensitivity step (not two).
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _frames(1)
	_reset_view()
	_mouse_move(Vector2(60, 0), false)
	await _frames(2)
	var d_free: float = wrapf(_yaw(), -PI, PI)
	check("mouse_look_in_touch_mode_plain", absf(d_free - (-60.0 * mouse_sens)) < 0.01,
		"%.4f rad, expected %.4f (touch_mode=%s, cursor free, no button)" % [
			d_free, -60.0 * mouse_sens, str(Game.touch_mode)])
	# ... and dragging still looks (a trackpad user who holds a button)
	_reset_view()
	_mouse_move(Vector2(60, 0), true)
	await _frames(2)
	check("mouse_drag_looks_in_touch_mode", absf(_yaw()) > 0.02, "%.4f rad" % _yaw())
	# while a finger IS on the glass, its emulated twin is ignored (no double look)
	var finger := InputEventScreenTouch.new()
	finger.index = 3
	finger.position = Vector2(900, 400)
	finger.pressed = true
	Input.parse_input_event(finger)
	await _frames(1)
	_reset_view()
	_mouse_move(Vector2(60, 0))
	await _frames(2)
	check("finger_down_suppresses_mouse_twin", absf(_yaw()) < 1e-6,
		"%.6f rad while finger_down=%s" % [_yaw(), str(player.finger_down)])
	var lift := InputEventScreenTouch.new()
	lift.index = 3
	lift.position = Vector2(900, 400)
	lift.pressed = false
	Input.parse_input_event(lift)
	await _frames(2)
	# ... and the finger lifting hands look back to the mouse immediately
	_reset_view()
	_mouse_move(Vector2(60, 0))
	await _frames(2)
	check("mouse_look_after_finger_lifts", absf(wrapf(_yaw(), -PI, PI) - (-60.0 * mouse_sens)) < 0.01,
		"%.4f rad" % wrapf(_yaw(), -PI, PI))
	# a real click on the world captures the pointer; a finger's emulated click
	# must never take the cursor away from the on-screen controls
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	await _frames(2)
	if DisplayServer.get_name() == "headless":
		skip("click_captures_pointer", "headless has no pointer to capture")
	else:
		check("click_captures_pointer", Input.mouse_mode == Input.MOUSE_MODE_CAPTURED,
			"mouse_mode=%d" % Input.mouse_mode)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var tap := InputEventScreenTouch.new()
	tap.index = 4
	tap.position = Vector2(900, 400)
	tap.pressed = true
	Input.parse_input_event(tap)
	await _frames(2)
	if DisplayServer.get_name() == "headless":
		skip("finger_click_does_not_capture", "headless has no pointer to capture")
	else:
		check("finger_click_does_not_capture", Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
			"mouse_mode=%d" % Input.mouse_mode)
	var tap_up := InputEventScreenTouch.new()
	tap_up.index = 4
	tap_up.position = Vector2(900, 400)
	tap_up.pressed = false
	Input.parse_input_event(tap_up)
	await _frames(2)

	# ------------------------------------------------------------- edge cases
	# absolute-mode motion (some remote desktop / tablet drivers) must not snap
	# the view to a screen coordinate
	_reset_view()
	var abs_ev := InputEventMouseMotion.new()
	abs_ev.relative = Vector2.ZERO
	abs_ev.position = Vector2(400, 300)
	Input.parse_input_event(abs_ev)
	await _frames(2)
	check("absolute_motion_ignored", absf(_yaw()) < 1e-6, "%.6f rad" % _yaw())

	# pitch is clamped, so a thousand-pixel flick cannot flip the world upside down
	_reset_view()
	for i in 20:
		_mouse_move(Vector2(0, -400), true)
	await _frames(2)
	check("pitch_clamped", absf(player.pitch) <= 1.36, "%.3f rad" % player.pitch)

	# ------------------------------------------------------------- flashlight
	_reset_view()
	var was_on: bool = player.flashlight_on
	var key := InputEventAction.new()
	key.action = "flashlight"
	key.pressed = true
	Input.parse_input_event(key)
	await _frames(2)
	check("flashlight_key_toggles", player.flashlight_on != was_on,
		"%s -> %s" % [str(was_on), str(player.flashlight_on)])
	Input.parse_input_event(key)
	await _frames(2)

	# --------------------------------------------------------------- pause
	world._toggle_pause()
	await _frames(2)
	var moved_paused: float = await _hold("move_forward", 24)
	check("pause_stops_movement", moved_paused < 0.05, "%.3f m" % moved_paused)
	# and the packed state does not leak out of the pause into the resume
	world._resume()
	await _frames(2)
	var resumed: float = await _hold("move_forward", 24)
	check("resume_restores_movement", resumed > 0.25, "%.2f m in 24 ticks" % resumed)

	# the stick must not stay latched across a pause
	world._toggle_pause()
	await _frames(1)
	world._resume()
	await _frames(2)
	check("stick_not_latched_after_pause", player.touch_move == Vector2.ZERO,
		str(player.touch_move))

	# ------------------------------------------- the overlay must go quiet
	# a thumb on the screen while paused must not steer, look or latch a stick
	Game.touch_mode = true
	world._toggle_pause()
	await _frames(2)
	_reset_view()
	_touch_drag(Vector2(900, 400), Vector2(90, 0))
	await _frames(2)
	check("touch_look_blocked_when_paused", absf(wrapf(_yaw(), -PI, PI)) < 1e-6,
		"%.6f rad" % _yaw())
	_touch_drag(Vector2(220, 600), Vector2(0, -90))
	await _frames(2)
	check("touch_stick_blocked_when_paused", player.touch_move == Vector2.ZERO,
		str(player.touch_move))
	world._resume()
	await _frames(2)

	# the death/win freeze must hold the camera still too
	player.freeze()
	await _frames(1)
	_reset_view()
	_touch_drag(Vector2(900, 400), Vector2(90, 0))
	_mouse_move(Vector2(90, 0))
	await _frames(2)
	check("look_blocked_when_frozen", absf(wrapf(_yaw(), -PI, PI)) < 1e-6,
		"%.6f rad" % _yaw())
	player.frozen = false

	# a note swallows the key that dismisses it (F closes the note, it must not
	# also toggle the torch on the same press)
	world.hud.show_note("1\n\nTEST", 4.0)
	await _frames(4)
	var torch_before: bool = player.flashlight_on
	var dismiss := InputEventAction.new()
	dismiss.action = "flashlight"
	dismiss.pressed = true
	Input.parse_input_event(dismiss)
	await _frames(3)
	await _frames(10)
	check("note_dismiss_consumes_key",
		player.flashlight_on == torch_before and world.hud.note_root.modulate.a < 0.05,
		"torch %s, note alpha %.2f (must not climb back)" % [
			str(player.flashlight_on), world.hud.note_root.modulate.a])

	# and after that, the same key works again
	var torch_before2: bool = player.flashlight_on
	Input.parse_input_event(dismiss)
	await _frames(3)
	check("key_works_after_note", player.flashlight_on != torch_before2,
		"%s -> %s" % [str(torch_before2), str(player.flashlight_on)])

	Game.touch_mode = false
	print("[controls] done")
