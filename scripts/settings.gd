extends Node
## Persistent player settings (user://settings.cfg) — survives restarts.

const PATH := "user://settings.cfg"

var mouse_sensitivity := 1.0
var invert_y := false
var force_touch := false
var master_volume := 0.9
var best_time := -1.0
var best_pages := 0
var flash_warning_seen := false
var camcorder := true          # the video-camera post stack + viewfinder
var camcorder_physics := true  # camera on the joint-driven handheld rig


func _ready() -> void:
	load_settings()
	# test hooks: A/B the video look without touching user://settings.cfg
	if OS.get_environment("EIGHT_PAGES_NO_CAMCORDER") == "1":
		camcorder = false
	if OS.get_environment("EIGHT_PAGES_PROC_CAM") == "1":
		camcorder_physics = false


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	mouse_sensitivity = cfg.get_value("input", "mouse_sensitivity", 1.0)
	invert_y = cfg.get_value("input", "invert_y", false)
	force_touch = cfg.get_value("input", "force_touch", false)
	master_volume = cfg.get_value("audio", "master_volume", 0.9)
	best_time = cfg.get_value("stats", "best_time", -1.0)
	best_pages = cfg.get_value("stats", "best_pages", 0)
	flash_warning_seen = cfg.get_value("misc", "flash_warning_seen", false)
	camcorder = cfg.get_value("video", "camcorder", true)
	camcorder_physics = cfg.get_value("video", "camcorder_physics", true)
	apply_volume()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("input", "invert_y", invert_y)
	cfg.set_value("input", "force_touch", force_touch)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("stats", "best_time", best_time)
	cfg.set_value("stats", "best_pages", best_pages)
	cfg.set_value("misc", "flash_warning_seen", flash_warning_seen)
	cfg.set_value("video", "camcorder", camcorder)
	cfg.set_value("video", "camcorder_physics", camcorder_physics)
	cfg.save(PATH)
	apply_volume()


func save_best(time: float, pages: int) -> void:
	if best_time < 0.0 or time < best_time:
		best_time = time
	best_pages = maxi(best_pages, pages)
	save_settings()


func apply_volume() -> void:
	var bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(bus, linear_to_db(clampf(master_volume, 0.0, 1.0)))
