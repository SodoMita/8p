extends Node
## Global game state, input routing and quality/touch configuration.

signal pages_changed(collected: int, total: int)
signal page_collected(index: int, text: String)
signal slender_visibility(visible_now: bool)
signal player_killed(reason: String)
signal run_finished(won: bool)

const TOTAL_PAGES := 8
const VERSION := "1.6.7"

var pages_collected := 0
var run_time := 0.0
var run_active := false
var clock_frozen := false
var touch_mode := false
## True while a menu, a note with buttons or an end screen owns the screen. The
## pointer policy has exactly one reader (player.gd) and one writer (hud.gd), so
## the cursor is released whenever a UI can be clicked and recaptured when the
## forest is back -- with no per-platform branches anywhere.
var ui_blocking := false
var quality := 2  # 0 = low, 1 = medium, 2 = high
var autotest := false
var best_time := -1.0
var best_pages := 0

var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# --- command line / environment switches (handy for automated tests) ---
	var args := OS.get_cmdline_user_args()
	autotest = OS.get_environment("EIGHT_PAGES_AUTOTEST") == "1"
	for a in args:
		if a == "--autotest" or a.begins_with("--autotest=") or a == "--flow":
			autotest = true
	quality = _detect_quality(args)
	touch_mode = _detect_touch(args)
	if "--touch" in args or OS.get_environment("EIGHT_PAGES_TOUCH") == "1":
		touch_mode = true
	if "--no-touch" in args:
		touch_mode = false
	_rng.randomize()
	apply_display_scaling()
	get_window().size_changed.connect(apply_display_scaling)


## Phones held upright get a portrait-friendly design resolution so that the
## HUD and menus stay legible; landscape keeps the 16:9 layout.
func apply_display_scaling() -> void:
	var win := get_window()
	if win == null:
		return
	var size := win.size
	var portrait := size.y > size.x
	if portrait:
		win.content_scale_size = Vector2i(720, 1280)
	else:
		win.content_scale_size = Vector2i(1280, 720)


func is_portrait() -> bool:
	var size := get_window().size
	return size.y > size.x


func _detect_touch(args: PackedStringArray) -> bool:
	if "--touch" in args:
		return true
	if "--no-touch" in args:
		return false
	if OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios"):
		return true
	if DisplayServer.is_touchscreen_available():
		return true
	if OS.has_feature("web"):
		# phones report touch points even when Godot's own probe says otherwise
		var js := "navigator.maxTouchPoints > 0 || 'ontouchstart' in window"
		if str(JavaScriptBridge.eval(js, true)) == "true":
			return true
	if Settings != null and Settings.force_touch:
		return true
	return false


func _detect_quality(args: PackedStringArray) -> int:
	for a in args:
		if a.begins_with("--quality="):
			return clampi(int(a.get_slice("=", 1)), 0, 2)
	if OS.has_feature("mobile"):
		return 1
	var adapter := RenderingServer.get_video_adapter_name().to_lower()
	if adapter.contains("llvmpipe") or adapter.contains("softpipe") or adapter.contains("swiftshader"):
		return 0
	if adapter.contains("intel") or adapter.contains("mali") or adapter.contains("adreno"):
		return 1
	return 2


# --------------------------------------------------------------------------- #
# life cycle helpers
# --------------------------------------------------------------------------- #
func begin_run() -> void:
	pages_collected = 0
	run_time = 0.0
	run_active = true
	clock_frozen = false
	pages_changed.emit(0, TOTAL_PAGES)


func finish_run(won: bool) -> void:
	if not run_active:
		return
	run_active = false
	if won:
		if best_time < 0.0 or run_time < best_time:
			best_time = run_time
		if not autotest:
			Settings.save_best(best_time, TOTAL_PAGES)
	best_pages = maxi(best_pages, pages_collected)
	if not autotest:
		Settings.save_best(best_pages, TOTAL_PAGES)
	run_finished.emit(won)


func freeze_clock() -> void:
	## stop the timer during the death/win sequences, run bookkeeping still happens
	clock_frozen = true


func register_page(note_text: String) -> void:
	pages_collected += 1
	page_collected.emit(pages_collected, note_text)
	pages_changed.emit(pages_collected, TOTAL_PAGES)


func difficulty() -> float:
	## 0.0 -> 1.0 ramp based on pages collected. Drives Slender aggression.
	return float(pages_collected) / float(TOTAL_PAGES)


func _process(delta: float) -> void:
	if run_active and not clock_frozen and not get_tree().paused:
		run_time += delta


func format_time(seconds: float) -> String:
	var s := int(seconds)
	return "%02d:%02d" % [s / 60, s % 60]


func rng() -> RandomNumberGenerator:
	return _rng


func quit_game() -> void:
	get_tree().quit()
