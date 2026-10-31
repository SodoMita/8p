extends Node
## Temporary end-to-end probe: who swallows the real mouse motion?
var world: Node = null
var events := 0
var sum := Vector2.ZERO
var last := Vector2.ZERO
var reported := 0


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		events += 1
		sum += event.relative
		last = event.relative
		if reported < 4:
			reported += 1
			var hov := get_viewport().gui_get_hovered_control()
			print("[live] motion rel=%s pos=%s device=%d hovered=%s" % [
				str(event.relative), str(event.position), event.device,
				(hov.get_path() if hov != null else "<none>")])


func _mode_name() -> String:
	return ["VISIBLE", "HIDDEN", "CAPTURED", "CONFINED"][Input.mouse_mode]


func _dump_controls(n: Node, depth := 0) -> void:
	if n is Control:
		var c := n as Control
		if c.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			print("[live] STOP-CONTROL %s filter=%d visible=%s rect=%s" % [
				c.get_path(), c.mouse_filter, str(c.is_visible_in_tree()), str(c.get_global_rect())])
	for ch in n.get_children():
		_dump_controls(ch, depth + 1)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await get_tree().create_timer(2.5).timeout
	var player = world.player
	print("[live] start mouse_mode=%s touch_mode=%s" % [_mode_name(), str(Game.touch_mode)])
	_dump_controls(world)
	# turn the F3 input diagnostic on so the E2E run also proves the overlay works
	var f3 := InputEventKey.new()
	f3.keycode = KEY_F3
	f3.pressed = true
	Input.parse_input_event(f3)
	print("[live] READY")
	var y0: float = player.rotation.y
	for i in 12:
		await get_tree().create_timer(0.5).timeout
		if i % 2 == 0:
			print("[live] t=%.1f events=%d sum=%s yaw=%.4f" % [
				(i + 1) * 0.5, events, str(sum), wrapf(player.rotation.y - y0, -PI, PI)])
	if OS.get_environment("EIGHT_PAGES_DIAG_SHOT") != "":
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(OS.get_environment("EIGHT_PAGES_DIAG_SHOT"))
		print("[live] wrote ", OS.get_environment("EIGHT_PAGES_DIAG_SHOT"))
	print("[live] RESULT events=%d yaw_delta=%.4f" % [
		events, wrapf(player.rotation.y - y0, -PI, PI)])
	get_tree().quit()
